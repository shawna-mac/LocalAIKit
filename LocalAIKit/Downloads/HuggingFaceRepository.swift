//
//  HuggingFaceRepository.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/13/26.
//

import Foundation

public struct HuggingFaceRepository: Sendable, Hashable, Codable {
    public var identifier: String
    public var revision: String
    public var accessToken: String?

    public init(identifier: String, revision: String = "main", accessToken: String? = nil) {
        self.identifier = identifier
        self.revision = revision
        self.accessToken = accessToken
    }
}
