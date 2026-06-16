//
//  LlamaBridge.swift
//  LocalAIKit
//
//  Pure Swift wrapper around the native llama.framework module.
//

import Foundation
import llama

public struct LlamaCppInferenceEngine: LocalAIKitInferenceEngine {
    public init() {}

    public func generate(
        request: LocalAIKitInferenceRequest,
        using model: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard let modelURL = model.primaryFileURL else {
            throw LocalAIKitInferenceError.missingPrimaryModelFile
        }

        return try await Task.detached(priority: .userInitiated) {
            try Self.generate(
                request: request,
                modelURL: modelURL,
                onPartialText: onPartialText
            )
        }.value
    }

    private static func generate(
        request: LocalAIKitInferenceRequest,
        modelURL: URL,
        onPartialText: (@Sendable (String) -> Void)?
    ) throws -> String {
        NSLog("LlamaCppInferenceEngine: generate started")
        llama_backend_init()
        NSLog("LlamaCppInferenceEngine: backend initialized")

        let prompt = composePrompt(request: request)
        NSLog("LlamaCppInferenceEngine: prompt composed (\(prompt.count) chars)")

        var modelParams = llama_model_default_params()
        NSLog("LlamaCppInferenceEngine: loading model at \(modelURL.path)")
        let modelPointer = modelURL.path.withCString { path in
            llama_model_load_from_file(path, modelParams)
        }

        guard let modelPointer else {
            NSLog("LlamaCppInferenceEngine: model load failed")
            throw LocalAIKitInferenceError.modelLoadFailed(path: modelURL.path)
        }
        defer { llama_model_free(modelPointer) }
        NSLog("LlamaCppInferenceEngine: model loaded")

        guard let vocab = llama_model_get_vocab(modelPointer) else {
            NSLog("LlamaCppInferenceEngine: vocab missing")
            throw LocalAIKitInferenceError.modelLoadFailed(path: modelURL.path)
        }

        let promptTokens = try tokenize(prompt, vocab: vocab)
        NSLog("LlamaCppInferenceEngine: tokenized prompt into \(promptTokens.count) tokens")

        var contextParams = llama_context_default_params()
        let contextBudget = max(promptTokens.count + request.maxTokens + 32, 256)
        contextParams.n_ctx = UInt32(contextBudget)
        contextParams.n_batch = UInt32(max(promptTokens.count, 1))
        contextParams.n_ubatch = UInt32(max(promptTokens.count, 1))
        contextParams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        contextParams.n_threads_batch = contextParams.n_threads
        NSLog("LlamaCppInferenceEngine: creating context with budget \(contextBudget)")

        guard let contextPointer = llama_init_from_model(modelPointer, contextParams) else {
            NSLog("LlamaCppInferenceEngine: context creation failed")
            throw LocalAIKitInferenceError.contextCreationFailed
        }
        defer { llama_free(contextPointer) }
        NSLog("LlamaCppInferenceEngine: context created")

        var generatedText = ""
        var completionTokenCount = 0
        var lastPartialUpdate = CFAbsoluteTimeGetCurrent()
        let partialUpdateInterval: CFTimeInterval = 0.12

        let samplerParams = llama_sampler_chain_default_params()
        let sampler = llama_sampler_chain_init(samplerParams)
        defer { llama_sampler_free(sampler) }

        if request.topK > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(Int32(request.topK)))
        }

        if request.topP < 1.0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(Float(request.topP), 1))
        }

        let penaltyLastN = Int32(min(max(promptTokens.count + request.maxTokens, 32), contextBudget))
        if request.repeatPenalty > 1.0 {
            llama_sampler_chain_add(
                sampler,
                llama_sampler_init_penalties(
                    penaltyLastN,
                    Float(request.repeatPenalty),
                    0.0,
                    0.0
                )
            )
        }

        if request.temperature > 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(request.temperature)))
        }

        if request.temperature <= 0 || request.topK == 1 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            let samplerSeed = UInt32(truncatingIfNeeded: request.seed ?? UInt64(LLAMA_DEFAULT_SEED))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(samplerSeed))
        }

        if llama_model_has_encoder(modelPointer) {
            NSLog("LlamaCppInferenceEngine: model has encoder")
            var promptTokenBuffer = promptTokens
            let promptBatch = llama_batch_get_one(&promptTokenBuffer, Int32(promptTokenBuffer.count))
            if llama_encode(contextPointer, promptBatch) != 0 {
                NSLog("LlamaCppInferenceEngine: encode failed")
                throw LocalAIKitInferenceError.decodeFailed(code: -1)
            }

            var decoderStartToken = llama_model_decoder_start_token(modelPointer)
            if decoderStartToken == LLAMA_TOKEN_NULL {
                decoderStartToken = llama_vocab_bos(vocab)
            }

            var decoderTokenBuffer = [decoderStartToken]
            let decoderBatch = llama_batch_get_one(&decoderTokenBuffer, 1)
            if llama_decode(contextPointer, decoderBatch) != 0 {
                NSLog("LlamaCppInferenceEngine: decoder priming failed")
                throw LocalAIKitInferenceError.decodeFailed(code: -1)
            }
        } else {
            NSLog("LlamaCppInferenceEngine: decoding prompt")
            var promptTokenBuffer = promptTokens
            let promptBatch = llama_batch_get_one(&promptTokenBuffer, Int32(promptTokenBuffer.count))
            if llama_decode(contextPointer, promptBatch) != 0 {
                NSLog("LlamaCppInferenceEngine: prompt decode failed")
                throw LocalAIKitInferenceError.decodeFailed(code: -1)
            }
        }

        NSLog("LlamaCppInferenceEngine: entering generation loop")

        while completionTokenCount < request.maxTokens {
            let nextToken = llama_sampler_sample(sampler, contextPointer, -1)

            if nextToken == LLAMA_TOKEN_NULL || llama_vocab_is_eog(vocab, nextToken) {
                break
            }

            let piece = try piece(for: nextToken, vocab: vocab)
            generatedText += piece
            if onPartialText != nil || completionTokenCount == 0 {
                let now = CFAbsoluteTimeGetCurrent()
                if completionTokenCount == 0 || now - lastPartialUpdate >= partialUpdateInterval {
                    lastPartialUpdate = now
                    onPartialText?(generatedText)
                }
            }
            completionTokenCount += 1

            if let stop = matchingStopSequence(in: generatedText, stopSequences: request.stopSequences) {
                if generatedText.hasSuffix(stop) {
                    generatedText.removeLast(stop.count)
                }
                break
            }

            var nextTokenBuffer = [nextToken]
            let batch = llama_batch_get_one(&nextTokenBuffer, 1)
            if llama_decode(contextPointer, batch) != 0 {
                NSLog("LlamaCppInferenceEngine: token decode failed")
                throw LocalAIKitInferenceError.decodeFailed(code: -3)
            }
        }

        onPartialText?(generatedText)

        NSLog("LlamaCppInferenceEngine: generation loop finished")

        NSLog("LlamaCppInferenceEngine: returning result")

        return generatedText
    }

    private static func composePrompt(request: LocalAIKitInferenceRequest) -> String {
        if let systemPrompt = request.systemPrompt, !systemPrompt.isEmpty {
            return [systemPrompt, request.prompt].joined(separator: "\n\n")
        }

        return request.prompt
    }

    private static func tokenize(_ prompt: String, vocab: OpaquePointer) throws -> [llama_token] {
        let byteCount = prompt.lengthOfBytes(using: .utf8)
        let estimatedCount = prompt.withCString { cString in
            llama_tokenize(vocab, cString, Int32(byteCount), nil, 0, true, true)
        }

        if estimatedCount > 0 {
            throw LocalAIKitInferenceError.tokenizationFailed
        }

        var tokens = Array(repeating: llama_token(0), count: Int(-estimatedCount))
        let actualCount = prompt.withCString { cString in
            tokens.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return -1
                }

                return Int(llama_tokenize(
                    vocab,
                    cString,
                    Int32(byteCount),
                    baseAddress,
                    Int32(buffer.count),
                    true,
                    true
                ))
            }
        }

        guard actualCount >= 0 else {
            throw LocalAIKitInferenceError.tokenizationFailed
        }

        tokens = Array(tokens.prefix(Int(actualCount)))
        return tokens
    }

    private static func piece(for token: llama_token, vocab: OpaquePointer) throws -> String {
        var buffer = Array(repeating: CChar(0), count: 512)
        let length = buffer.withUnsafeMutableBufferPointer { pieceBuffer in
            guard let baseAddress = pieceBuffer.baseAddress else {
                return -1
            }

            return Int(llama_token_to_piece(vocab, token, baseAddress, Int32(pieceBuffer.count), 0, false))
        }

        guard length >= 0 else {
            throw LocalAIKitInferenceError.tokenizationFailed
        }

        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func matchingStopSequence(in text: String, stopSequences: [String]) -> String? {
        stopSequences
            .filter { !$0.isEmpty && text.hasSuffix($0) }
            .max(by: { $0.count < $1.count })
    }
}
