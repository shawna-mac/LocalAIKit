//
//  LocalAIKitModelManager.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

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

@Observable
public final class LocalAIKitModelManager: @unchecked Sendable {
    public let configuration: LocalAIKitConfiguration
    public let modelStore: HuggingFaceModelStore
    public let inferenceEngine: any LocalAIKitInferenceEngine
    public private(set) var modelStatus: LocalAIKitModelStatus = .idle
    public private(set) var loadedModel: LoadedModelContents?
    public private(set) var request: LocalAIKitInferenceRequest?
    public private(set) var outputText: String = ""
    public private(set) var statusMessage: String?

    public init(
        configuration: LocalAIKitConfiguration = .init(),
        modelStore: HuggingFaceModelStore? = nil,
        inferenceEngine: (any LocalAIKitInferenceEngine)? = nil
    ) {
        self.configuration = configuration
        let resolvedModelStore = modelStore ?? HuggingFaceModelStore(cacheRoot: configuration.modelsDirectory)
        self.modelStore = resolvedModelStore
        self.inferenceEngine = inferenceEngine ?? LocalAIKitInferenceEngineFactory.makeDefault()
    }

    public func resetModelState() {
        modelStatus = .idle
        loadedModel = nil
        resetInferenceState()
    }

    public func resetInferenceState() {
        request = nil
        outputText = ""
        statusMessage = nil
    }

    public var isBusy: Bool {
        modelStatus == .downloading ||
        modelStatus == .loadingIntoMemory ||
        modelStatus == .generating
    }

    public var isReady: Bool {
        modelStatus == .ready
    }

    public var modelStatusText: String {
        switch modelStatus {
        case .idle:
            return "Idle"
        case .downloading:
            return "Downloading"
        case .loadingIntoMemory:
            return "Loading into memory"
        case .generating:
            return "Generating"
        case .ready:
            return "Ready"
        case .failed(let error):
            return error.localizedDescription
        }
    }

    public func load(
        _ package: HuggingFaceModelPackage,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)? = nil
    ) async throws -> LoadedModelContents {
        resetModelState()
        modelStatus = .downloading

        let downloadManager = await MainActor.run {
            LocalAIKitDownloadManager(
                configuration: configuration,
                modelStore: modelStore
            )
        }

        do {
            let downloadedModel = try await downloadManager.prepareModel(package, onProgress: onProgress)
            modelStatus = .loadingIntoMemory

            let loaded = try loadIntoMemory(downloadedModel)
            loadedModel = loaded
            modelStatus = .ready
            return loaded
        } catch {
            modelStatus = .failed(error: error)
            throw error
        }
    }

    public func load(downloadedModel: DownloadedModel) throws -> LoadedModelContents {
        resetModelState()
        modelStatus = .loadingIntoMemory

        do {
            let loaded = try loadIntoMemory(downloadedModel)
            loadedModel = loaded
            modelStatus = .ready
            return loaded
        } catch {
            modelStatus = .failed(error: error)
            throw error
        }
    }

    public func loadIntoMemory(_ downloadedModel: DownloadedModel) throws -> LoadedModelContents {
        var loadedURLs: [String: URL] = [:]
        loadedURLs.reserveCapacity(downloadedModel.files.count)

        var loadedFiles: [String: Data] = [:]
        loadedFiles.reserveCapacity(downloadedModel.files.count)

        for (filename, fileURL) in downloadedModel.files {
            let fileData = try Data(contentsOf: fileURL)
            loadedURLs[filename] = fileURL
            loadedFiles[filename] = fileData
        }

        return LoadedModelContents(package: downloadedModel.package, fileURLs: loadedURLs, files: loadedFiles)
    }
}

public extension LocalAIKitModelManager {
    func generate(
        _ request: LocalAIKitInferenceRequest,
        using loadedModel: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        NSLog("LocalAIKit.generate(using:) started")
        resetInferenceState()
        self.request = request
        modelStatus = .generating
        statusMessage = "Generating text..."

        do {
            let wrappedPartialText: (@Sendable (String) -> Void)? = { [weak self] partialText in
                self?.outputText = partialText
                onPartialText?(partialText)
            }

            let result = try await inferenceEngine.generate(
                request: request,
                using: loadedModel,
                onPartialText: wrappedPartialText
            )
            outputText = result
            modelStatus = .ready
            statusMessage = "Generation complete."
            Self.printGeneratedResponse(result)
            return result
        } catch {
            modelStatus = .failed(error: error)
            statusMessage = error.localizedDescription
            NSLog("LocalAIKit.generate(using:) failed: \(error.localizedDescription)")
            throw error
        }
    }

    func generate(
        _ request: LocalAIKitInferenceRequest,
        using downloadedModel: DownloadedModel,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let loadedModel = try load(downloadedModel: downloadedModel)
        return try await generate(request, using: loadedModel, onPartialText: onPartialText)
    }

    func generate(
        _ request: LocalAIKitInferenceRequest,
        package: HuggingFaceModelPackage,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let loadedModel = try await load(package, onProgress: nil)
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
        return try decodeStructuredOutput(result, as: type)
    }

    func generateStructured<T: Decodable>(
        _ request: LocalAIKitInferenceRequest,
        as type: T.Type = T.self,
        using downloadedModel: DownloadedModel,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let loadedModel = try load(downloadedModel: downloadedModel)
        return try await generateStructured(request, as: type, using: loadedModel, onPartialText: onPartialText)
    }

    func generateStructured<T: Decodable>(
        _ request: LocalAIKitInferenceRequest,
        as type: T.Type = T.self,
        package: HuggingFaceModelPackage,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let loadedModel = try await load(package, onProgress: nil)
        return try await generateStructured(request, as: type, using: loadedModel, onPartialText: onPartialText)
    }

    private static func printGeneratedResponse(_ response: String) {
        let response = response.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("LocalAIKit response:")
        NSLog(response.isEmpty ? "(empty response)" : response)
    }

    private func decodeStructuredOutput<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        let candidateText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateText.isEmpty else {
            throw LocalAIKitInferenceError.structuredOutputEmpty
        }

        let jsonCandidates = Self.extractJSONCandidates(from: candidateText)
        guard !jsonCandidates.isEmpty else {
            throw LocalAIKitInferenceError.structuredOutputMissingJSON
        }

        var lastDecodingError: Error?
        for jsonText in jsonCandidates {
            do {
                return try JSONDecoder().decode(T.self, from: Data(jsonText.utf8))
            } catch {
                lastDecodingError = error
            }
        }

        throw LocalAIKitInferenceError.structuredOutputDecodingFailed(
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
