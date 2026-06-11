//
//  HuggingFaceModelDownloader.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/1/26.
//

import CryptoKit
import Foundation

public final class HuggingFaceModelDownloader: @unchecked Sendable {
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

    public func download(
        _ package: HuggingFaceModelPackage,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)? = nil
    ) async throws -> DownloadedModel {
        guard !package.repository.identifier.isEmpty else {
            throw LocalAIKitError.invalidRepository
        }

        guard !package.assets.isEmpty else {
            throw LocalAIKitError.emptyModelPackage
        }

        let packageDirectory = packageDirectory(for: package)
        try createDirectoryIfNeeded(at: packageDirectory)

        var downloadedFiles: [String: URL] = [:]
        downloadedFiles.reserveCapacity(package.assets.count)

        for (assetIndex, asset) in package.assets.enumerated() {
            try Task.checkCancellation()
            let destinationURL = destinationURL(for: package, asset: asset)

            if fileExists(at: destinationURL) {
                if let expected = asset.expectedSHA256 {
                    let actual = try checksumSHA256(for: destinationURL)
                    if actual.lowercased() != expected.lowercased() {
                        throw LocalAIKitError.checksumMismatch(expected: expected, actual: actual)
                    }
                }

                downloadedFiles[asset.filename] = destinationURL
                await reportProgress(
                    onProgress,
                    package: package,
                    asset: asset,
                    assetIndex: assetIndex,
                    assetCount: package.assets.count,
                    bytesReceived: 1,
                    bytesExpected: 1,
                    completedAssets: assetIndex + 1
                )
                continue
            }

            try createParentDirectoryIfNeeded(for: destinationURL)

            let request = try makeDownloadRequest(for: package, asset: asset)
            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LocalAIKitError.invalidHTTPStatus(code: -1)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw LocalAIKitError.invalidHTTPStatus(code: httpResponse.statusCode)
            }

            let temporaryURL = try await writeDownloadedBytes(
                bytes,
                response: httpResponse,
                onProgress: onProgress,
                package: package,
                asset: asset,
                assetIndex: assetIndex,
                assetCount: package.assets.count
            )

            try finalizeDownloadedFile(
                from: temporaryURL,
                to: destinationURL,
                expectedSHA256: asset.expectedSHA256
            )

            downloadedFiles[asset.filename] = destinationURL
            await reportProgress(
                onProgress,
                package: package,
                asset: asset,
                assetIndex: assetIndex,
                assetCount: package.assets.count,
                bytesReceived: 1,
                bytesExpected: 1,
                completedAssets: assetIndex + 1
            )
        }

        return DownloadedModel(package: package, files: downloadedFiles)
    }

    private func writeDownloadedBytes(
        _ bytes: URLSession.AsyncBytes,
        response: HTTPURLResponse,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)?,
        package: HuggingFaceModelPackage,
        asset: HuggingFaceModelAsset,
        assetIndex: Int,
        assetCount: Int
    ) async throws -> URL {
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)

        fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        var didCompleteSuccessfully = false
        defer {
            try? fileHandle.close()
            if !didCompleteSuccessfully {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let expectedBytes = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let bufferSize = 32 * 1024
        var buffer = Data()
        buffer.reserveCapacity(bufferSize)
        var receivedBytes: Int64 = 0

        await reportProgress(
            onProgress,
            package: package,
            asset: asset,
            assetIndex: assetIndex,
            assetCount: assetCount,
            bytesReceived: 0,
            bytesExpected: expectedBytes,
            completedAssets: assetIndex
        )

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            receivedBytes += 1

            if buffer.count >= bufferSize {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                await reportProgress(
                    onProgress,
                    package: package,
                    asset: asset,
                    assetIndex: assetIndex,
                    assetCount: assetCount,
                    bytesReceived: receivedBytes,
                    bytesExpected: expectedBytes,
                    completedAssets: assetIndex
                )
            }
        }

        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }

        await reportProgress(
            onProgress,
            package: package,
            asset: asset,
            assetIndex: assetIndex,
            assetCount: assetCount,
            bytesReceived: receivedBytes,
            bytesExpected: expectedBytes,
            completedAssets: assetIndex + 1
        )

        didCompleteSuccessfully = true
        return temporaryURL
    }

    private func reportProgress(
        _ onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)?,
        package: HuggingFaceModelPackage,
        asset: HuggingFaceModelAsset,
        assetIndex: Int,
        assetCount: Int,
        bytesReceived: Int64,
        bytesExpected: Int64?,
        completedAssets: Int
    ) async {
        guard let onProgress else { return }

        let fraction: Double
        if let bytesExpected, bytesExpected > 0 {
            let currentAssetFraction = min(max(Double(bytesReceived) / Double(bytesExpected), 0), 1)
            fraction = (Double(completedAssets) + currentAssetFraction) / Double(assetCount)
        } else {
            fraction = Double(completedAssets) / Double(assetCount)
        }

        await onProgress(
            HuggingFaceModelDownloadProgress(
                package: package,
                asset: asset,
                assetIndex: assetIndex,
                assetCount: assetCount,
                bytesReceived: bytesReceived,
                bytesExpected: bytesExpected,
                completedAssets: completedAssets,
                fractionCompleted: min(max(fraction, 0), 1)
            )
        )
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
        try replaceItem(at: destinationURL, withTemporaryItemAt: temporaryURL)
        do {
            try validateDownloadedFile(at: destinationURL, expectedSHA256: expectedSHA256)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
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
