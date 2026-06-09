//
//  Inference.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/1/26.
//

import Foundation
import Observation

private func localAIKitLog(_ message: String) {
    NSLog("%@", message)
}

public struct LocalAIKitInferenceRequest: Sendable, Hashable {
    public var prompt: String
    public var systemPrompt: String?
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var repeatPenalty: Double
    public var seed: UInt64?
    public var stopSequences: [String]

    public init(
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 256,
        temperature: Double = 0.7,
        topP: Double = 0.95,
        topK: Int = 40,
        repeatPenalty: Double = 1.1,
        seed: UInt64? = nil,
        stopSequences: [String] = []
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.seed = seed
        self.stopSequences = stopSequences
    }
}

public extension LocalAIKitInferenceRequest {
    func forStructuredOutput() -> LocalAIKitInferenceRequest {
        let structuredInstruction = """
        Return only valid JSON. Do not include markdown fences, commentary, or extra text.
        The JSON must decode cleanly into the requested Swift type.
        """

        let combinedSystemPrompt: String
        if let systemPrompt, !systemPrompt.isEmpty {
            combinedSystemPrompt = [systemPrompt, structuredInstruction].joined(separator: "\n\n")
        } else {
            combinedSystemPrompt = structuredInstruction
        }

        return LocalAIKitInferenceRequest(
            prompt: prompt,
            systemPrompt: combinedSystemPrompt,
            maxTokens: maxTokens,
            temperature: 0,
            topP: 1,
            topK: 1,
            repeatPenalty: 1,
            seed: seed,
            stopSequences: stopSequences
        )
    }
}

public struct LocalAIKitInferenceUsage: Sendable, Hashable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = promptTokens + completionTokens
    }
}

public struct LocalAIKitInferenceResult: Sendable, Hashable {
    public var text: String
    public var usage: LocalAIKitInferenceUsage?
    public var finishReason: String?

    public init(text: String, usage: LocalAIKitInferenceUsage? = nil, finishReason: String? = nil) {
        self.text = text
        self.usage = usage
        self.finishReason = finishReason
    }
}

public enum LocalAIKitInferencePhase: Equatable, Sendable {
    case idle
    case generating
    case ready
    case failed(message: String)
}

public enum LocalAIKitInferenceError: Error, Equatable, Sendable {
    case modelLoadFailed(path: String)
    case contextCreationFailed
    case tokenizationFailed
    case decodeFailed(code: Int32)
    case missingPrimaryModelFile
}

public enum LocalAIKitStructuredOutputError: Error, Equatable, Sendable {
    case emptyResponse
    case invalidJSONObject
    case decodingFailed(message: String)
}

extension LocalAIKitStructuredOutputError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Structured output was empty."
        case .invalidJSONObject:
            return "Structured output did not contain valid JSON."
        case .decodingFailed(let message):
            return "Structured output could not be decoded: \(message)"
        }
    }
}

public protocol LocalAIKitInferenceEngine: Sendable {
    func generate(
        request: LocalAIKitInferenceRequest,
        using model: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)?
    ) async throws -> LocalAIKitInferenceResult
}

public enum LocalAIKitInferenceEngineFactory {
    public static func makeDefault() -> any LocalAIKitInferenceEngine {
#if canImport(llama)
        return LlamaCppInferenceEngine()
#else
        return UnsupportedLocalAIKitInferenceEngine()
#endif
    }
}

public struct UnsupportedLocalAIKitInferenceEngine: LocalAIKitInferenceEngine {
    public init() {}

    public func generate(
        request: LocalAIKitInferenceRequest,
        using model: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)?
    ) async throws -> LocalAIKitInferenceResult {
        localAIKitLog("LocalAIKit: unsupported inference engine selected")
        throw LocalAIKitError.inferenceEngineNotConfigured
    }
}

public extension LocalAIKitClient {
    func generate(
        _ request: LocalAIKitInferenceRequest,
        using loadedModel: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> LocalAIKitInferenceResult {
        localAIKitLog("LocalAIKit.generate(using:) started")

        do {
            let result = try await inferenceEngine.generate(
                request: request,
                using: loadedModel,
                onPartialText: onPartialText
            )
            Self.printGeneratedResponse(result)
            return result
        } catch {
            localAIKitLog("LocalAIKit.generate(using:) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func generate(
        _ request: LocalAIKitInferenceRequest,
        using downloadedModel: DownloadedModel,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> LocalAIKitInferenceResult {
        let loadedModel = try loadIntoMemory(downloadedModel)
        return try await generate(request, using: loadedModel, onPartialText: onPartialText)
    }

    func generate(
        _ request: LocalAIKitInferenceRequest,
        package: HuggingFaceModelPackage,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> LocalAIKitInferenceResult {
        let loadedModel = try await loadModel(package)
        return try await generate(request, using: loadedModel, onPartialText: onPartialText)
    }

    func generateStructured<T: Decodable>(
        _ request: LocalAIKitInferenceRequest,
        as type: T.Type = T.self,
        using loadedModel: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let structuredRequest = request.forStructuredOutput()
        let result = try await generate(structuredRequest, using: loadedModel, onPartialText: onPartialText)
        return try decodeStructuredOutput(result.text, as: type)
    }

    func generateStructured<T: Decodable>(
        _ request: LocalAIKitInferenceRequest,
        as type: T.Type = T.self,
        using downloadedModel: DownloadedModel,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let loadedModel = try loadIntoMemory(downloadedModel)
        return try await generateStructured(request, as: type, using: loadedModel, onPartialText: onPartialText)
    }

    func generateStructured<T: Decodable>(
        _ request: LocalAIKitInferenceRequest,
        as type: T.Type = T.self,
        package: HuggingFaceModelPackage,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let loadedModel = try await loadModel(package)
        return try await generateStructured(request, as: type, using: loadedModel, onPartialText: onPartialText)
    }

    private static func printGeneratedResponse(_ result: LocalAIKitInferenceResult) {
        let response = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        localAIKitLog("LocalAIKit response:")
        localAIKitLog(response.isEmpty ? "(empty response)" : response)
    }

    private func decodeStructuredOutput<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        let candidateText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateText.isEmpty else {
            throw LocalAIKitStructuredOutputError.emptyResponse
        }

        let jsonCandidates = Self.extractJSONCandidates(from: candidateText)
        guard !jsonCandidates.isEmpty else {
            throw LocalAIKitStructuredOutputError.invalidJSONObject
        }

        var lastDecodingError: Error?
        for jsonText in jsonCandidates {
            do {
                return try JSONDecoder().decode(T.self, from: Data(jsonText.utf8))
            } catch {
                lastDecodingError = error
            }
        }

        throw LocalAIKitStructuredOutputError.decodingFailed(
            message: Self.describeDecodingError(lastDecodingError) ?? "The response contained JSON, but none of the candidates matched the requested Swift type."
        )
    }

    private static func describeDecodingError(_ error: Error?) -> String? {
        guard let error else { return nil }

        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .typeMismatch(let type, let context):
                return "Type mismatch for \(type) at \(Self.describeCodingPath(context.codingPath)): \(context.debugDescription)"
            case .valueNotFound(let type, let context):
                return "Missing value for \(type) at \(Self.describeCodingPath(context.codingPath)): \(context.debugDescription)"
            case .keyNotFound(let key, let context):
                return "Missing key '\(key.stringValue)' at \(Self.describeCodingPath(context.codingPath)): \(context.debugDescription)"
            case .dataCorrupted(let context):
                return "Corrupted JSON at \(Self.describeCodingPath(context.codingPath)): \(context.debugDescription)"
            @unknown default:
                return decodingError.localizedDescription
            }
        }

        return error.localizedDescription
    }

    private static func describeCodingPath(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else {
            return "the top level"
        }

        return codingPath
            .map { key in
                if let intValue = key.intValue {
                    return "[\(intValue)]"
                } else {
                    return key.stringValue
                }
            }
            .joined(separator: ".")
    }

    private static func extractJSONCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        var seen = Set<String>()

        func appendCandidate(_ candidate: String) {
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCandidate.isEmpty, seen.insert(trimmedCandidate).inserted else {
                return
            }

            candidates.append(trimmedCandidate)
        }

        func appendFencedJSONCandidates(labeledFence: String) {
            var searchStart = trimmed.startIndex

            while let openRange = trimmed.range(of: labeledFence, range: searchStart..<trimmed.endIndex) {
                let contentStart = openRange.upperBound
                guard let closeRange = trimmed.range(of: "```", range: contentStart..<trimmed.endIndex) else {
                    break
                }

                let fencedContent = String(trimmed[contentStart..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                appendCandidate(fencedContent)
                searchStart = closeRange.upperBound
            }
        }

        appendFencedJSONCandidates(labeledFence: "```json")
        appendFencedJSONCandidates(labeledFence: "```JSON")

        func appendBalancedCandidates(opening: Character, closing: Character) {
            var searchStart = trimmed.startIndex

            while searchStart < trimmed.endIndex,
                  let openIndex = trimmed[searchStart...].firstIndex(of: opening) {
                let suffix = String(trimmed[openIndex...])
                if let candidate = Self.extractBalancedJSON(from: suffix, opening: opening, closing: closing) {
                    appendCandidate(candidate)
                }

                searchStart = trimmed.index(after: openIndex)
            }
        }

        appendBalancedCandidates(opening: "{", closing: "}")
        appendBalancedCandidates(opening: "[", closing: "]")

        return candidates
    }

    private static func extractBalancedJSON(from text: String, opening: Character, closing: Character) -> String? {
        guard let startIndex = text.firstIndex(of: opening) else {
            return nil
        }

        var depth = 0
        var isInString = false
        var isEscaping = false
        var currentIndex = startIndex

        while currentIndex < text.endIndex {
            let character = text[currentIndex]

            if isInString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInString = false
                }
            } else {
                if character == "\"" {
                    isInString = true
                } else if character == opening {
                    depth += 1
                } else if character == closing {
                    depth -= 1
                    if depth == 0 {
                        return String(text[startIndex...currentIndex])
                    }
                }
            }

            currentIndex = text.index(after: currentIndex)
        }

        return nil
    }
}

@MainActor
@Observable
public final class LocalAIKitInferenceState {
    public private(set) var phase: LocalAIKitInferencePhase = .idle
    public private(set) var request: LocalAIKitInferenceRequest?
    public private(set) var result: LocalAIKitInferenceResult?
    public private(set) var outputText: String = ""
    public private(set) var lastErrorMessage: String?
    public private(set) var statusMessage: String?

    private let client: LocalAIKitClient
    private let loadedModel: LoadedModelContents?
    private let downloadedModel: DownloadedModel?
    private let package: HuggingFaceModelPackage?

    public init(
        client: LocalAIKitClient = .init(),
        loadedModel: LoadedModelContents? = nil,
        downloadedModel: DownloadedModel? = nil,
        package: HuggingFaceModelPackage? = nil
    ) {
        self.client = client
        self.loadedModel = loadedModel
        self.downloadedModel = downloadedModel
        self.package = package
    }

    public var isBusy: Bool {
        phase == .generating
    }

    public func reset() {
        phase = .idle
        request = nil
        result = nil
        outputText = ""
        lastErrorMessage = nil
        statusMessage = nil
    }

    public func generate(
        _ request: LocalAIKitInferenceRequest,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async {
        localAIKitLog("LocalAIKitInferenceState.generate started")
        reset()
        self.request = request
        phase = .generating
        statusMessage = "Generating text..."

        do {
            let generatedResult: LocalAIKitInferenceResult

            if let loadedModel {
                localAIKitLog("LocalAIKitInferenceState.generate using loadedModel")
                generatedResult = try await client.generate(request, using: loadedModel, onPartialText: onPartialText)
            } else if let downloadedModel {
                localAIKitLog("LocalAIKitInferenceState.generate using downloadedModel")
                generatedResult = try await client.generate(request, using: downloadedModel, onPartialText: onPartialText)
            } else if let package {
                localAIKitLog("LocalAIKitInferenceState.generate using package")
                generatedResult = try await client.generate(request, package: package, onPartialText: onPartialText)
            } else {
                localAIKitLog("LocalAIKitInferenceState.generate has no model")
                throw LocalAIKitError.noLoadedModel
            }

            result = generatedResult
            outputText = generatedResult.text
            lastErrorMessage = nil
            phase = .ready
            statusMessage = "Generation complete."
            localAIKitLog("LocalAIKitInferenceState.generate completed")
        } catch {
            let message = Self.message(for: error)
            lastErrorMessage = message
            statusMessage = message
            phase = .failed(message: message)
            localAIKitLog("LocalAIKitInferenceState.generate failed: \(message)")
        }
    }

    private static func message(for error: Error) -> String {
        if let localAIKitError = error as? LocalAIKitError {
            switch localAIKitError {
            case .emptyModelPackage:
                return "The model package does not contain any files."
            case .invalidRepository:
                return "The Hugging Face repository identifier is invalid."
            case .invalidRemoteURL:
                return "The Hugging Face download URL could not be built."
            case .missingModelFilename:
                return "The model filename is missing."
            case .invalidHTTPStatus(let code):
                return "The download failed with HTTP status code \(code)."
            case .unableToCreateDirectory(let url):
                return "Unable to create a cache directory at \(url.path)."
            case .checksumMismatch(let expected, let actual):
                return "Checksum mismatch. Expected \(expected), got \(actual)."
            case .inferenceEngineNotConfigured:
                return "No inference engine has been configured."
            case .noLoadedModel:
                return "No loaded model is available for inference."
            }
        }

        if let inferenceError = error as? LocalAIKitInferenceError {
            switch inferenceError {
            case .modelLoadFailed(let path):
                return "Unable to load the llama.cpp model at \(path)."
            case .contextCreationFailed:
                return "Unable to create a llama.cpp context."
            case .tokenizationFailed:
                return "Unable to tokenize the prompt or model output."
            case .decodeFailed(let code):
                return "The llama.cpp decode step failed with code \(code)."
            case .missingPrimaryModelFile:
                return "The loaded model does not have a primary file."
            }
        }

        return error.localizedDescription
    }
}
