//
//  LocalAIKitInferenceState.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

@MainActor
@Observable
public final class LocalAIKitInferenceState {
    public private(set) var modelStatus: LocalAIKitModelStatus = .idle
    public private(set) var request: LocalAIKitInferenceRequest?
    public private(set) var outputText: String = ""
    public private(set) var statusMessage: String?

    private let client: LocalAIKitModelManager
    private let loadedModel: LoadedModelContents?
    private let downloadedModel: DownloadedModel?
    private let package: HuggingFaceModelPackage?

    public init(
        client: LocalAIKitModelManager = .init(),
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
        if case .generating = modelStatus {
            return true
        }

        return false
    }

    public func reset() {
        modelStatus = .idle
        request = nil
        outputText = ""
        statusMessage = nil
    }

    public func generate(
        _ request: LocalAIKitInferenceRequest,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async {
        NSLog("LocalAIKitInferenceState.generate started")
        reset()
        self.request = request
        modelStatus = .generating
        statusMessage = "Generating text..."

        do {
            let generatedText: String

            if let loadedModel {
                NSLog("LocalAIKitInferenceState.generate using loadedModel")
                generatedText = try await client.generate(request, using: loadedModel, onPartialText: onPartialText)
            } else if let downloadedModel {
                NSLog("LocalAIKitInferenceState.generate using downloadedModel")
                generatedText = try await client.generate(request, using: downloadedModel, onPartialText: onPartialText)
            } else if let package {
                NSLog("LocalAIKitInferenceState.generate using package")
                generatedText = try await client.generate(request, package: package, onPartialText: onPartialText)
            } else {
                NSLog("LocalAIKitInferenceState.generate has no model")
                throw LocalAIKitError.noLoadedModel
            }

            outputText = generatedText
            modelStatus = .ready
            statusMessage = "Generation complete."
            NSLog("LocalAIKitInferenceState.generate completed")
        } catch {
            let message = Self.message(for: error)
            statusMessage = message
            modelStatus = .failed(error: error)
            NSLog("LocalAIKitInferenceState.generate failed: \(message)")
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
            case .missingBackgroundDownloadState:
                return ""
            case .modelDownloadIncomplete(filename: _):
                return ""
            case .modelDownloadFailed(message: _):
                return ""
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
            case .structuredOutputEmpty:
                return "The structured output is empty."
            case .structuredOutputMissingJSON:
                return "The structured output is missing JSON data."
            case .structuredOutputDecodingFailed(message: let message):
                return "Failed to decode the structured output: \(message)."
            }
        }

        return error.localizedDescription
    }
}
