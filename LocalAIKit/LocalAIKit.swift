//
//  LocalAIKit.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/1/26.
//

import Foundation

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
        files.values.first
    }
}

public enum LocalAIKitError: Error, Equatable {
    case emptyModelPackage
    case invalidRepository
    case invalidRemoteURL
    case invalidHTTPStatus(code: Int)
    case unableToCreateDirectory(URL)
    case checksumMismatch(expected: String, actual: String)
}

public final class LocalAIKitClient {
    public let configuration: LocalAIKitConfiguration
    public let modelDownloader: HuggingFaceModelDownloader

    public init(
        configuration: LocalAIKitConfiguration = .init(),
        modelDownloader: HuggingFaceModelDownloader? = nil
    ) {
        self.configuration = configuration
        self.modelDownloader = modelDownloader ?? HuggingFaceModelDownloader(cacheRoot: configuration.modelsDirectory)
    }

    public func prepareModel(_ package: HuggingFaceModelPackage) async throws -> DownloadedModel {
        try await modelDownloader.download(package)
    }
}
