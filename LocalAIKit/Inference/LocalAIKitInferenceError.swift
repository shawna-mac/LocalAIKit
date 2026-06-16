//
//  LocalAIKitInferenceError.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

public enum LocalAIKitInferenceError: Error, Equatable, Sendable {
    case modelLoadFailed(path: String)
    case contextCreationFailed
    case tokenizationFailed
    case decodeFailed(code: Int32)
    case missingPrimaryModelFile

    case structuredOutputEmpty
    case structuredOutputMissingJSON
    case structuredOutputDecodingFailed(message: String)
}

extension LocalAIKitInferenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .structuredOutputEmpty:
            return "Structured output was empty."
        case .structuredOutputMissingJSON:
            return "Structured output did not contain valid JSON."
        case .structuredOutputDecodingFailed(let message):
            return "Structured output could not be decoded: \(message)"
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
}
