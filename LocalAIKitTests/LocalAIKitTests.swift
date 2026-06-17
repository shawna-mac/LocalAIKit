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
