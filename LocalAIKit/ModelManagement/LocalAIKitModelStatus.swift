//
//  LocalAIKitModelStatus.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

public enum LocalAIKitModelStatus: Sendable, Equatable {
    case idle
    case downloading
    case loadingIntoMemory
    case generating
    case ready
    case failed(error: Error)

    public static func == (lhs: LocalAIKitModelStatus, rhs: LocalAIKitModelStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.downloading, .downloading),
             (.loadingIntoMemory, .loadingIntoMemory),
             (.generating, .generating),
             (.ready, .ready):
            return true
        case (.failed, .failed):
            return true
        default:
            return false
        }
    }
}
