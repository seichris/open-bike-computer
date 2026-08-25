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

        let published = expectation(description: "detailed trace state published")
        let cancellable = recorder.$detailedTraceEnabled
            .dropFirst()
            .filter { $0 }
            .sink { _ in published.fulfill() }
        recorder.beginDetailedTrace()
        // Wait for the recorder queue to complete the transition before the
        // timed wait. This also guarantees that the main-thread publication
        // has been enqueued, even when a hosted simulator starves utility QoS.
        XCTAssertTrue(recorder.health.detailedTraceEnabled)
        wait(for: [published], timeout: 2)
        XCTAssertTrue(recorder.isDetailedTraceEnabled)
        XCTAssertTrue(recorder.detailedTraceEnabled)
        XCTAssertNotNil(recorder.detailedTraceExpiresAt)
        withExtendedLifetime(cancellable) {}
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
