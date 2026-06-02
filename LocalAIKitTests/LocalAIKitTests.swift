import XCTest
@testable import LocalAIKit

final class LocalAIKitTests: XCTestCase {
    func testDefaultModelsDirectoryUsesApplicationSupportWhenAvailable() {
        let configuration = LocalAIKitConfiguration(modelsDirectory: nil, fileManager: .default)
        XCTAssertTrue(configuration.modelsDirectory.path.contains("LocalAIKit/Models"))
    }

    func testDownloadCacheKeySeparatesRepositoryAndRevision() throws {
        let downloader = HuggingFaceModelDownloader(cacheRoot: FileManager.default.temporaryDirectory)
        let packageA = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model-a", revision: "main"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )
        let packageB = HuggingFaceModelPackage(
            repository: HuggingFaceRepository(identifier: "org/model-a", revision: "v2"),
            assets: [HuggingFaceModelAsset(filename: "model.gguf")]
        )

        XCTAssertNotEqual(
            downloader.cacheKey(for: packageA),
            downloader.cacheKey(for: packageB)
        )
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
}
