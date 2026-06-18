//
//  UnsupportedLocalAIKitInferenceEngine.swift
//  LocalAIKit
//
//  Created by Codex on 6/17/26.
//

import Foundation

/// A fallback inference engine used when the native `llama` binary is not available.
public struct UnsupportedLocalAIKitInferenceEngine: LocalAIKitInferenceEngine {
    public init() {}

    public func generate(
        request: LocalAIKitInferenceRequest,
        using model: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)?
    ) async throws -> String {
        throw LocalAIKitError.inferenceEngineNotConfigured
    }
}
