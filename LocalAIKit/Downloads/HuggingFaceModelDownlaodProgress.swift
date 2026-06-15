//
//  HuggingFaceModelDownlaodProgress.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

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
