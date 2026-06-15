//
//  LocalAIKitClient.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

public final class LocalAIKitClient: @unchecked Sendable {
    public let configuration: LocalAIKitConfiguration
    public let modelStore: HuggingFaceModelStore
    public let inferenceEngine: any LocalAIKitInferenceEngine

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

public extension LocalAIKitClient {
    @MainActor
    func prepareModel(
        _ package: HuggingFaceModelPackage,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)? = nil
    ) async throws -> DownloadedModel {
        try await LocalAIKitDownloadManager(
            configuration: configuration,
            modelStore: modelStore
        )
        .prepareModel(package, onProgress: onProgress)
    }

    @MainActor
    func loadModel(
        _ package: HuggingFaceModelPackage,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)? = nil
    ) async throws -> LoadedModelContents {
        let downloadedModel = try await prepareModel(package, onProgress: onProgress)
        return try loadIntoMemory(downloadedModel)
    }
}
