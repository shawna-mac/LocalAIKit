//
//  LocalAIKitInferenceRequest.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

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
