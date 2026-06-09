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

public struct HuggingFaceRepository: Sendable, Hashable {
    public var identifier: String
    public var revision: String
    public var accessToken: String?

    public init(identifier: String, revision: String = "main", accessToken: String? = nil) {
        self.identifier = identifier
        self.revision = revision
        self.accessToken = accessToken
    }
}

public struct HuggingFaceModelAsset: Sendable, Hashable {
    public var filename: String
    public var destinationFilename: String?
    public var expectedSHA256: String?

    public init(
        filename: String,
        destinationFilename: String? = nil,
        expectedSHA256: String? = nil
    ) {
        self.filename = filename
        self.destinationFilename = destinationFilename
        self.expectedSHA256 = expectedSHA256
    }
}

public struct HuggingFaceModelPackage: Sendable, Hashable {
    public var repository: HuggingFaceRepository
    public var assets: [HuggingFaceModelAsset]

    public init(repository: HuggingFaceRepository, assets: [HuggingFaceModelAsset]) {
        self.repository = repository
        self.assets = assets
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

public enum LocalAIKitLoadPhase: Equatable, Sendable {
    case idle
    case downloading
    case loadingIntoMemory
    case ready
    case failed(message: String)
}

public enum LocalAIKitError: Error, Equatable, Sendable {
    case emptyModelPackage
    case invalidRepository
    case invalidRemoteURL
    case missingModelFilename
    case invalidHTTPStatus(code: Int)
    case unableToCreateDirectory(URL)
    case checksumMismatch(expected: String, actual: String)
    case inferenceEngineNotConfigured
    case noLoadedModel
}

public final class LocalAIKitClient: @unchecked Sendable {
    public let configuration: LocalAIKitConfiguration
    public let modelDownloader: HuggingFaceModelDownloader
    public let inferenceEngine: any LocalAIKitInferenceEngine

    public init(
        configuration: LocalAIKitConfiguration = .init(),
        modelDownloader: HuggingFaceModelDownloader? = nil,
        inferenceEngine: (any LocalAIKitInferenceEngine)? = nil
    ) {
        self.configuration = configuration
        self.modelDownloader = modelDownloader ?? HuggingFaceModelDownloader(cacheRoot: configuration.modelsDirectory)
        self.inferenceEngine = inferenceEngine ?? LocalAIKitInferenceEngineFactory.makeDefault()
    }

    public func prepareModel(_ package: HuggingFaceModelPackage) async throws -> DownloadedModel {
        try await modelDownloader.download(package)
    }

    public func loadModel(_ package: HuggingFaceModelPackage) async throws -> LoadedModelContents {
        let downloadedModel = try await prepareModel(package)
        return try loadIntoMemory(downloadedModel)
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
    public private(set) var phase: LocalAIKitLoadPhase = .idle
    public private(set) var downloadedModel: DownloadedModel?
    public private(set) var loadedModel: LoadedModelContents?
    public private(set) var lastErrorMessage: String?
    public private(set) var statusMessage: String?

    private let client: LocalAIKitClient

    public init(client: LocalAIKitClient = .init()) {
        self.client = client
    }

    public var isBusy: Bool {
        switch phase {
        case .downloading, .loadingIntoMemory:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    public var phaseText: String {
        String(describing: phase)
    }

    public var displayStatusText: String {
        switch phase {
        case .idle:
            return "Idle"
        case .downloading:
            return "Downloading model files..."
        case .loadingIntoMemory:
            return "Loading model files into memory..."
        case .ready:
            return "Model ready."
        case .failed(let message):
            return message
        }
    }

    public func reset() {
        phase = .idle
        downloadedModel = nil
        loadedModel = nil
        lastErrorMessage = nil
        statusMessage = nil
    }

    public func load(_ package: HuggingFaceModelPackage) async {
        reset()
        phase = .downloading
        statusMessage = "Downloading model files..."

        do {
            let downloaded = try await client.prepareModel(package)
            downloadedModel = downloaded

            phase = .loadingIntoMemory
            statusMessage = "Loading model files into memory..."

            let loaded = try client.loadIntoMemory(downloaded)
            loadedModel = loaded
            lastErrorMessage = nil
            phase = .ready
            statusMessage = "Model ready."
        } catch {
            let message = Self.message(for: error)
            lastErrorMessage = message
            statusMessage = message
            phase = .failed(message: message)
        }
    }

    public func load(downloadedModel: DownloadedModel) async {
        reset()
        self.downloadedModel = downloadedModel
        phase = .loadingIntoMemory
        statusMessage = "Loading model files into memory..."

        do {
            let loaded = try client.loadIntoMemory(downloadedModel)
            loadedModel = loaded
            lastErrorMessage = nil
            phase = .ready
            statusMessage = "Model ready."
        } catch {
            let message = Self.message(for: error)
            lastErrorMessage = message
            statusMessage = message
            phase = .failed(message: message)
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
            }
        }

        return error.localizedDescription
    }
}
