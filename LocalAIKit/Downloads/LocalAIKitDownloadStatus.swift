//
//  LocalAIKitDownloadStatus.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/13/26.
//

import Foundation

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
