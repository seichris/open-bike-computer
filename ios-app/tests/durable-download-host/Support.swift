import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
let NSURLSessionDownloadTaskResumeData = "NSURLSessionDownloadTaskResumeData"
extension URLSession {
    var allTasks: [URLSessionTask] {
        get async { await withCheckedContinuation { c in getAllTasks { c.resume(returning: $0) } } }
    }
}
#endif

struct OfflineMapDownloadConstraints: Codable, Equatable, Sendable {
    let exactBytes: Int64?
    let maximumBytes: Int64
    let allowedDownloadHosts: Set<String>?
    let artifactSHA256: String?
}
enum BikeMapStreamFormat { static let maximumArtifactBytes: Int64 = 1024 * 1024 * 1024 }
enum OfflineMapCatalogError: Error { case invalidResponse }
enum OfflineMapPlatformError: Error { case invalidPack(String) }
struct OfflineMapByteProgress: Sendable { let completedBytes: Int64; let totalBytes: Int64 }
@MainActor enum OfflineMapPackDownloader {
    static func download(from url: URL, constraints: OfflineMapDownloadConstraints,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void) async throws -> URL {
        // Legacy unsigned networking is outside this focused ownership harness.
        throw OfflineMapCatalogError.invalidResponse
    }
}

final class ControlledDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    let identity: Int
    var cancelled = 0
    var started = 0
    var resumeCompletion: ((Data?) -> Void)?
    var resultResponse: URLResponse?
    init(_ identity: Int) { self.identity = identity; super.init() }
    override var taskIdentifier: Int { identity }
    override var response: URLResponse? { resultResponse }
    override func resume() { started += 1 }
    override func cancel() { cancelled += 1 }
    override func cancel(byProducingResumeData completionHandler: @escaping (Data?) -> Void) {
        cancelled += 1
        resumeCompletion = completionHandler
    }
}
