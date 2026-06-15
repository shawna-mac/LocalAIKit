//
//  LocalAIKit.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/1/26.
//

import Foundation
import Observation

public struct LocalAIKitConfiguration: Sendable {
    public var modelsDirectory: URL

    public init(modelsDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.modelsDirectory = modelsDirectory ?? Self.defaultModelsDirectory(fileManager: fileManager)
    }

    public static func defaultModelsDirectory(fileManager: FileManager = .default) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory

        return baseDirectory
            .appendingPathComponent("LocalAIKit", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }
}

public struct DownloadedModel: Sendable {
    public let package: HuggingFaceModelPackage
    public let files: [String: URL]

    public init(package: HuggingFaceModelPackage, files: [String: URL]) {
        self.package = package
        self.files = files
    }

    public func url(for filename: String) -> URL? {
        files[filename]
    }

    public var primaryFileURL: URL? {
        package.assets.first.flatMap { files[$0.filename] }
    }
}

public struct LoadedModelContents: Sendable {
    public let package: HuggingFaceModelPackage
    public let fileURLs: [String: URL]
    public let files: [String: Data]

    public init(package: HuggingFaceModelPackage, fileURLs: [String: URL], files: [String: Data]) {
        self.package = package
        self.fileURLs = fileURLs
        self.files = files
    }

    public func url(for filename: String) -> URL? {
        fileURLs[filename]
    }

    public func data(for filename: String) -> Data? {
        files[filename]
    }

    public var primaryFileURL: URL? {
        package.assets.first.flatMap { fileURLs[$0.filename] }
    }

    public var primaryFileData: Data? {
        package.assets.first.flatMap { files[$0.filename] }
    }

    public var totalByteCount: Int {
        files.values.reduce(0) { $0 + $1.count }
    }
}

public enum LocalAIKitModelStatus: Sendable {
    case idle
    case downloading
    case loadingIntoMemory
    case ready
    case failed(error: Error)
}


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

@MainActor
@Observable
public final class LocalAIKitLoadState {
    public private(set) var modelStatus: LocalAIKitModelStatus = .idle
    public private(set) var downloadedModel: DownloadedModel?
    public private(set) var loadedModel: LoadedModelContents?

    private let client: LocalAIKitClient

    public init(client: LocalAIKitClient = .init()) {
        self.client = client
    }

    public var isBusy: Bool {
        switch modelStatus {
        case .downloading, .loadingIntoMemory:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }
    
    public var isReady: Bool {
        if case .ready = modelStatus { return true }
        return false
    }

    public var modelStatusText: String {
        String(describing: modelStatus)
    }

    @available(*, deprecated, renamed: "modelStatus")
    public var phase: LocalAIKitModelStatus {
        modelStatus
    }

    @available(*, deprecated, renamed: "modelStatusText")
    public var phaseText: String {
        modelStatusText
    }

    public func reset() {
        modelStatus = .idle
        downloadedModel = nil
        loadedModel = nil
    }

    public func load(
        _ package: HuggingFaceModelPackage,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)? = nil
    ) async {
        reset()
        modelStatus = .downloading

        do {
            let downloaded = try await client.prepareModel(package, onProgress: onProgress)
            downloadedModel = downloaded

            modelStatus = .loadingIntoMemory

            loadedModel = try client.loadIntoMemory(downloaded)
            modelStatus = .ready
        } catch {
            modelStatus = .failed(error: error)
        }
    }

    public func load(downloadedModel: DownloadedModel) async {
        reset()
        self.downloadedModel = downloadedModel
        modelStatus = .loadingIntoMemory

        do {
            loadedModel = try client.loadIntoMemory(downloadedModel)
            modelStatus = .ready
        } catch {
            modelStatus = .failed(error: error)
        }
    }

    private static func message(for error: Error) -> String {
        localAIKitMessage(for: error)
    }
}
