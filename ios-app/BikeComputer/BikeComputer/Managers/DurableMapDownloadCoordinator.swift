import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class DurableMapDownloadCoordinator: NSObject, URLSessionDownloadDelegate {
    static let shared = DurableMapDownloadCoordinator()
    nonisolated static let sessionIdentifier = "org.bicino.offline-map-downloads.v1"
    private var completionHandler: (() -> Void)?
    private var backgroundEventsFinished = false
    private var pendingCancellationCallbacks = 0
    private var blockedAttempts: Set<UUID> = []

    // This record survives process death. A late callback cannot adopt an
    // artifact merely because its newer caller no longer has a waiter.
    nonisolated private struct Ownership: Codable {
        enum Phase: String, Codable { case active, cancelled, finished, failed }
        let attemptID: UUID
        let constraints: OfflineMapDownloadConstraints
        let phase: Phase
    }
    private let configurationOverride: URLSessionConfiguration?
    nonisolated private let directoryOverride: URL?
    init(configuration: URLSessionConfiguration? = nil, directory: URL? = nil) {
        configurationOverride = configuration
        directoryOverride = directory
        super.init()
    }
    private struct Waiter {
        let invocationID: UUID
        let attemptID: UUID
        let task: URLSessionDownloadTask
        let continuation: CheckedContinuation<URL, Error>
        let progress: @MainActor @Sendable (Double) -> Void
        let bytes: @MainActor @Sendable (OfflineMapByteProgress) -> Void
    }
    private var waiters: [String: Waiter] = [:]
    private lazy var session: URLSession = {
        let configuration: URLSessionConfiguration
        if let override = configurationOverride {
            configuration = override
        } else {
#if os(iOS) && !HOST_TESTING
        configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
#else
        configuration = URLSessionConfiguration.default
#endif
        }
#if !os(Linux)
        configuration.waitsForConnectivity = true
#endif
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        // All delegate work, ownership checks, file publication and waiter
        // transitions share the main actor. File moves complete before the
        // callback returns; no URLSession temporary file escapes its lifetime.
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    nonisolated struct Descriptor: Codable {
        let constraints: OfflineMapDownloadConstraints
        let attemptID: UUID?

        init(constraints: OfflineMapDownloadConstraints, attemptID: UUID? = nil) {
            self.constraints = constraints
            self.attemptID = attemptID
        }
        var key: String? {
            guard let sha = constraints.artifactSHA256, sha.count == 64,
                  sha.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let count = constraints.exactBytes, count > 0,
                  count <= constraints.maximumBytes,
                  count <= BikeMapStreamFormat.maximumArtifactBytes else { return nil }
            return "\(sha)-\(count)"
        }
        static func read(_ task: URLSessionTask) -> Self? {
            guard let text = task.taskDescription, text.utf8.count <= 4096,
                  let data = text.data(using: .utf8),
                  let value = try? JSONDecoder().decode(Self.self, from: data),
                  value.key != nil else { return nil }
            return value
        }
        func file(_ suffix: String, directory: URL? = nil) throws -> URL {
            guard let key else { throw OfflineMapCatalogError.invalidResponse }
            var root = try directory ?? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("OfflineMapDownloads", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            return root.appendingPathComponent(key).appendingPathExtension(suffix)
        }
        func allows(_ url: URL?) -> Bool {
            guard let hosts = constraints.allowedDownloadHosts else { return true }
            guard let url, url.scheme == "https", url.port == nil,
                  url.user == nil, url.password == nil, let host = url.host else { return false }
            return hosts.contains(host.lowercased())
        }
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        self.completionHandler = completionHandler
        _ = session
        completeBackgroundEventsIfReady()
    }

    func download(
        from url: URL, constraints: OfflineMapDownloadConstraints,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void,
        allowResume: Bool = true
    ) async throws -> URL {
        var descriptor = Descriptor(constraints: constraints)
        guard let key = descriptor.key else {
            // Legacy unsigned endpoints have no immutable identity to resume.
            return try await OfflineMapPackDownloader.download(
                from: url, constraints: constraints,
                onProgress: onProgress, onByteProgress: onByteProgress
            )
        }
        guard descriptor.allows(url) else { throw OfflineMapCatalogError.invalidResponse }
        let tasks = await session.allTasks
        try Task.checkCancellation()
        guard waiters[key] == nil else {
            throw OfflineMapPlatformError.invalidPack("this map is already downloading")
        }
        let complete = try descriptor.file("download", directory: directoryOverride)
        // The caller still checks the full artifact digest/signature before
        // publishing; a completed background task is not trusted installation.
        if FileManager.default.fileExists(atPath: complete.path) { return complete }
        try maintainStorage(descriptor: descriptor, tasks: tasks)
        let resume = try descriptor.file("resume", directory: directoryOverride)
        let matching = tasks.compactMap { $0 as? URLSessionDownloadTask }.first {
            guard let saved = Descriptor.read($0) else { return false }
            return saved.constraints == constraints && owns(saved, phases: [.active])
                && $0.state != .canceling && $0.state != .completed
        }
        let task: URLSessionDownloadTask
        var resumed = false
        if let matching {
            task = matching
            descriptor = Descriptor.read(matching)!
        } else {
            descriptor = Descriptor(constraints: constraints, attemptID: UUID())
            if allowResume, let data = resumeData(for: descriptor) {
                task = session.downloadTask(withResumeData: data)
                resumed = true
            } else {
                task = session.downloadTask(with: url)
            }
            do {
                let encoded = try JSONEncoder().encode(descriptor)
                guard encoded.count <= 4096 else { throw OfflineMapCatalogError.invalidResponse }
                task.taskDescription = String(decoding: encoded, as: UTF8.self)
                try persistOwnership(descriptor, phase: .active)
            } catch {
                task.cancel()
                throw error
            }
            // Supersede ownership BEFORE cancelling old tasks. Legacy tasks
            // without an attempt record restart using this authorized URL.
            for old in tasks where Descriptor.read(old)?.key == key { old.cancel() }
            try? FileManager.default.removeItem(at: resume)
        }
        do {
            return try await wait(for: task, descriptor: descriptor,
                onProgress: onProgress, onByteProgress: onByteProgress)
        } catch {
            // Opaque resume data can contain an expired signed URL. Retry once
            // using the freshly authorized URL and the SAME immutable identity.
            if resumed && !Task.isCancelled && !(error is CancellationError) {
                return try await download(from: url, constraints: constraints,
                    onProgress: onProgress, onByteProgress: onByteProgress, allowResume: false)
            }
            throw error
        }
    }

    private func wait(
        for task: URLSessionDownloadTask, descriptor: Descriptor,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void
    ) async throws -> URL {
        guard let key = descriptor.key, let attemptID = descriptor.attemptID else {
            throw OfflineMapCatalogError.invalidResponse
        }
        let invocationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[key] = Waiter(invocationID: invocationID, attemptID: attemptID,
                    task: task, continuation: continuation, progress: onProgress, bytes: onByteProgress)
                task.resume()
                if Task.isCancelled { cancel(key, invocationID: invocationID) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(key, invocationID: invocationID) }
        }
    }

    private func ownership(_ descriptor: Descriptor) throws -> Ownership? {
        let file = try descriptor.file("owner", directory: directoryOverride)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4096 else { throw OfflineMapCatalogError.invalidResponse }
        return try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: file))
    }

    private func owns(_ descriptor: Descriptor, phases: [Ownership.Phase]) -> Bool {
        guard let attemptID = descriptor.attemptID, !blockedAttempts.contains(attemptID),
              let current = try? ownership(descriptor), current.attemptID == attemptID,
              current.constraints == descriptor.constraints else { return false }
        return phases.contains(current.phase)
    }

    private func persistOwnership(_ descriptor: Descriptor, phase: Ownership.Phase) throws {
        guard let attemptID = descriptor.attemptID else { throw OfflineMapCatalogError.invalidResponse }
        let file = try descriptor.file("owner", directory: directoryOverride)
        let encoded = try JSONEncoder().encode(Ownership(attemptID: attemptID,
            constraints: descriptor.constraints, phase: phase))
        guard encoded.count <= 4096 else { throw OfflineMapCatalogError.invalidResponse }
        try encoded.write(to: file, options: .atomic)
    }

    private func retire(_ descriptor: Descriptor, phase: Ownership.Phase) {
        guard let attemptID = descriptor.attemptID else { return }
        // Persisted terminal records fence later process-restoration callbacks.
        // Only failed writes need an additional in-memory fail-closed fence.
        do { try persistOwnership(descriptor, phase: phase) }
        catch { blockedAttempts.insert(attemptID) }
    }

    private func resumeData(for descriptor: Descriptor) -> Data? {
        // Opaque URLSession resume data contains its original URL. A new host
        // policy must not reuse a request admitted under older, looser rules.
        guard let current = try? ownership(descriptor),
              current.constraints == descriptor.constraints,
              [.cancelled, .failed].contains(current.phase),
              let file = try? descriptor.file("resume", directory: directoryOverride),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1024 * 1024,
              let data = try? Data(contentsOf: file), data.count <= 1024 * 1024 else { return nil }
        return data
    }

    private func saveResumeData(_ data: Data?, descriptor: Descriptor) {
        guard owns(descriptor, phases: [.active, .cancelled]),
              let data, data.count <= 1024 * 1024,
              let file = try? descriptor.file("resume", directory: directoryOverride) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func maintainStorage(descriptor: Descriptor, tasks: [URLSessionTask]) throws {
        let root = try descriptor.file("download", directory: directoryOverride).deletingLastPathComponent()
        let protectedKeys = Set(tasks.compactMap { Descriptor.read($0)?.key }).union(waiters.keys).union([descriptor.key!])
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        var retained: Int64 = 0
        for file in files {
            retained += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let budget = 2 * BikeMapStreamFormat.maximumArtifactBytes
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let artifactKey = file.pathExtension == "staging"
                ? file.deletingPathExtension().deletingPathExtension().lastPathComponent
                : file.deletingPathExtension().lastPathComponent
            guard ["download", "resume", "owner", "staging"].contains(file.pathExtension),
                  !protectedKeys.contains(artifactKey) else { continue }
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if retained > budget || (values.contentModificationDate ?? .distantPast) < Date().addingTimeInterval(-7 * 86400) {
                try FileManager.default.removeItem(at: file)
                retained -= Int64(values.fileSize ?? 0)
            }
        }
        let activeOthers = tasks.filter { $0.state != .completed && $0.state != .canceling && Descriptor.read($0)?.key != descriptor.key }
        guard activeOthers.count < 2 else {
            throw OfflineMapPlatformError.invalidPack("wait for the other map downloads to finish")
        }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available >= (descriptor.constraints.exactBytes ?? 0) + 32 * 1024 * 1024 else {
            throw OfflineMapPlatformError.invalidPack("not enough free space to download this map")
        }
    }

    private func cancel(_ key: String, invocationID: UUID) {
        guard let waiter = waiters[key], waiter.invocationID == invocationID else { return }
        waiters.removeValue(forKey: key)
        let descriptor = Descriptor.read(waiter.task)
        if let descriptor, owns(descriptor, phases: [.active]) {
            do { try persistOwnership(descriptor, phase: .cancelled) }
            catch { blockedAttempts.insert(waiter.attemptID) }
        }
        pendingCancellationCallbacks += 1
        waiter.task.cancel { data in
            Task { @MainActor in
                defer {
                    self.pendingCancellationCallbacks -= 1
                    self.completeBackgroundEventsIfReady()
                }
                guard let descriptor, self.owns(descriptor, phases: [.cancelled]) else { return }
                self.saveResumeData(data, descriptor: descriptor)
                self.retire(descriptor, phase: .failed)
            }
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finish(_ task: URLSessionTask, result: Result<URL, Error>) {
        guard let descriptor = Descriptor.read(task), let key = descriptor.key,
              let waiter = waiters[key], waiter.attemptID == descriptor.attemptID,
              waiter.task.taskIdentifier == task.taskIdentifier else { return }
        waiters.removeValue(forKey: key)
        waiter.continuation.resume(with: result)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let descriptor = Descriptor.read(downloadTask), owns(descriptor, phases: [.active]) else {
                finish(downloadTask, result: .failure(OfflineMapCatalogError.invalidResponse))
                return
            }
            let result: Result<URL, Error> = Result {
                guard descriptor.allows(downloadTask.response?.url),
                      let response = downloadTask.response as? HTTPURLResponse,
                      [200, 206].contains(response.statusCode),
                      let count = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      Int64(count) == descriptor.constraints.exactBytes else {
                    throw OfflineMapCatalogError.invalidResponse
                }
                let destination = try descriptor.file("download", directory: directoryOverride)
                let staged = try descriptor.file(
                    "\(descriptor.attemptID!.uuidString).staging", directory: directoryOverride)
                defer { try? FileManager.default.removeItem(at: staged) }
                try FileManager.default.moveItem(at: location, to: staged)
                // Stage on the destination filesystem, then atomically replace
                // only while this attempt still owns publication. A failed
                // promotion must retain the previous completed artifact.
                guard owns(descriptor, phases: [.active]) else {
                    throw OfflineMapCatalogError.invalidResponse
                }
                guard rename(staged.path, destination.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return destination
            }
            switch result {
            case .success: retire(descriptor, phase: .finished)
            case .failure: retire(descriptor, phase: .failed)
            }
            finish(downloadTask, result: result)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            if let descriptor = Descriptor.read(task), owns(descriptor, phases: [.active, .cancelled]) {
                saveResumeData((error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                    descriptor: descriptor)
                // Cancellation's resume-data completion may arrive after this
                // delegate callback, so it owns retirement of cancelled tasks.
                if owns(descriptor, phases: [.active]) { retire(descriptor, phase: .failed) }
            }
            finish(task, result: .failure(error))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard let descriptor = Descriptor.read(downloadTask), let key = descriptor.key,
                  let expected = descriptor.constraints.exactBytes,
                  owns(descriptor, phases: [.active]) else { return }
            guard totalBytesWritten >= 0, totalBytesWritten <= expected,
                  totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite == expected else {
                downloadTask.cancel()
                return
            }
            guard let waiter = waiters[key], waiter.attemptID == descriptor.attemptID,
                  waiter.task.taskIdentifier == downloadTask.taskIdentifier else { return }
            waiter.progress(Double(totalBytesWritten) / Double(expected))
            waiter.bytes(OfflineMapByteProgress(completedBytes: totalBytesWritten, totalBytes: expected))
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Descriptor.read(task)?.allows(request.url) == true ? request : nil)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsFinished = true
            completeBackgroundEventsIfReady()
        }
    }

    private func completeBackgroundEventsIfReady() {
        guard backgroundEventsFinished, pendingCancellationCallbacks == 0,
              let completion = completionHandler else { return }
        completionHandler = nil
        backgroundEventsFinished = false
        completion()
    }
}
