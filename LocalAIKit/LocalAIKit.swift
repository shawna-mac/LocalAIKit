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
