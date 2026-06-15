//
//  LocalAIKitModelDownload.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

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

