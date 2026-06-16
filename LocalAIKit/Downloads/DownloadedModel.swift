//
//  DownloadedModel.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/15/26.
//

import Foundation

public struct DownloadedModel: Sendable {
    public let package: HuggingFaceModelPackage
    public let files: [String: URL]

    public init(package: HuggingFaceModelPackage, files: [String: URL]) {
        self.package = package
        self.files = files
    }

    public func url(for filename: String) -> URL? {
        files[filename]
    }

    public var primaryFileURL: URL? {
        package.assets.first.flatMap { files[$0.filename] }
    }
}
