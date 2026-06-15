//
//  Downloads.swift
//  LocalAIKit
//
//  Created by OpenAI.
//

import Foundation
import Observation

public struct HuggingFaceModelDownloadProgress: Sendable, Hashable {
    public var package: HuggingFaceModelPackage
    public var asset: HuggingFaceModelAsset
    public var assetIndex: Int
    public var assetCount: Int
    public var bytesReceived: Int64
    public var bytesExpected: Int64?
    public var completedAssets: Int
    public var fractionCompleted: Double

    public init(
        package: HuggingFaceModelPackage,
        asset: HuggingFaceModelAsset,
        assetIndex: Int,
        assetCount: Int,
        bytesReceived: Int64,
        bytesExpected: Int64?,
        completedAssets: Int,
        fractionCompleted: Double
    ) {
        self.package = package
        self.asset = asset
        self.assetIndex = assetIndex
        self.assetCount = assetCount
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.completedAssets = completedAssets
        self.fractionCompleted = fractionCompleted
    }
}

public enum LocalAIKitDownloadStatus: Sendable, Hashable, Codable {
    case queued
    case downloading
    case finished
    case failed(message: String)
    case cancelled
}

public struct LocalAIKitModelDownload: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public var package: HuggingFaceModelPackage
    public private(set) var downloadStatus: LocalAIKitDownloadStatus
    public var fractionCompleted: Double

    public init(
        id: String,
        package: HuggingFaceModelPackage
    ) {
        self.id = id
        self.package = package
        self.downloadStatus = .queued
        self.fractionCompleted = 0
    }

    public var displayName: String {
        let revision = package.repository.revision.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(package.repository.identifier) @ \(revision.isEmpty ? "main" : revision)"
    }

    public var progressPercentage: Int {
        Int((max(0, min(1, fractionCompleted)) * 100).rounded())
    }

    public var statusText: String {
        switch downloadStatus {
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading..."
        case .finished:
            return "Finished"
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }
    
    mutating func updateStatus(_ status: LocalAIKitDownloadStatus) {
        self.downloadStatus = status
    }
}

struct LocalAIKitBackgroundDownloadTaskMetadata: Codable, Hashable, Sendable {
    var downloadID: String
    var assetIndex: Int
}

struct LocalAIKitDownloadManifest: Codable {
    var downloads: [LocalAIKitModelDownload]
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
