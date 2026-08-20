import Foundation
import Combine
import XCTest

final class RideDiagnosticsTests: XCTestCase {
    func testRecorderExportsBoundedPrivacySafeBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ride-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RideDiagnosticsRecorder(rootURL: root)
        recorder.record(
            category: .ble,
            event: "connected",
            fields: ["rssiBucket": "good"]
        )
        recorder.record(
            category: .user,
            event: "issue_marker",
            fields: ["code": RideIssueCode.connectionDrop.rawValue]
        )

        let bundle = try recorder.exportBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertGreaterThan(
            try FileManager.default.attributesOfItem(atPath: bundle.path)[.size] as? Int ?? 0,
            0
        )
        XCTAssertEqual(recorder.health.schema, 1)
        XCTAssertNil(recorder.lastError)
    }

    func testDetailedTraceExpiresAtFourHours() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ride-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RideDiagnosticsRecorder(rootURL: root)
        recorder.beginDetailedTrace()
        let deadline = Date().addingTimeInterval(1)
        while !recorder.detailedTraceEnabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(recorder.detailedTraceEnabled)
        XCTAssertNotNil(recorder.detailedTraceExpiresAt)
    }

    func testRecorderPublishesRetentionBytesOnMainThread() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ride-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RideDiagnosticsRecorder(rootURL: root)
        let published = expectation(description: "retention snapshot published")
        let lock = NSLock()
        var receivedOnMain = false
        var didFulfill = false
        let cancellable = recorder.$retainedBytes
            .dropFirst()
            .sink { value in
                _ = value
                lock.lock()
                receivedOnMain = Thread.isMainThread
                let shouldFulfill = !didFulfill
                didFulfill = true
                lock.unlock()
                if shouldFulfill {
                    published.fulfill()
                }
            }

        recorder.record(category: .lifecycle, event: "retention_test")
        wait(for: [published], timeout: 2)

        lock.lock()
        let result = receivedOnMain
        lock.unlock()
        XCTAssertTrue(result)
        withExtendedLifetime(cancellable) {}
    }
}
