//
//  LocalAIKitDownloadManager.swift
//  LocalAIKit
//
//  Created by Shawna MacNabb on 6/13/26.
//

import Foundation
import SwiftUI

@MainActor
@Observable
/// Manages observable model downloads, including background transfer recovery and persisted queue state.
public final class LocalAIKitDownloadManager {
    /// The shared download manager used by the demo apps and other callers that want one observable queue.
    public static let shared = LocalAIKitDownloadManager()

    /// The current downloads known to the manager, ordered by insertion and updated as progress changes.
    private var downloads: [LocalAIKitModelDownload] = []

    /// The downloads that are still queued or actively downloading.
    public var activeDownloads: [LocalAIKitModelDownload] {
        downloads.filter { item in
            switch item.downloadStatus {
            case .queued, .downloading:
                return true
            case .finished, .failed, .cancelled:
                return false
            }
        }
    }

    /// The downloads that completed successfully and are ready to load from disk.
    public var completedDownloads: [LocalAIKitModelDownload] {
        downloads.filter { item in
            if case .finished = item.downloadStatus {
                return true
            }

            return false
        }
    }

    /// Returns the download status for the download with the specified identifier.
    ///
    /// - Parameters:
    ///   - id: The identifier of the download to inspect.
    /// - Returns: The download status if the download exists, or `nil` if the identifier is unknown.
    public func downloadStatus(for id: String) -> LocalAIKitDownloadStatus? {
        downloads.first(where: { $0.id == id })?.downloadStatus
    }

    /// Returns the tracked download record for the specified identifier.
    ///
    /// - Parameters:
    ///   - id: The identifier of the download to inspect.
    /// - Returns: The tracked download if it exists, or `nil` if the identifier is unknown.
    public func download(for id: String) -> LocalAIKitModelDownload? {
        downloads.first(where: { $0.id == id })
    }

    private let modelStore: HuggingFaceModelStore
    private let sessionIdentifier: String
    private let storeURL: URL
    private let packageRegistry: LocalAIKitBackgroundDownloadPackageRegistry
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let delegateProxy: LocalAIKitBackgroundDownloadSessionDelegate
    @ObservationIgnored private var assetProgressByDownloadID: [String: [Int: Double]] = [:]
    @ObservationIgnored private var backgroundEventsCompletionHandler: (() -> Void)?

    /// Creates a download manager for the supplied configuration and optional custom model store.
    ///
    /// - Parameters:
    ///   - configuration: The configuration that provides the models directory and related paths.
    ///   - modelStore: An optional custom model store to use for cache paths and download requests.
    ///   - sessionIdentifier: An optional background URL session identifier. A default is derived from the app bundle identifier.
    public init(
        configuration: LocalAIKitConfiguration = .init(),
        modelStore: HuggingFaceModelStore? = nil,
        sessionIdentifier: String? = nil
    ) {
        let resolvedModelStore = modelStore ?? HuggingFaceModelStore(cacheRoot: configuration.modelsDirectory)
        self.modelStore = resolvedModelStore
        self.sessionIdentifier = sessionIdentifier ?? Self.defaultSessionIdentifier(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        self.storeURL = configuration.modelsDirectory
            .appendingPathComponent("LocalAIKitBackgroundDownloads.json")
        self.packageRegistry = LocalAIKitBackgroundDownloadPackageRegistry()

        let delegate = LocalAIKitBackgroundDownloadSessionDelegate(
            modelStore: resolvedModelStore,
            packageRegistry: packageRegistry
        )
        self.delegateProxy = delegate

        let configuration = URLSessionConfiguration.background(withIdentifier: self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        self.downloads = Self.loadManifest(from: storeURL)?.downloads ?? []
        for download in downloads {
            self.packageRegistry.register(package: download.package, downloadID: download.id)
        }
        self.delegateProxy.manager = self
        rebuildAssetProgress()

        Task { [weak self] in
            await self?.restoreBackgroundTasks()
        }
    }

    /// Starts a background download for the package and waits until the model is fully available on disk.
    ///
    /// - Parameters:
    ///   - package: The Hugging Face model package to download.
    ///   - onProgress: Optional async callback that receives coarse progress updates while assets download.
    /// - Returns: The downloaded model files on disk, ready for loading into memory.
    public func prepareModel(
        _ package: HuggingFaceModelPackage,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)? = nil
    ) async throws -> DownloadedModel {
        guard !package.repository.identifier.isEmpty else {
            throw LocalAIKitError.invalidRepository
        }

        guard !package.assets.isEmpty else {
            throw LocalAIKitError.emptyModelPackage
        }

        let id = modelStore.cacheKey(for: package)
        queue(package)

        var lastReportedFraction: Double?
        while true {
            try Task.checkCancellation()

            if let download = downloads.first(where: { $0.id == id }) {
                if lastReportedFraction != download.fractionCompleted {
                    await reportProgress(download, onProgress: onProgress)
                    lastReportedFraction = download.fractionCompleted
                }

                switch download.downloadStatus {
                case .finished:
                    await reportProgress(download, onProgress: onProgress)
                    return try modelStore.downloadedModel(for: package)
                case .failed(let message):
                    throw LocalAIKitError.modelDownloadFailed(message: message)
                case .cancelled:
                    throw CancellationError()
                case .queued, .downloading:
                    break
                }
            }

            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Enqueues a package for background download without waiting for completion.
    ///
    /// - Parameters:
    ///   - package: The Hugging Face model package to add to the background download queue.
    public func queue(_ package: HuggingFaceModelPackage) {
        let id = modelStore.cacheKey(for: package)

        if downloads.contains(where: { $0.id == id && $0.downloadStatus.isActive }) {
            persistDownloads()
            return
        }

        assetProgressByDownloadID[id] = [:]
        packageRegistry.register(package: package, downloadID: id)
        upsert(LocalAIKitModelDownload(id: id, package: package))
        persistDownloads()

        startBackgroundDownloads(package: package, id: id)
    }

    /// Cancels the active background download associated with the given download identifier.
    ///
    /// - Parameters:
    ///   - id: The download identifier to cancel.
    public func cancel(id: String) {
        cancelBackgroundTasks(for: id)
        assetProgressByDownloadID[id] = nil
        update(id: id) { item in
            item.updateStatus(.cancelled)
        }
        persistDownloads()
    }

    /// Deletes the cached model files for the download with the specified identifier and removes its queue record.
    ///
    /// - Parameters:
    ///   - id: The download identifier whose cached files should be deleted from disk.
    /// - Throws: `LocalAIKitError.downloadNotFound` if the identifier is unknown, or `LocalAIKitError.unableToDeleteDirectory` if the cache directory could not be removed.
    public func deleteModel(id: String) throws {
        guard let download = download(for: id) else {
            throw LocalAIKitError.downloadNotFound(id: id)
        }

        cancelBackgroundTasks(for: id)
        assetProgressByDownloadID[id] = nil
        try modelStore.deleteDownloadedModel(for: download.package)
        packageRegistry.unregister(downloadID: id)
        downloads.removeAll { $0.id == id }
        persistDownloads()
    }

    /// Removes completed, failed, and cancelled downloads from the observable queue.
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
        finishedIDs.forEach { packageRegistry.unregister(downloadID: $0) }
        let activeIDs = Set(downloads.map(\.id))
        assetProgressByDownloadID = assetProgressByDownloadID.filter { activeIDs.contains($0.key) }
        persistDownloads()
    }

    /// Stores the completion handler that should be called when the background URL session finishes its events.
    ///
    /// - Parameters:
    ///   - identifier: The background session identifier associated with the current app launch.
    ///   - completionHandler: The completion handler to invoke after the session finishes delivering events.
    public func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == sessionIdentifier else {
            return
        }

        backgroundEventsCompletionHandler = completionHandler
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
            item.updateStatus(.downloading)
            item.fractionCompleted = aggregateFraction(for: item.id, assetCount: assetCount)
        }

        persistDownloads()
    }

    func handleAssetFinished(_ metadata: LocalAIKitBackgroundDownloadTaskMetadata) async {
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
        }

        if isDownloadComplete(downloadID: metadata.downloadID, package: download.package) {
            markDownloadFinished(id: metadata.downloadID)
        } else {
            update(id: metadata.downloadID) { item in
                item.updateStatus(.downloading)
            }
        }

        persistDownloads()
    }

    func handleTaskFailure(metadata: LocalAIKitBackgroundDownloadTaskMetadata, error: Error) async {
        if error is CancellationError {
            markDownloadCancelled(id: metadata.downloadID)
            return
        }

        let message = localAIKitMessage(for: error)
        markDownloadFailed(id: metadata.downloadID, message: message)
    }

    func backgroundSessionDidFinishEvents() async {
        backgroundEventsCompletionHandler?()
        backgroundEventsCompletionHandler = nil
    }

    func restoreBackgroundTasks() async {
        let tasks = await Self.allTasks(in: session)
        guard !tasks.isEmpty else {
            return
        }

        for task in tasks {
            guard let metadata = Self.metadata(from: task.taskDescription) else {
                continue
            }

            update(id: metadata.downloadID) { item in
                if item.downloadStatus != .finished && item.downloadStatus != .cancelled {
                    item.updateStatus(.downloading)
                }
            }
        }

        persistDownloads()
    }
}

// MARK: Private LocalAIKitDownloadManager
private extension LocalAIKitDownloadManager {
    func startBackgroundDownloads(package: HuggingFaceModelPackage, id: String) {
        var anyTaskStarted = false

        do {
            try modelStore.preparePackageDirectory(for: package)
        } catch {
            markDownloadFailed(id: id, message: localAIKitMessage(for: error))
            return
        }

        for (assetIndex, asset) in package.assets.enumerated() {
            if modelStore.cachedAssetIsReady(for: package, asset: asset) {
                markAssetComplete(downloadID: id, assetIndex: assetIndex, package: package)
                continue
            }

            do {
                let request = try modelStore.makeDownloadRequest(for: package, asset: asset)
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
                item.updateStatus(.downloading)
            }
        } else {
            markDownloadFinished(id: id)
        }

        persistDownloads()
    }

    func reportProgress(
        _ download: LocalAIKitModelDownload,
        onProgress: (@Sendable (HuggingFaceModelDownloadProgress) async -> Void)?
    ) async {
        guard let onProgress, !download.package.assets.isEmpty else {
            return
        }

        let assetCount = download.package.assets.count
        let fractionCompleted = max(0, min(1, download.fractionCompleted))
        let completedAssets = min(assetCount, Int((fractionCompleted * Double(assetCount)).rounded(.down)))
        let assetIndex = min(completedAssets, assetCount - 1)

        await onProgress(
            HuggingFaceModelDownloadProgress(
                package: download.package,
                asset: download.package.assets[assetIndex],
                assetIndex: assetIndex,
                assetCount: assetCount,
                bytesReceived: Int64((fractionCompleted * 1_000).rounded()),
                bytesExpected: 1_000,
                completedAssets: completedAssets,
                fractionCompleted: fractionCompleted
            )
        )
    }

    func markAssetComplete(
        downloadID: String,
        assetIndex: Int,
        package: HuggingFaceModelPackage
    ) {
        var progress = assetProgressByDownloadID[downloadID, default: [:]]
        progress[assetIndex] = 1
        assetProgressByDownloadID[downloadID] = progress

        update(id: downloadID) { item in
            item.updateStatus(.downloading)
            item.fractionCompleted = aggregateFraction(for: item.id, assetCount: item.package.assets.count)
        }

        if isDownloadComplete(downloadID: downloadID, package: package) {
            markDownloadFinished(id: downloadID)
        }
    }
    
    func cancelBackgroundTasks(for downloadID: String) {
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

    func isDownloadComplete(downloadID: String, package: HuggingFaceModelPackage) -> Bool {
        let progress = assetProgressByDownloadID[downloadID] ?? [:]
        guard !package.assets.isEmpty else {
            return true
        }

        return package.assets.enumerated().allSatisfy { index, _ in
            (progress[index] ?? 0) >= 1
        }
    }

    func aggregateFraction(for downloadID: String, assetCount: Int) -> Double {
        guard assetCount > 0 else {
            return 1
        }

        let progress = assetProgressByDownloadID[downloadID] ?? [:]
        let total = (0..<assetCount).reduce(0.0) { partialResult, index in
            partialResult + (progress[index] ?? 0)
        }
        return min(max(total / Double(assetCount), 0), 1)
    }

    func markDownloadFinished(id: String) {
        update(id: id) { item in
            item.updateStatus(.finished)
            item.fractionCompleted = 1
        }
        persistDownloads()
    }

    func markDownloadCancelled(id: String) {
        assetProgressByDownloadID[id] = nil
        update(id: id) { item in
            item.updateStatus(.cancelled)
        }
        persistDownloads()
    }

    func markDownloadFailed(id: String, message: String) {
        assetProgressByDownloadID[id] = nil
        update(id: id) { item in
            item.updateStatus(.failed(message: message))
        }
        persistDownloads()
    }

    func rebuildAssetProgress() {
        assetProgressByDownloadID = downloads.reduce(into: [:]) { partialResult, download in
            partialResult[download.id] = [:]
            if case .finished = download.downloadStatus {
                partialResult[download.id] = Dictionary(
                    uniqueKeysWithValues: download.package.assets.enumerated().map { ($0.offset, 1) }
                )
            }
        }
    }

    func upsert(_ item: LocalAIKitModelDownload) {
        if let index = downloads.firstIndex(where: { $0.id == item.id }) {
            downloads[index] = item
        } else {
            downloads.append(item)
        }
    }

    func update(id: String, _ mutate: (inout LocalAIKitModelDownload) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else {
            return
        }

        var item = downloads[index]
        mutate(&item)
        downloads[index] = item
    }

    func persistDownloads() {
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

    static func loadManifest(from url: URL) -> LocalAIKitDownloadManifest? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(LocalAIKitDownloadManifest.self, from: data)
    }

    static func defaultSessionIdentifier(bundleIdentifier: String?) -> String {
        let base = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.map { "\($0).LocalAIKit.background-downloads" } ?? "LocalAIKit.background-downloads"
    }

    static func encodeTaskMetadata(_ metadata: LocalAIKitBackgroundDownloadTaskMetadata) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func metadata(from taskDescription: String?) -> LocalAIKitBackgroundDownloadTaskMetadata? {
        guard
            let taskDescription,
            let data = taskDescription.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder().decode(LocalAIKitBackgroundDownloadTaskMetadata.self, from: data)
    }

    static func allTasks(in session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }
}


// MARK: LocalAIKitBackgroundDownloadPackageRegistry
final class LocalAIKitBackgroundDownloadPackageRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var packagesByDownloadID: [String: HuggingFaceModelPackage] = [:]

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
}

// MARK: LocalAIKitBackgroundDownloadSessionDelegate
final class LocalAIKitBackgroundDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    weak var manager: LocalAIKitDownloadManager?
    private let modelStore: HuggingFaceModelStore
    private let packageRegistry: LocalAIKitBackgroundDownloadPackageRegistry

    init(
        modelStore: HuggingFaceModelStore,
        packageRegistry: LocalAIKitBackgroundDownloadPackageRegistry
    ) {
        self.modelStore = modelStore
        self.packageRegistry = packageRegistry
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
            guard let package = packageRegistry.package(for: metadata.downloadID) else {
                throw LocalAIKitError.missingBackgroundDownloadState
            }

            try modelStore.finalizeBackgroundDownload(
                for: package,
                assetIndex: metadata.assetIndex,
                temporaryURL: location
            )
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
