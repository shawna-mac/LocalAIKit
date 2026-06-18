//
//  LocalAIKitModelManager.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

/// A pluggable inference backend that turns a loaded model and request into generated text.
public protocol LocalAIKitInferenceEngine: Sendable {
    /// Generates text for the supplied request and loaded model.
    ///
    /// - Parameters:
    ///   - request: The inference request to execute.
    ///   - model: The loaded model contents to generate from.
    ///   - onPartialText: Optional callback that receives incremental text updates while generation is in progress.
    /// - Returns: The final generated text.
    func generate(
        request: LocalAIKitInferenceRequest,
        using model: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)?
    ) async throws -> String
}

/// Creates the default inference engine used by LocalAIKit when no custom engine is supplied.
public enum LocalAIKitInferenceEngineFactory {
    /// Returns the default inference engine for the current platform and build configuration.
    ///
    /// - Returns: The default `LocalAIKitInferenceEngine` implementation.
    public static func makeDefault() -> any LocalAIKitInferenceEngine {
        return LlamaCppInferenceEngine()
    }
}

/// Owns model downloads, model loading, and generation state for a LocalAIKit session.
@Observable
public final class LocalAIKitModelManager: @unchecked Sendable {
    /// The configuration used to resolve model storage locations and related settings.
    public let configuration: LocalAIKitConfiguration
    /// The cache and request builder used to resolve Hugging Face model assets.
    public let modelStore: HuggingFaceModelStore
    /// The inference engine used to generate text from loaded model contents.
    public let inferenceEngine: any LocalAIKitInferenceEngine
    /// The current model lifecycle status.
    public private(set) var modelStatus: LocalAIKitModelStatus = .idle
    /// The most recently loaded model contents, if loading succeeded.
    public private(set) var loadedModel: LoadedModelContents?
    /// The most recent inference request, if a generation is in progress or just completed.
    public private(set) var request: LocalAIKitInferenceRequest?
    /// The latest generated text snapshot produced by the current manager session.
    public private(set) var outputText: String = ""

    /// Creates a model manager with optional custom configuration, model store, and inference engine.
    ///
    /// - Parameters:
    ///   - configuration: The configuration used to locate and manage local model files.
    ///   - modelStore: An optional custom Hugging Face model store.
    ///   - inferenceEngine: An optional custom inference engine implementation.
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

    /// Resets the loaded model and inference snapshot state back to idle values.
    public func resetModelState() {
        modelStatus = .idle
        loadedModel = nil
        resetInferenceState()
    }

    /// Clears the current request and generated text without changing the model lifecycle state.
    public func resetInferenceState() {
        request = nil
        outputText = ""
    }

    /// Indicates whether the manager is currently busy loading or generating.
    public var isBusy: Bool {
        modelStatus == .downloading ||
        modelStatus == .loadingIntoMemory ||
        modelStatus == .generating
    }

    /// Indicates whether the manager has a ready-to-use loaded model.
    public var isReady: Bool {
        modelStatus == .ready
    }

    /// Returns a user-facing summary string for the current model lifecycle state.
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

    /// Downloads a Hugging Face package, loads it into memory, and updates observable model state.
    ///
    /// - Parameters:
    ///   - package: The Hugging Face model package to download and load.
    ///   - onProgress: Optional async callback that receives coarse progress updates while assets download.
    /// - Returns: The loaded model contents.
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

    /// Loads already-downloaded model files into memory and updates observable model state.
    ///
    /// - Parameters:
    ///   - downloadedModel: The downloaded model files to load into memory.
    /// - Returns: The loaded model contents.
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

    /// Loads a previously downloaded model identified by a tracked download record.
    ///
    /// - Parameters:
    ///   - download: The completed download record whose cached files should be loaded into memory.
    /// - Returns: The loaded model contents.
    public func load(download: LocalAIKitModelDownload) throws -> LoadedModelContents {
        resetModelState()
        modelStatus = .loadingIntoMemory

        do {
            let downloadedModel = try modelStore.downloadedModel(for: download.package)
            let loaded = try loadIntoMemory(downloadedModel)
            loadedModel = loaded
            modelStatus = .ready
            return loaded
        } catch {
            modelStatus = .failed(error: error)
            throw error
        }
    }

    /// Loads the files from disk into memory and returns a `LoadedModelContents` snapshot.
    ///
    /// - Parameters:
    ///   - downloadedModel: The downloaded model to load into memory.
    /// - Returns: The in-memory representation of the model files.
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
    /// Generates plain text from a request using already loaded model contents.
    ///
    /// - Parameters:
    ///   - request: The inference request to execute.
    ///   - loadedModel: The in-memory model contents to generate from.
    ///   - onPartialText: Optional async callback that receives incremental text updates while generation is in progress.
    /// - Returns: The final generated text.
    func generate(
        _ request: LocalAIKitInferenceRequest,
        using loadedModel: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        NSLog("LocalAIKit.generate(using:) started")
        resetInferenceState()
        self.request = request
        modelStatus = .generating

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
            Self.printGeneratedResponse(result)
            return result
        } catch {
            modelStatus = .failed(error: error)
            NSLog("LocalAIKit.generate(using:) failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Loads a downloaded model into memory and then generates plain text from the request.
    ///
    /// - Parameters:
    ///   - request: The inference request to execute.
    ///   - downloadedModel: The downloaded model files to load and generate from.
    ///   - onPartialText: Optional async callback that receives incremental text updates while generation is in progress.
    /// - Returns: The final generated text.
    func generate(
        _ request: LocalAIKitInferenceRequest,
        using downloadedModel: DownloadedModel,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let loadedModel = try load(downloadedModel: downloadedModel)
        return try await generate(request, using: loadedModel, onPartialText: onPartialText)
    }

    /// Downloads a Hugging Face package, loads it into memory, and generates plain text from the request.
    ///
    /// - Parameters:
    ///   - request: The inference request to execute.
    ///   - package: The Hugging Face model package to download, load, and generate from.
    ///   - onPartialText: Optional async callback that receives incremental text updates while generation is in progress.
    /// - Returns: The final generated text.
    func generate(
        _ request: LocalAIKitInferenceRequest,
        package: HuggingFaceModelPackage,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let loadedModel = try await load(package, onProgress: nil)
        return try await generate(request, using: loadedModel, onPartialText: onPartialText)
    }

    /// Generates structured output from already loaded model contents and decodes it into the requested Swift type.
    ///
    /// - Parameters:
    ///   - request: The inference request to execute.
    ///   - type: The `Decodable` type to decode the structured response into.
    ///   - loadedModel: The in-memory model contents to generate from.
    ///   - onPartialText: Optional async callback that receives incremental text updates while generation is in progress.
    /// - Returns: The decoded structured output.
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

    /// Loads a downloaded model into memory and generates structured output decoded into the requested Swift type.
    ///
    /// - Parameters:
    ///   - request: The inference request to execute.
    ///   - type: The `Decodable` type to decode the structured response into.
    ///   - downloadedModel: The downloaded model files to load and generate from.
    ///   - onPartialText: Optional async callback that receives incremental text updates while generation is in progress.
    /// - Returns: The decoded structured output.
    func generateStructured<T: Decodable>(
        _ request: LocalAIKitInferenceRequest,
        as type: T.Type = T.self,
        using downloadedModel: DownloadedModel,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let loadedModel = try load(downloadedModel: downloadedModel)
        return try await generateStructured(request, as: type, using: loadedModel, onPartialText: onPartialText)
    }

    /// Downloads a Hugging Face package, loads it into memory, and generates structured output decoded into the requested Swift type.
    ///
    /// - Parameters:
    ///   - request: The inference request to execute.
    ///   - type: The `Decodable` type to decode the structured response into.
    ///   - package: The Hugging Face model package to download, load, and generate from.
    ///   - onPartialText: Optional async callback that receives incremental text updates while generation is in progress.
    /// - Returns: The decoded structured output.
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

public extension LocalAIKitModelManager {
    func makeAgent(agentTemplate: LocalAIKitAgentTemplate) -> LocalAIKitAgent {
        LocalAIKitAgent(agentTemplate: agentTemplate)
    }

    func generateStructured<T: Decodable>(
        _ agent: LocalAIKitAgent,
        prompt: String,
        as type: T.Type = T.self,
        using loadedModel: LoadedModelContents,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> T {
        let request = agent.makeStructuredRequest(
            prompt: prompt,
            history: history,
            overrideSystemPrompt: overrideSystemPrompt
        )

        return try await generateStructured(
            request,
            as: type,
            using: loadedModel,
            onPartialText: onPartialText
        )
    }

    func run(
        _ agent: LocalAIKitAgent,
        prompt: String,
        using loadedModel: LoadedModelContents,
        history: [LocalAIKitConversationTurn] = [],
        overrideSystemPrompt: String? = nil,
        onPartialText: (@Sendable (String) -> Void)? = nil
    ) async throws -> LocalAIKitAgentRunResult {
        try await agent.run(
            prompt: prompt,
            using: self,
            loadedModel: loadedModel,
            history: history,
            overrideSystemPrompt: overrideSystemPrompt,
            onPartialText: onPartialText
        )
    }
}
