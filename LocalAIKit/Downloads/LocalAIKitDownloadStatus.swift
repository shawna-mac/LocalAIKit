//
//  LocalAIKitDownloadStatus.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/13/26.
//

import Foundation

public enum LocalAIKitDownloadStatus: Sendable, Hashable, Codable {
    case queued
    case downloading
    case finished
    case failed(message: String)
    case cancelled
}

extension LocalAIKitDownloadStatus {
    var isActive: Bool {
        switch self {
        case .queued, .downloading:
            return true
        case .finished, .failed, .cancelled:
            return false
        }
    }
}
