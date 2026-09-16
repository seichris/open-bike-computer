import Foundation

@MainActor
protocol WorkoutRecordingPersisting: AnyObject {
    func load() throws -> WorkoutRecordingRecord?
    func save(_ record: WorkoutRecordingRecord) throws
    func clear(sessionID: UUID) throws
}

/// A corrupt or protected record is an error, not an empty/no-workout state.
@MainActor
final class WorkoutRecordingStore: WorkoutRecordingPersisting {
    enum StoreError: Error { case invalidRecord, identityMismatch }
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("WorkoutRecording/owner-v1.json")
    }

    func load() throws -> WorkoutRecordingRecord? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        let record = try JSONDecoder().decode(WorkoutRecordingRecord.self, from: data)
        guard record.isValid else { throw StoreError.invalidRecord }
        return record
    }

    func save(_ record: WorkoutRecordingRecord) throws {
        guard record.isValid else { throw StoreError.invalidRecord }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        let data = try JSONEncoder().encode(record)
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
        try data.write(to: url, options: .atomic)
#endif
    }

    func clear(sessionID: UUID) throws {
        guard let record = try load() else { return }
        guard record.sessionID == sessionID else { throw StoreError.identityMismatch }
        try FileManager.default.removeItem(at: url)
    }
}
