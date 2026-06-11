//
//  Downloads.swift
//  LocalAIKit
//
//  Created by OpenAI.
//

import Foundation
import Observation

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

public enum LocalAIKitDownloadStatus: Sendable, Hashable, Codable {
    case queued
    case downloading
    case finished
    case failed(message: String)
    case cancelled
}

public struct LocalAIKitModelDownload: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public var package: HuggingFaceModelPackage
    public var downloadStatus: LocalAIKitDownloadStatus
    public var fractionCompleted: Double
    public var currentAssetFilename: String?
    public var lastUpdated: Date

    public init(
        id: String,
        package: HuggingFaceModelPackage,
        downloadStatus: LocalAIKitDownloadStatus = .queued,
        fractionCompleted: Double = 0,
        currentAssetFilename: String? = nil,
        lastUpdated: Date = .init()
    ) {
        self.id = id
        self.package = package
        self.downloadStatus = downloadStatus
        self.fractionCompleted = fractionCompleted
        self.currentAssetFilename = currentAssetFilename
        self.lastUpdated = lastUpdated
    }

    public var displayName: String {
        let revision = package.repository.revision.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(package.repository.identifier) @ \(revision.isEmpty ? "main" : revision)"
    }

    public var progressPercentage: Int {
        Int((max(0, min(1, fractionCompleted)) * 100).rounded())
    }

    public var statusText: String {
        switch downloadStatus {
        case .queued:
            return "Queued"
        case .downloading:
            return currentAssetFilename.map { "Downloading \($0)" } ?? "Downloading..."
        case .finished:
            return "Finished"
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }
}

private struct LocalAIKitBackgroundDownloadTaskMetadata: Codable, Hashable, Sendable {
    var downloadID: String
    var assetIndex: Int
}

private struct LocalAIKitDownloadManifest: Codable {
    var downloads: [LocalAIKitModelDownload]
}

private final class LocalAIKitBackgroundDownloadFileProcessor: @unchecked Sendable {
    let downloader: HuggingFaceModelDownloader
    private let lock = NSLock()
    private var packagesByDownloadID: [String: HuggingFaceModelPackage] = [:]

    init(downloader: HuggingFaceModelDownloader) {
        self.downloader = downloader
    }

    func register(package: HuggingFaceModelPackage, downloadID: String) {
        lock.lock()
        packagesByDownloadID[downloadID] = package
        lock.unlock()
    }

    func unregister(downloadID: String) {
        lock.lock()
        packagesByDownloadID.removeValue(forKey: downloadID)
        lock.unlock()
    }

    func package(for downloadID: String) -> HuggingFaceModelPackage? {
        lock.lock()
        defer { lock.unlock() }
        return packagesByDownloadID[downloadID]
    }

    func packageDirectory(for package: HuggingFaceModelPackage) -> URL {
        downloader.packageDirectory(for: package)
    }

    func destinationURL(for package: HuggingFaceModelPackage, asset: HuggingFaceModelAsset) -> URL {
        downloader.destinationURL(for: package, asset: asset)
    }

    func makeDownloadRequest(for package: HuggingFaceModelPackage, asset: HuggingFaceModelAsset) throws -> URLRequest {
        try downloader.makeDownloadRequest(for: package, asset: asset)
    }

    func fileExists(at url: URL) -> Bool {
        downloader.fileExists(at: url)
    }

    func validateDownloadedFile(at destinationURL: URL, expectedSHA256: String?) throws {
        try downloader.validateDownloadedFile(at: destinationURL, expectedSHA256: expectedSHA256)
    }

    func finalizeDownloadedFile(metadata: LocalAIKitBackgroundDownloadTaskMetadata, location: URL) throws {
        guard
            let package = package(for: metadata.downloadID),
            metadata.assetIndex < package.assets.count
        else {
            throw LocalAIKitError.missingBackgroundDownloadState
        }

        let asset = package.assets[metadata.assetIndex]
        let destinationURL = destinationURL(for: package, asset: asset)
        try downloader.finalizeDownloadedFile(
            from: location,
            to: destinationURL,
            expectedSHA256: asset.expectedSHA256
        )
    }
}

private final class LocalAIKitBackgroundDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    weak var manager: LocalAIKitDownloadManager?
    private let fileProcessor: LocalAIKitBackgroundDownloadFileProcessor

    init(fileProcessor: LocalAIKitBackgroundDownloadFileProcessor) {
        self.fileProcessor = fileProcessor
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let metadata = Self.metadata(from: downloadTask.taskDescription) else {
            return
        }

        Task { [weak manager] in
            await manager?.handleProgress(
                metadata: metadata,
                bytesWritten: totalBytesWritten,
                bytesExpected: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let metadata = Self.metadata(from: downloadTask.taskDescription) else {
            return
        }

        do {
            try fileProcessor.finalizeDownloadedFile(metadata: metadata, location: location)
            Task { [weak manager] in
                await manager?.handleAssetFinished(metadata)
            }
        } catch {
            Task { [weak manager] in
                await manager?.handleTaskFailure(metadata: metadata, error: error)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            return
        }

        guard let metadata = Self.metadata(from: task.taskDescription) else {
            return
        }

        Task { [weak manager] in
            await manager?.handleTaskFailure(metadata: metadata, error: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { [weak manager] in
            await manager?.backgroundSessionDidFinishEvents()
        }
    }

    private static func metadata(from taskDescription: String?) -> LocalAIKitBackgroundDownloadTaskMetadata? {
        guard
            let taskDescription,
            let data = taskDescription.data(using: .utf8),
            let metadata = try? JSONDecoder().decode(LocalAIKitBackgroundDownloadTaskMetadata.self, from: data)
        else {
            return nil
        }

        return metadata
    }
}

@MainActor
@Observable
public final class LocalAIKitDownloadManager {
    public static let shared = LocalAIKitDownloadManager()

    public private(set) var downloads: [LocalAIKitModelDownload] = []

    private let client: LocalAIKitClient
    private let sessionIdentifier: String
    private let storeURL: URL
    private let fileProcessor: LocalAIKitBackgroundDownloadFileProcessor
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let delegateProxy: LocalAIKitBackgroundDownloadSessionDelegate
    @ObservationIgnored private var assetProgressByDownloadID: [String: [Int: Double]] = [:]
    @ObservationIgnored private var backgroundEventsCompletionHandler: (() -> Void)?

    public init(
        client: LocalAIKitClient = .init(),
        sessionIdentifier: String? = nil
    ) {
        self.client = client
        self.sessionIdentifier = sessionIdentifier ?? Self.defaultSessionIdentifier(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        self.storeURL = client.configuration.modelsDirectory
            .appendingPathComponent("LocalAIKitBackgroundDownloads.json")
        self.fileProcessor = LocalAIKitBackgroundDownloadFileProcessor(downloader: client.modelDownloader)

        let delegate = LocalAIKitBackgroundDownloadSessionDelegate(fileProcessor: fileProcessor)
        self.delegateProxy = delegate

        let configuration = URLSessionConfiguration.background(withIdentifier: self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        self.downloads = Self.loadManifest(from: storeURL)?.downloads ?? []
        for download in downloads {
            self.fileProcessor.register(package: download.package, downloadID: download.id)
        }
        self.delegateProxy.manager = self
        rebuildAssetProgress()

        Task { [weak self] in
            await self?.restoreBackgroundTasks()
        }
    }

    public func queue(_ package: HuggingFaceModelPackage) {
        let id = client.modelDownloader.cacheKey(for: package)

        if let activeIndex = downloads.firstIndex(where: { $0.id == id && $0.downloadStatus.isActive }) {
            downloads[activeIndex].lastUpdated = .init()
            persistDownloads()
            return
        }

        assetProgressByDownloadID[id] = [:]
        fileProcessor.register(package: package, downloadID: id)
        upsert(
            LocalAIKitModelDownload(
                id: id,
                package: package,
                downloadStatus: .queued,
                fractionCompleted: 0,
                currentAssetFilename: nil
            )
        )
        persistDownloads()

        startBackgroundDownloads(package: package, id: id)
    }

    public func cancel(id: String) {
        cancelBackgroundTasks(for: id)
        assetProgressByDownloadID[id] = nil
        update(id: id) { item in
            item.downloadStatus = .cancelled
            item.currentAssetFilename = nil
            item.lastUpdated = .init()
        }
        persistDownloads()
    }

    public func remove(id: String) {
        cancelBackgroundTasks(for: id)
        assetProgressByDownloadID[id] = nil
        fileProcessor.unregister(downloadID: id)
        downloads.removeAll { $0.id == id }
        persistDownloads()
    }

    public func clearFinished() {
        let finishedIDs = downloads.compactMap { item -> String? in
            switch item.downloadStatus {
            case .finished, .failed, .cancelled:
                return item.id
            case .queued, .downloading:
                return nil
            }
        }

        downloads.removeAll { item in
            switch item.downloadStatus {
            case .finished, .failed, .cancelled:
                return true
            case .queued, .downloading:
                return false
            }
        }
        finishedIDs.forEach { fileProcessor.unregister(downloadID: $0) }
        assetProgressByDownloadID = assetProgressByDownloadID.filter { key, _ in
            downloads.contains(where: { $0.id == key })
        }
        persistDownloads()
    }

    public func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == sessionIdentifier else {
            return
        }

        backgroundEventsCompletionHandler = completionHandler
    }

    private func startBackgroundDownloads(package: HuggingFaceModelPackage, id: String) {
        var anyTaskStarted = false
        let packageDirectory = fileProcessor.packageDirectory(for: package)

        do {
            try FileManager.default.createDirectory(
                at: packageDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            markDownloadFailed(id: id, message: localAIKitMessage(for: error))
            return
        }

        for (assetIndex, asset) in package.assets.enumerated() {
            let destinationURL = fileProcessor.destinationURL(for: package, asset: asset)

            if fileProcessor.fileExists(at: destinationURL) {
                do {
                    try fileProcessor.validateDownloadedFile(at: destinationURL, expectedSHA256: asset.expectedSHA256)
                    markAssetComplete(downloadID: id, assetIndex: assetIndex, asset: asset, package: package)
                    continue
                } catch {
                    // If the on-disk file is invalid, redownload it below.
                    try? FileManager.default.removeItem(at: destinationURL)
                }
            }

            do {
                let request = try fileProcessor.makeDownloadRequest(for: package, asset: asset)
                let task = session.downloadTask(with: request)
                task.taskDescription = Self.encodeTaskMetadata(
                    LocalAIKitBackgroundDownloadTaskMetadata(
                        downloadID: id,
                        assetIndex: assetIndex
                    )
                )
                task.resume()
                anyTaskStarted = true
            } catch {
                markDownloadFailed(id: id, message: localAIKitMessage(for: error))
                return
            }
        }

        if anyTaskStarted {
            update(id: id) { item in
                item.downloadStatus = .downloading
                item.lastUpdated = .init()
            }
        } else {
            markDownloadFinished(id: id)
        }

        persistDownloads()
    }

    private func markAssetComplete(
        downloadID: String,
        assetIndex: Int,
        asset: HuggingFaceModelAsset,
        package: HuggingFaceModelPackage
    ) {
        var progress = assetProgressByDownloadID[downloadID, default: [:]]
        progress[assetIndex] = 1
        assetProgressByDownloadID[downloadID] = progress

        update(id: downloadID) { item in
            item.downloadStatus = .downloading
            item.fractionCompleted = aggregateFraction(for: item.id, assetCount: item.package.assets.count)
            item.currentAssetFilename = asset.filename
            item.lastUpdated = .init()
        }

        if isDownloadComplete(downloadID: downloadID, package: package) {
            markDownloadFinished(id: downloadID)
        }
    }

    func handleProgress(
        metadata: LocalAIKitBackgroundDownloadTaskMetadata,
        bytesWritten: Int64,
        bytesExpected: Int64
    ) async {
        guard let download = downloads.first(where: { $0.id == metadata.downloadID }) else {
            return
        }

        let assetCount = download.package.assets.count
        guard metadata.assetIndex < assetCount else {
            return
        }

        var progress = assetProgressByDownloadID[metadata.downloadID, default: [:]]
        let assetFraction: Double
        if bytesExpected > 0 {
            assetFraction = min(max(Double(bytesWritten) / Double(bytesExpected), 0), 1)
        } else {
            assetFraction = 0
        }
        progress[metadata.assetIndex] = assetFraction
        assetProgressByDownloadID[metadata.downloadID] = progress

        update(id: metadata.downloadID) { item in
            item.downloadStatus = .downloading
            item.fractionCompleted = aggregateFraction(for: item.id, assetCount: assetCount)
            item.currentAssetFilename = download.package.assets[metadata.assetIndex].filename
            item.lastUpdated = .init()
        }

        persistDownloads()
    }

    private func handleAssetFinished(_ metadata: LocalAIKitBackgroundDownloadTaskMetadata) async {
        guard let download = downloads.first(where: { $0.id == metadata.downloadID }) else {
            return
        }

        let assetIndex = metadata.assetIndex
        guard assetIndex < download.package.assets.count else {
            return
        }

        var progress = assetProgressByDownloadID[metadata.downloadID, default: [:]]
        progress[assetIndex] = 1
        assetProgressByDownloadID[metadata.downloadID] = progress

        update(id: metadata.downloadID) { item in
            item.fractionCompleted = aggregateFraction(for: item.id, assetCount: download.package.assets.count)
            item.currentAssetFilename = download.package.assets[assetIndex].filename
            item.lastUpdated = .init()
        }

        if isDownloadComplete(downloadID: metadata.downloadID, package: download.package) {
            markDownloadFinished(id: metadata.downloadID)
        } else {
            update(id: metadata.downloadID) { item in
                item.downloadStatus = .downloading
            }
        }

        persistDownloads()
    }

    private func handleTaskFailure(metadata: LocalAIKitBackgroundDownloadTaskMetadata, error: Error) async {
        if error is CancellationError {
            markDownloadCancelled(id: metadata.downloadID)
            return
        }

        let message = localAIKitMessage(for: error)
        markDownloadFailed(id: metadata.downloadID, message: message)
    }

    private func backgroundSessionDidFinishEvents() async {
        backgroundEventsCompletionHandler?()
        backgroundEventsCompletionHandler = nil
    }

    private func restoreBackgroundTasks() async {
        let tasks = await allTasks()
        guard !tasks.isEmpty else {
            return
        }

        for task in tasks {
            guard let metadata = Self.metadata(from: task.taskDescription) else {
                continue
            }

            update(id: metadata.downloadID) { item in
                if item.downloadStatus != .finished && item.downloadStatus != .cancelled {
                    item.downloadStatus = .downloading
                    item.lastUpdated = .init()
                }
            }
        }

        persistDownloads()
    }

    private func cancelBackgroundTasks(for downloadID: String) {
        Task { [session] in
            let tasks = await Self.allTasks(in: session)
            for task in tasks {
                guard let metadata = Self.metadata(from: task.taskDescription), metadata.downloadID == downloadID else {
                    continue
                }
                task.cancel()
            }
        }
    }

    private func isDownloadComplete(downloadID: String, package: HuggingFaceModelPackage) -> Bool {
        let progress = assetProgressByDownloadID[downloadID] ?? [:]
        guard !package.assets.isEmpty else {
            return true
        }

        return package.assets.enumerated().allSatisfy { index, _ in
            (progress[index] ?? 0) >= 1
        }
    }

    private func aggregateFraction(for downloadID: String, assetCount: Int) -> Double {
        guard assetCount > 0 else {
            return 1
        }

        let progress = assetProgressByDownloadID[downloadID] ?? [:]
        let total = (0..<assetCount).reduce(0.0) { partialResult, index in
            partialResult + (progress[index] ?? 0)
        }
        return min(max(total / Double(assetCount), 0), 1)
    }

    private func markDownloadFinished(id: String) {
        update(id: id) { item in
            item.downloadStatus = .finished
            item.fractionCompleted = 1
            item.currentAssetFilename = nil
            item.lastUpdated = .init()
        }
        persistDownloads()
    }

    private func markDownloadCancelled(id: String) {
        assetProgressByDownloadID[id] = nil
        update(id: id) { item in
            item.downloadStatus = .cancelled
            item.currentAssetFilename = nil
            item.lastUpdated = .init()
        }
        persistDownloads()
    }

    private func markDownloadFailed(id: String, message: String) {
        assetProgressByDownloadID[id] = nil
        update(id: id) { item in
            item.downloadStatus = .failed(message: message)
            item.currentAssetFilename = nil
            item.lastUpdated = .init()
        }
        persistDownloads()
    }

    private func rebuildAssetProgress() {
        assetProgressByDownloadID = downloads.reduce(into: [:]) { partialResult, download in
            partialResult[download.id] = [:]
            if case .finished = download.downloadStatus {
                partialResult[download.id] = Dictionary(
                    uniqueKeysWithValues: download.package.assets.enumerated().map { ($0.offset, 1) }
                )
            }
        }
    }

    private func upsert(_ item: LocalAIKitModelDownload) {
        if let index = downloads.firstIndex(where: { $0.id == item.id }) {
            downloads[index] = item
        } else {
            downloads.append(item)
        }
    }

    private func update(id: String, _ mutate: (inout LocalAIKitModelDownload) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            return
        }

        var item = downloads[index]
        mutate(&item)
        downloads[index] = item
    }

    private func persistDownloads() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            let data = try JSONEncoder().encode(LocalAIKitDownloadManifest(downloads: downloads))
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Persistence failure should not break downloads; state will still be held in memory.
        }
    }

    private static func loadManifest(from url: URL) -> LocalAIKitDownloadManifest? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(LocalAIKitDownloadManifest.self, from: data)
    }

    private static func defaultSessionIdentifier(bundleIdentifier: String?) -> String {
        let base = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.map { "\($0).LocalAIKit.background-downloads" } ?? "LocalAIKit.background-downloads"
    }

    private static func encodeTaskMetadata(_ metadata: LocalAIKitBackgroundDownloadTaskMetadata) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func metadata(from taskDescription: String?) -> LocalAIKitBackgroundDownloadTaskMetadata? {
        guard
            let taskDescription,
            let data = taskDescription.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder().decode(LocalAIKitBackgroundDownloadTaskMetadata.self, from: data)
    }

    private func allTasks() async -> [URLSessionTask] {
        await Self.allTasks(in: session)
    }

    private static func allTasks(in session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }
}

public extension LocalAIKitClient {
    public func prepareModel(
        _ package: HuggingFaceModelPackage,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)? = nil
    ) async throws -> DownloadedModel {
        try await modelDownloader.download(package, onProgress: onProgress)
    }

    public func loadModel(
        _ package: HuggingFaceModelPackage,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)? = nil
    ) async throws -> LoadedModelContents {
        let downloadedModel = try await prepareModel(package, onProgress: onProgress)
        return try loadIntoMemory(downloadedModel)
    }
}

public extension LocalAIKitModelDownload {
    @available(*, deprecated, renamed: "downloadStatus")
    var phase: LocalAIKitDownloadStatus {
        downloadStatus
    }
}

private extension LocalAIKitDownloadStatus {
    var isActive: Bool {
        switch self {
        case .queued, .downloading:
            return true
        case .finished, .failed, .cancelled:
            return false
        }
    }
}
