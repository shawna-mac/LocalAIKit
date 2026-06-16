//
//  LocalAIKitError.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/13/26.
//

import Foundation

public enum LocalAIKitError: Error, Equatable, Sendable {
    case emptyModelPackage
    case invalidRepository
    case invalidRemoteURL
    case missingModelFilename
    case invalidHTTPStatus(code: Int)
    case unableToCreateDirectory(URL)
    case checksumMismatch(expected: String, actual: String)
    case modelDownloadIncomplete(filename: String)
    case modelDownloadFailed(message: String)
    case missingBackgroundDownloadState
    case inferenceEngineNotConfigured
    case noLoadedModel
}

func localAIKitMessage(for error: Error) -> String {
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
        case .modelDownloadIncomplete(let filename):
            return "The model file \(filename) has not finished downloading."
        case .modelDownloadFailed(let message):
            return message
        case .missingBackgroundDownloadState:
            return "The background download state could not be restored."
        case .inferenceEngineNotConfigured:
            return "No inference engine has been configured."
        case .noLoadedModel:
            return "No loaded model is available for inference."
        }
    }

    return error.localizedDescription
}
