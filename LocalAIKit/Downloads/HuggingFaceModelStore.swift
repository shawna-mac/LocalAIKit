//
//  HuggingFaceModelStore.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/1/26.
//

import CryptoKit
import Foundation

public final class HuggingFaceModelStore: @unchecked Sendable {
    private let cacheRoot: URL
    private let fileManager: FileManager

    public init(
        cacheRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot ?? LocalAIKitConfiguration.defaultModelsDirectory(fileManager: fileManager)
    }

    internal func packageDirectory(for package: HuggingFaceModelPackage) -> URL {
        cacheRoot.appendingPathComponent(cacheKey(for: package), isDirectory: true)
    }

    internal func destinationURL(for package: HuggingFaceModelPackage, asset: HuggingFaceModelAsset) -> URL {
        packageDirectory(for: package).appendingPathComponent(asset.destinationFilename ?? asset.filename)
    }

    internal func makeDownloadRequest(
        for package: HuggingFaceModelPackage,
        asset: HuggingFaceModelAsset
    ) throws -> URLRequest {
        let remoteURL = try makeRemoteURL(for: package.repository, assetFilename: asset.filename)
        return makeRequest(for: remoteURL, accessToken: package.repository.accessToken)
    }

    internal func finalizeDownloadedFile(
        from temporaryURL: URL,
        to destinationURL: URL,
        expectedSHA256: String?
    ) throws {
        try createParentDirectoryIfNeeded(for: destinationURL)
        try replaceItem(at: destinationURL, withTemporaryItemAt: temporaryURL)
        do {
            try validateDownloadedFile(at: destinationURL, expectedSHA256: expectedSHA256)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    internal func preparePackageDirectory(for package: HuggingFaceModelPackage) throws {
        try createDirectoryIfNeeded(at: packageDirectory(for: package))
    }

    internal func cachedAssetIsReady(for package: HuggingFaceModelPackage, asset: HuggingFaceModelAsset) -> Bool {
        let destinationURL = destinationURL(for: package, asset: asset)
        guard fileExists(at: destinationURL) else {
            return false
        }

        do {
            try validateDownloadedFile(at: destinationURL, expectedSHA256: asset.expectedSHA256)
            return true
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            return false
        }
    }

    internal func finalizeBackgroundDownload(
        for package: HuggingFaceModelPackage,
        assetIndex: Int,
        temporaryURL: URL
    ) throws {
        guard assetIndex < package.assets.count else {
            throw LocalAIKitError.missingBackgroundDownloadState
        }

        let asset = package.assets[assetIndex]
        try finalizeDownloadedFile(
            from: temporaryURL,
            to: destinationURL(for: package, asset: asset),
            expectedSHA256: asset.expectedSHA256
        )
    }

    internal func downloadedModel(for package: HuggingFaceModelPackage) throws -> DownloadedModel {
        guard !package.repository.identifier.isEmpty else {
            throw LocalAIKitError.invalidRepository
        }

        guard !package.assets.isEmpty else {
            throw LocalAIKitError.emptyModelPackage
        }

        var files: [String: URL] = [:]
        files.reserveCapacity(package.assets.count)

        for asset in package.assets {
            guard cachedAssetIsReady(for: package, asset: asset) else {
                throw LocalAIKitError.modelDownloadIncomplete(filename: asset.filename)
            }

            files[asset.filename] = destinationURL(for: package, asset: asset)
        }

        return DownloadedModel(package: package, files: files)
    }

    internal func validateDownloadedFile(at destinationURL: URL, expectedSHA256: String?) throws {
        guard let expectedSHA256 else {
            return
        }

        let actual = try checksumSHA256(for: destinationURL)
        if actual.lowercased() != expectedSHA256.lowercased() {
            throw LocalAIKitError.checksumMismatch(expected: expectedSHA256, actual: actual)
        }
    }

    private func makeRequest(for url: URL, accessToken: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func makeRemoteURL(for repository: HuggingFaceRepository, assetFilename: String) throws -> URL {
        let encodedRepository = encodePathComponent(repository.identifier)
        let encodedRevision = encodePathComponent(repository.revision)
        let encodedAssetPath = assetFilename
            .split(separator: "/")
            .map { encodePathComponent(String($0)) }
            .joined(separator: "/")

        let urlString = "https://huggingface.co/\(encodedRepository)/resolve/\(encodedRevision)/\(encodedAssetPath)?download=1"

        guard let url = URL(string: urlString) else {
            throw LocalAIKitError.invalidRemoteURL
        }

        return url
    }

    private func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    func cacheKey(for package: HuggingFaceModelPackage) -> String {
        let keyMaterial = [
            package.repository.identifier,
            package.repository.revision,
            package.assets.map(\.filename).sorted().joined(separator: "|")
        ]
        .joined(separator: "::")

        let digest = SHA256.hash(data: Data(keyMaterial.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func createDirectoryIfNeeded(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            return
        }

        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw LocalAIKitError.unableToCreateDirectory(url)
        }
    }

    private func createParentDirectoryIfNeeded(for url: URL) throws {
        let parentDirectory = url.deletingLastPathComponent()
        try createDirectoryIfNeeded(at: parentDirectory)
    }

    internal func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func replaceItem(at destinationURL: URL, withTemporaryItemAt temporaryURL: URL) throws {
        if fileExists(at: destinationURL) {
            try fileManager.removeItem(at: destinationURL)
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            // If the destination already exists from a concurrent caller, fall back to replacing it.
            if fileExists(at: destinationURL) {
                try fileManager.removeItem(at: destinationURL)
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            } else {
                throw error
            }
        }
    }

    private func checksumSHA256(for fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var hasher = SHA256()

        while true {
            let chunk = try fileHandle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }

            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
