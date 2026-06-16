//
//  Inference.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/1/26.
//

import Foundation
import Observation

public protocol LocalAIKitInferenceEngine: Sendable {
    func generate(
        request: LocalAIKitInferenceRequest,
        using model: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)?
    ) async throws -> String
}

public enum LocalAIKitInferenceEngineFactory {
    public static func makeDefault() -> any LocalAIKitInferenceEngine {
        return LlamaCppInferenceEngine()
    }
}
