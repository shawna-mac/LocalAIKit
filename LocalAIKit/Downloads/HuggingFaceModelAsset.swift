//
//  HuggingFaceModelAsset.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/13/26.
//

import Foundation

public struct HuggingFaceModelAsset: Sendable, Hashable, Codable {
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
