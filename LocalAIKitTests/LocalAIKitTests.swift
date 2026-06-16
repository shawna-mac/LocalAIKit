import XCTest
@testable import LocalAIKit

final class LocalAIKitTests: XCTestCase {
    func testDefaultModelsDirectoryUsesApplicationSupportWhenAvailable() {
        let configuration = LocalAIKitConfiguration(modelsDirectory: nil, fileManager: .default)
        XCTAssertTrue(configuration.modelsDirectory.path.contains("LocalAIKit/Models"))
    }

    func testDownloadCacheKeySeparatesRepositoryAndRevision() throws {
        let modelStore = HuggingFaceModelStore(cacheRoot: FileManager.default.temporaryDirectory)
        let packageA = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model-a", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )
        let packageB = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model-a", revision: "v2"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        XCTAssertNotEqual(
            modelStore.cacheKey(for: packageA),
            modelStore.cacheKey(for: packageB)
        )
    }

    func testModelStoreDeletesDownloadedModelFromDisk() throws {
        let store = HuggingFaceModelStore(cacheRoot: FileManager.default.temporaryDirectory)
        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        try store.preparePackageDirectory(for: package)
        let fileURL = store.destinationURL(for: package, asset: package.assets[0])
        try Data("hello llama".utf8).write(to: fileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))

        try store.deleteDownloadedModel(for: package)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
    }

    func testDeleteModelThrowsWhenDownloadIsMissing() {
        let manager = LocalAIKitDownloadManager()

        XCTAssertThrowsError(try manager.deleteModel(id: "missing-download")) { error in
            guard case LocalAIKitError.downloadNotFound(let id) = error else {
                return XCTFail("Expected downloadNotFound, got \(error)")
            }

            XCTAssertEqual(id, "missing-download")
        }
    }

    func testDownloadedModelReturnsMatchingURL() {
        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )
        let url = URL(fileURLWithPath: "/tmp/model.gguf")
        let model = DownloadedModel(package: package, files: ["model.gguf": url])

        XCTAssertEqual(model.url(for: "model.gguf"), url)
        XCTAssertEqual(model.primaryFileURL, url)
    }

    func testClientLoadsDownloadedModelIntoMemory() throws {
        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expectedData = Data("hello llama".utf8)
        try expectedData.write(to: fileURL)

        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let client = LocalAIKitModelManager()
        let loadedModel = try client.loadIntoMemory(downloadedModel)

        XCTAssertEqual(loadedModel.data(for: "model.gguf"), expectedData)
        XCTAssertEqual(loadedModel.primaryFileData, expectedData)
        XCTAssertEqual(loadedModel.url(for: "model.gguf"), fileURL)
        XCTAssertEqual(loadedModel.primaryFileURL, fileURL)
        XCTAssertEqual(loadedModel.totalByteCount, expectedData.count)
    }

    func testClientUpdatesModelStatusAndLoadedModel() async throws {
        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expectedData = Data([0x01, 0x02, 0x03])
        try? expectedData.write(to: fileURL)

        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let client = LocalAIKitModelManager()

        let loadedModel = try client.load(downloadedModel: downloadedModel)

        let modelStatus = client.modelStatus
        let clientLoadedModel = client.loadedModel
        let isBusy = client.isBusy

        XCTAssertEqual(modelStatus, .ready)
        XCTAssertEqual(loadedModel.data(for: "model.gguf"), expectedData)
        XCTAssertEqual(clientLoadedModel?.data(for: "model.gguf"), expectedData)
        XCTAssertFalse(isBusy)
    }

    func testClientGenerateUsesConfiguredInferenceEngine() async throws {
        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let engine = StubInferenceEngine(result: "hello from llama.cpp")
        let client = LocalAIKitModelManager(inferenceEngine: engine)
        let request = LocalAIKitInferenceRequest(prompt: "Say hello")

        let result = try await client.generate(request, using: downloadedModel)

        XCTAssertEqual(result, "hello from llama.cpp")
        XCTAssertEqual(await engine.receivedRequest()?.prompt, "Say hello")
        XCTAssertEqual(await engine.receivedModel()?.primaryFileURL, fileURL)
    }

    func testClientGenerateStructuredDecodesCodableOutput() async throws {
        struct ContactCard: Codable, Equatable {
            var name: String
            var age: Int
            var isActive: Bool
        }

        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let engine = StubInferenceEngine(result: #"{"name":"Ava","age":29,"isActive":true}"#)
        let client = LocalAIKitModelManager(inferenceEngine: engine)
        let request = LocalAIKitInferenceRequest(prompt: "Return a contact card")

        let decoded = try await client.generateStructured(request, as: ContactCard.self, using: downloadedModel)

        XCTAssertEqual(decoded, ContactCard(name: "Ava", age: 29, isActive: true))
        XCTAssertEqual(await engine.receivedRequest()?.systemPrompt?.contains("Return only valid JSON"), true)
    }

    func testClientGenerateStructuredExtractsJSONObjectFromNoisyOutput() async throws {
        struct ContactCard: Codable, Equatable {
            var name: String
            var title: String
            var email: String
        }

        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let noisyText = """
        ```json
        {
          "name": "Taylor Chen",
          "title": "product engineer",
          "email": "taylor@localaikit.dev"
        }
        ```
        The JSON must decode cleanly into the requested Swift type.
        ```json
        {
          "name": "Taylor Chen",
          "title": "product engineer",
          "email": "taylor@localaikit.dev"
        }
        ```
        """

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let engine = StubInferenceEngine(result: noisyText)
        let client = LocalAIKitModelManager(inferenceEngine: engine)
        let request = LocalAIKitInferenceRequest(prompt: "Return a contact card")

        let decoded = try await client.generateStructured(request, as: ContactCard.self, using: downloadedModel)

        XCTAssertEqual(
            decoded,
            ContactCard(
                name: "Taylor Chen",
                title: "product engineer",
                email: "taylor@localaikit.dev"
            )
        )
    }

    func testClientGenerateStructuredSkipsSwiftCodeAndDecodesLaterJSON() async throws {
        struct ModelPayload: Codable, Equatable {
            var model: Model

            struct Model: Codable, Equatable {
                var id: Int
                var name: String
                var parameters: [String]
            }
        }

        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let noisyText = """
        ```swift
        import Foundation

        struct ModelParameters: Identifiable {
            let id: Int
            let name: String
            let parameters: [String: Any]
        }
        ```

        The JSON must decode cleanly into the requested Swift type.
        ```json
        {
          "model": {
            "id": 1,
            "name": "Gemma-3-1b-it",
            "parameters": [
              "Write a short story about a cat."
            ]
          }
        }
        ```
        """

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let engine = StubInferenceEngine(result: noisyText)
        let client = LocalAIKitModelManager(inferenceEngine: engine)
        let request = LocalAIKitInferenceRequest(prompt: "Return structured output")

        let decoded = try await client.generateStructured(request, as: ModelPayload.self, using: downloadedModel)

        XCTAssertEqual(
            decoded,
            ModelPayload(
                model: .init(id: 1, name: "Gemma-3-1b-it", parameters: ["Write a short story about a cat."])
            )
        )
    }

    func testClientGenerateStructuredFromAgentConvenienceMethod() async throws {
        struct ContactCard: Codable, Equatable {
            var name: String
            var title: String
            var email: String
        }

        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let engine = StubInferenceEngine(result: #"{"name":"Ava","title":"Engineer","email":"ava@example.com"}"#)
        let client = LocalAIKitModelManager(inferenceEngine: engine)
        let agent = client.makeAgent(blueprint: LocalAIKitAgentBlueprintPreset.structuredExtractor.blueprint)

        let decoded = try await client.generateStructured(
            agent,
            prompt: "Extract a contact card.",
            as: ContactCard.self,
            using: downloadedModel
        )

        XCTAssertEqual(decoded, ContactCard(name: "Ava", title: "Engineer", email: "ava@example.com"))
        XCTAssertEqual(await engine.receivedRequest()?.systemPrompt?.contains("Return only valid JSON"), true)
    }

    func testStructuredOutputErrorsProvideReadableDescriptions() {
        XCTAssertEqual(
            LocalAIKitInferenceError.structuredOutputEmpty.localizedDescription,
            "Structured output was empty."
        )
        XCTAssertEqual(
            LocalAIKitInferenceError.structuredOutputMissingJSON.localizedDescription,
            "Structured output did not contain valid JSON."
        )
        XCTAssertEqual(
            LocalAIKitInferenceError.structuredOutputDecodingFailed(message: "Missing key").localizedDescription,
            "Structured output could not be decoded: Missing key"
        )
    }

    func testStructuredOutputErrorDescriptionIncludesDecodingContext() {
        let message = LocalAIKitInferenceError.structuredOutputDecodingFailed(
            message: "Missing key 'name' at the top level: The data couldn’t be read because it isn’t in the correct format."
        ).localizedDescription

        XCTAssertTrue(message.contains("Missing key 'name'"))
        XCTAssertTrue(message.contains("Structured output could not be decoded"))
    }

    func testDownloadItemFormatsProgressAndStatus() {
        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let item = LocalAIKitModelDownload(
            id: "download-1",
            package: package
        )

        XCTAssertEqual(item.downloadStatus, .queued)
        XCTAssertEqual(item.progressPercentage, 0)
        XCTAssertEqual(item.statusText, "Queued")

        XCTAssertEqual(item.displayName, "org/model @ main")
    }

    func testAgentBlueprintBuildsChatRequest() {
        let agent = LocalAIKitAgent(blueprint: LocalAIKitAgentBlueprintPreset.generalAssistant.blueprint)
        let request = agent.makeChatRequest(
            prompt: "Hello there",
            history: [
                LocalAIKitConversationTurn(role: .user, text: "My name is Ava."),
                LocalAIKitConversationTurn(role: .assistant, text: "Nice to meet you, Ava.")
            ]
        )

        XCTAssertTrue(request.prompt.contains("User: My name is Ava."))
        XCTAssertTrue(request.prompt.contains("Assistant: Nice to meet you, Ava."))
        XCTAssertEqual(request.maxTokens, 256)
        XCTAssertEqual(request.temperature, 0.7)
        XCTAssertTrue(request.systemPrompt?.contains("helpful assistant") == true)
    }

    func testStructuredAgentBlueprintBuildsStructuredRequest() {
        let agent = LocalAIKitAgent(blueprint: LocalAIKitAgentBlueprintPreset.structuredExtractor.blueprint)
        let request = agent.makeStructuredRequest(prompt: "Extract contact info from this text.")

        XCTAssertEqual(request.temperature, 0)
        XCTAssertEqual(request.topP, 1)
        XCTAssertEqual(request.topK, 1)
        XCTAssertTrue(request.systemPrompt?.contains("Return only valid JSON") == true)
        XCTAssertTrue(request.systemPrompt?.contains("Example JSON") == true)
    }

    func testAgentToolLoopCallsRegisteredToolAndReturnsFinalResponse() async throws {
        struct TimeLookupInput: Codable, Equatable {
            var timezone: String
        }

        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let agent = Agent(title: "Time Agent", systemPrompt: "Use tools when helpful.")
            .register(
                "get_current_time",
                description: "Returns the current time for a timezone.",
                inputExample: TimeLookupInput(timezone: "America/Chicago")
            ) { input in
                return [
                    "timezone": input.timezone,
                    "currentTime": "2026-06-06T12:00:00Z"
                ]
            }

        let firstEnvelope = #"{"kind":"toolCall","tool":{"name":"get_current_time","arguments":{"timezone":"America/Chicago"}}}"#
        let secondEnvelope = #"{"kind":"final","response":"It is noon in Chicago."}"#
        let engine = SequenceInferenceEngine(results: [
            firstEnvelope,
            secondEnvelope
        ])
        let client = LocalAIKitModelManager(inferenceEngine: engine)

        let runResult = try await client.run(
            agent,
            prompt: "What time is it in Chicago?",
            using: downloadedModel
        )

        XCTAssertEqual(runResult.finalResponse, "It is noon in Chicago.")
        XCTAssertEqual(runResult.toolObservations.count, 1)
        XCTAssertEqual(runResult.toolObservations.first?.name, "get_current_time")
        XCTAssertTrue(runResult.toolObservations.first?.result.contains("America/Chicago") == true)
    }

    func testAgentToolLoopFallsBackToSingleToolArgumentsJSON() async throws {
        struct TimeLookupInput: Codable, Equatable {
            var timezone: String
        }

        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let agent = Agent(title: "Time Agent", systemPrompt: "Use tools when helpful.")
            .register(
                "get_current_time",
                description: "Returns the current time for a timezone.",
                inputExample: TimeLookupInput(timezone: "America/Chicago")
            ) { input in
                return "Time lookup for \(input.timezone)"
            }

        let engine = SequenceInferenceEngine(results: [
            """
            The JSON must decode cleanly into the requested Swift type.
            ```json
            {
              "timezone": "America/Chicago"
            }
            ```
            """,
            #"{"kind":"final","response":"Done."}"#
        ])
        let client = LocalAIKitModelManager(inferenceEngine: engine)

        let runResult = try await client.run(
            agent,
            prompt: "What time is it in Chicago?",
            using: downloadedModel
        )

        XCTAssertEqual(runResult.finalResponse, "Done.")
        XCTAssertEqual(runResult.toolObservations.count, 1)
        XCTAssertEqual(runResult.toolObservations.first?.name, "get_current_time")
        XCTAssertEqual(runResult.toolObservations.first?.result, "Time lookup for America/Chicago")
    }

    func testModelManagerUpdatesWhenGenerationCompletes() async throws {
        let package = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let downloadedModel = DownloadedModel(package: package, files: ["model.gguf": fileURL])
        let engine = StubInferenceEngine(result: "generated text")
        let client = LocalAIKitModelManager(inferenceEngine: engine)

        let generatedText = try await client.generate(
            LocalAIKitInferenceRequest(prompt: "Write a sentence"),
            using: downloadedModel
        )

        XCTAssertEqual(generatedText, "generated text")
        XCTAssertEqual(client.modelStatus, .ready)
        XCTAssertEqual(client.request?.prompt, "Write a sentence")
        XCTAssertEqual(client.outputText, "generated text")
        XCTAssertEqual(client.statusMessage, "Generation complete.")
    }
}

private actor StubInferenceEngine: LocalAIKitInferenceEngine {
    let result: String
    private var receivedRequestStorage: LocalAIKitInferenceRequest?
    private var receivedModelStorage: LoadedModelContents?

    init(result: String) {
        self.result = result
    }

    func generate(
        request: LocalAIKitInferenceRequest,
        using model: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)?
    ) async throws -> String {
        receivedRequestStorage = request
        receivedModelStorage = model
        onPartialText?(result)
        return result
    }

    func receivedRequest() -> LocalAIKitInferenceRequest? {
        receivedRequestStorage
    }

    func receivedModel() -> LoadedModelContents? {
        receivedModelStorage
    }
}

private actor SequenceInferenceEngine: LocalAIKitInferenceEngine {
    private var results: [String]

    init(results: [String]) {
        self.results = results
    }

    func generate(
        request: LocalAIKitInferenceRequest,
        using model: LoadedModelContents,
        onPartialText: (@Sendable (String) -> Void)?
    ) async throws -> String {
        if results.isEmpty {
            return #"{"kind":"final","response":"No more results."}"#
        }

        let nextResult = results.removeFirst()
        onPartialText?(nextResult)
        return nextResult
    }
}
