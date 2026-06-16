//
//  HuggingFaceModelPackage.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/13/26.
//

import Foundation

public struct HuggingFaceModelPackage: Sendable, Hashable, Codable {
    public var repository: HuggingFaceRepository
    public var assets: [HuggingFaceModelAsset]

    public init(repository: HuggingFaceRepository, assets: [HuggingFaceModelAsset]) {
        self.repository = repository
        self.assets = assets
    }
}
