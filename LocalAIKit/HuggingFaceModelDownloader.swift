//
//  HuggingFaceModelDownloader.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/1/26.
//

import CryptoKit
import Foundation

public final class HuggingFaceModelDownloader {
    private let cacheRoot: URL
    private let fileManager: FileManager
    private let session: URLSession

    public init(
        cacheRoot: URL? = nil,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.session = session
        self.cacheRoot = cacheRoot ?? LocalAIKitConfiguration.defaultModelsDirectory(fileManager: fileManager)
    }

    public func download(_ package: HuggingFaceModelPackage) async throws -> DownloadedModel {
        guard !package.repository.identifier.isEmpty else {
            throw LocalAIKitError.invalidRepository
        }

        guard !package.assets.isEmpty else {
            throw LocalAIKitError.emptyModelPackage
        }

        let packageDirectory = cacheRoot.appendingPathComponent(cacheKey(for: package), isDirectory: true)
        try createDirectoryIfNeeded(at: packageDirectory)

        var downloadedFiles: [String: URL] = [:]
        downloadedFiles.reserveCapacity(package.assets.count)

        for asset in package.assets {
            let destinationURL = packageDirectory.appendingPathComponent(asset.destinationFilename ?? asset.filename)

            if fileExists(at: destinationURL) {
                if let expected = asset.expectedSHA256 {
                    let actual = try checksumSHA256(for: destinationURL)
                    if actual.lowercased() != expected.lowercased() {
                        throw LocalAIKitError.checksumMismatch(expected: expected, actual: actual)
                    }
                }

                downloadedFiles[asset.filename] = destinationURL
                continue
            }

            try createParentDirectoryIfNeeded(for: destinationURL)

            let remoteURL = try makeRemoteURL(for: package.repository, assetFilename: asset.filename)
            let request = makeRequest(for: remoteURL, accessToken: package.repository.accessToken)
            let (temporaryURL, response) = try await session.download(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LocalAIKitError.invalidHTTPStatus(code: -1)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw LocalAIKitError.invalidHTTPStatus(code: httpResponse.statusCode)
            }

            try replaceItem(at: destinationURL, withTemporaryItemAt: temporaryURL)

            if let expected = asset.expectedSHA256 {
                let actual = try checksumSHA256(for: destinationURL)
                if actual.lowercased() != expected.lowercased() {
                    throw LocalAIKitError.checksumMismatch(expected: expected, actual: actual)
                }
            }

            downloadedFiles[asset.filename] = destinationURL
        }

        return DownloadedModel(package: package, files: downloadedFiles)
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

    private func fileExists(at url: URL) -> Bool {
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
