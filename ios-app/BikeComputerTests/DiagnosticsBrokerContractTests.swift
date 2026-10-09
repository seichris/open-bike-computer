import Foundation
#if canImport(Combine)
import Combine
#endif

@main enum DiagnosticsBrokerContractTests {
    #if canImport(Combine)
    private final class ReadinessProbe {
        @Published var ready = false
    }

    @MainActor
    private static func verifyPublishedResumeBoundary() async {
        let probe = ReadinessProbe()
        var immediateReads: [Bool] = []
        let immediate = probe.$ready.dropFirst().sink { _ in
            immediateReads.append(probe.ready)
        }
        var deferred: AnyCancellable?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            deferred = probe.$ready.dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { ready in
                    precondition(ready && probe.ready, "resume must read the committed readiness")
                    continuation.resume()
                }
            probe.ready = true
            precondition(immediateReads == [false], "synchronous Published delivery precedes assignment")
        }
        withExtendedLifetime((immediate, deferred)) { }
        print("Combine committed-readiness resume boundary passed")
    }
    #endif

    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--pairing-interop" {
            let enrollment = try JSONDecoder().decode(DiagnosticsBrokerEnrollment.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            let pairing = try enrollment.pairing(phoneID: UUID(), credential: String(repeating: "c", count: 64), credentialID: UUID())
            try JSONEncoder().encode(pairing).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            return
        }
        if args.count == 5, args[1] == "--confirm-interop" {
            let pending = try JSONDecoder().decode(DiagnosticsBrokerPairing.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            let receipt = try JSONDecoder().decode(DiagnosticsBrokerEnrollmentReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            try JSONEncoder().encode(pending.confirmed(by: receipt)).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
            return
        }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func pairing(_ origin: String, lifetime: Int64 = 3600) -> DiagnosticsBrokerPairing {
            DiagnosticsBrokerPairing(schema: 2, origin: origin,
                certificateSHA256: String(repeating: "a", count: 64),
                token: String(repeating: "b", count: 64), expiresAt: 1_800_000_000 + lifetime)
        }
        precondition(pairing("https://192.168.1.50:8443").valid(at: date))
        precondition(pairing("https://127.0.0.1:8443").valid(at: date))
        for origin in ["http://192.168.1.50:8443", "https://8.8.8.8:8443",
                       "https://example.com:8443", "https://192.168.1.50",
                       "https://192.168.1.50:8443/path", "https://192.168.1.50:8443?token=x",
                       "https://user@192.168.1.50:8443", "https://192.168.01.50:8443"] {
            precondition(!pairing(origin).valid(at: date), origin)
        }
        precondition(!pairing("https://192.168.1.50:8443", lifetime: 0).valid(at: date))
        precondition(!pairing("https://192.168.1.50:8443", lifetime: 100000).valid(at: date))
        func command(target: String) throws -> DiagnosticsBrokerCommand {
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": 2, "id": UUID().uuidString, "kind": "collect", "target": target,
                "parameters": [:], "createdAt": 1_800_000_000, "expiresAt": 1_800_000_060,
            ])
            return try JSONDecoder().decode(DiagnosticsBrokerCommand.self, from: data)
        }
        let phone = try command(target: "iphone")
        let firmware = try command(target: "0123456789abcdef")
        precondition(phone.valid(at: date) && !phone.requiresFirmware)
        precondition(firmware.valid(at: date) && firmware.requiresFirmware)
        let limit = DiagnosticsOutboxAdmission.maximumBytes
        precondition(DiagnosticsOutboxAdmission.allows(existingCount: 7, existingBytes: limit - 1024, additionalBytes: 1024))
        precondition(!DiagnosticsOutboxAdmission.allows(existingCount: 8, existingBytes: 0, additionalBytes: 1024))
        precondition(!DiagnosticsOutboxAdmission.allows(existingCount: 7, existingBytes: limit - 1024, additionalBytes: 1025))
        precondition(!DiagnosticsOutboxAdmission.allows(existingCount: 0, existingBytes: 0, additionalBytes: Int.max))
        precondition(!DiagnosticsOutboxAdmission.allows(existingCount: 0, existingBytes: Int.max, additionalBytes: 1))
        precondition(!DiagnosticsOutboxAdmission.allows(existingCount: -1, existingBytes: 0, additionalBytes: 1))
        precondition(!DiagnosticsOutboxAdmission.allows(existingCount: 0, existingBytes: -1, additionalBytes: 1))
        precondition(!DiagnosticsOutboxAdmission.allows(existingCount: 0, existingBytes: 0, additionalBytes: 0))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("commands.json")
        let first = DiagnosticsBrokerCommandJournal(root: url)
        let id = UUID()
        let expiry: Int64 = 1_800_000_060
        try await first.save(.init(id: id, state: "interrupted", code: "execution_started"), expiresAt: expiry, at: date)
        let reloaded = DiagnosticsBrokerCommandJournal(root: url)
        let pending = try await reloaded.existing(id, at: date)
        precondition(pending?.state == "interrupted")
        try await first.save(.init(id: id, state: "accepted", code: "phone_marker_saved"), expiresAt: expiry, at: date)
        let completed = try await reloaded.existing(id, at: date)
        precondition(completed?.code == "phone_marker_saved")
        for _ in 0..<99 { try await first.save(.init(id: UUID(), state: "accepted", code: "done"), expiresAt: expiry, at: date) }
        do {
            try await first.save(.init(id: UUID(), state: "accepted", code: "done"), expiresAt: expiry, at: date)
            preconditionFailure("journal must not evict still-valid replay receipts")
        } catch DiagnosticsAcquisitionStore.Failure.storageFull { }
        let original = try await reloaded.existing(id, at: date)
        precondition(original != nil)
        let bytes = try Data(contentsOf: url)
        do {
            try await first.save(.init(id: id, state: "bad", code: "not diagnostic text"), expiresAt: expiry, at: date)
            preconditionFailure("invalid receipt should fail")
        } catch DiagnosticsAcquisitionStore.Failure.invalidManifest { }
        let afterFailure = try Data(contentsOf: url)
        precondition(afterFailure == bytes)
        // One-use enrollment is distinct from the persisted phone credential.
        let enrollment = DiagnosticsBrokerEnrollment(schema: 3, origin: "https://192.168.1.50:8443",
            certificateSHA256: String(repeating: "a", count: 64), token: String(repeating: "b", count: 64),
            expiresAt: 1_800_000_060, brokerID: UUID(), enrollmentID: UUID())
        precondition(enrollment.valid(at: date))
        let phoneID = UUID(), credentialID = UUID()
        let pendingPair = try enrollment.pairing(phoneID: phoneID, credential: String(repeating: "c", count: 64),
            credentialID: credentialID, at: date)
        let restoredPair = try JSONDecoder().decode(DiagnosticsBrokerPairing.self, from: JSONEncoder().encode(pendingPair))
        precondition(restoredPair.enrollmentRequest?.credential == pendingPair.token)
        let dayLater = date.addingTimeInterval(2 * 86400)
        precondition(!enrollment.valid(at: dayLater))
        precondition(restoredPair.valid(at: dayLater), "lost reply may confirm an already-committed pair")
        let receipt = DiagnosticsBrokerEnrollmentReceipt(schema: 3, brokerID: enrollment.brokerID,
            credentialID: credentialID, phoneID: phoneID, paired: true)
        let confirmedPair = try restoredPair.confirmed(by: receipt)
        precondition(confirmedPair.enrollment == nil && confirmedPair.token == pendingPair.token)
        precondition(confirmedPair.valid(at: dayLater) && confirmedPair.valid(at: date.addingTimeInterval(365 * 86400)))
        let repeated = try enrollment.pairing(phoneID: phoneID, credential: String(repeating: "d", count: 64),
            credentialID: UUID(), existing: restoredPair, at: date)
        precondition(repeated == restoredPair, "duplicate import must preserve the pending credential")
        let repeatedConfirmed = try enrollment.pairing(phoneID: phoneID, credential: String(repeating: "d", count: 64),
            credentialID: UUID(), existing: confirmedPair, at: date)
        precondition(repeatedConfirmed == confirmedPair)
        for badReceipt in [
            DiagnosticsBrokerEnrollmentReceipt(schema: 3, brokerID: UUID(), credentialID: credentialID, phoneID: phoneID, paired: true),
            DiagnosticsBrokerEnrollmentReceipt(schema: 3, brokerID: enrollment.brokerID, credentialID: UUID(), phoneID: phoneID, paired: true),
            DiagnosticsBrokerEnrollmentReceipt(schema: 3, brokerID: enrollment.brokerID, credentialID: credentialID, phoneID: UUID(), paired: true),
            DiagnosticsBrokerEnrollmentReceipt(schema: 3, brokerID: enrollment.brokerID, credentialID: credentialID, phoneID: phoneID, paired: false),
        ] {
            do { _ = try restoredPair.confirmed(by: badReceipt); preconditionFailure("cross-pair receipt must fail") }
            catch DiagnosticsAcquisitionStore.Failure.invalidManifest { }
        }

        func replayCommand(_ id: UUID, now: Int64, seconds: Int64 = 60) throws -> DiagnosticsBrokerCommand {
            let data = try JSONSerialization.data(withJSONObject: ["schema":2, "id":id.uuidString,
                "kind":"export", "target":"iphone", "parameters":[:], "createdAt":now, "expiresAt":now + seconds])
            return try JSONDecoder().decode(DiagnosticsBrokerCommand.self, from: data)
        }
        let replayURL = root.appendingPathComponent("replays.json")
        let replay = DiagnosticsBrokerCommandJournal(root: replayURL)
        let originalCommand = try replayCommand(UUID(), now: 1_800_000_000)
        let permitted = try await replay.claim(originalCommand, at: date)
        precondition(permitted.shouldExecute)
        let restarted = DiagnosticsBrokerCommandJournal(root: replayURL)
        let interrupted = try await restarted.claim(originalCommand, at: date)
        precondition(!interrupted.shouldExecute && interrupted.receipt.state == "interrupted")
        try await replay.complete(originalCommand, receipt: .init(id: originalCommand.id, state: "accepted", code: "handoff_requested"), at: date)
        let duplicated = try await restarted.claim(originalCommand, at: date)
        precondition(!duplicated.shouldExecute && duplicated.receipt.code == "handoff_requested")
        let changedDeadline = try replayCommand(originalCommand.id, now: 1_800_000_000, seconds: 120)
        let changedReplay = try await restarted.claim(changedDeadline, at: date)
        precondition(!changedReplay.shouldExecute, "same ID cannot renew an action")
        do {
            try await replay.complete(changedDeadline, receipt: .init(id: originalCommand.id, state: "accepted", code: "handoff_requested"), at: date)
            preconditionFailure("completion cannot renew the receipt deadline")
        } catch DiagnosticsAcquisitionStore.Failure.invalidManifest { }
        do {
            try await replay.complete(originalCommand, receipt: .init(id: originalCommand.id, state: "accepted", code: "changed"), at: date)
            preconditionFailure("completed receipts cannot change after acknowledgement")
        } catch DiagnosticsAcquisitionStore.Failure.invalidManifest { }
        let expiredReplay = try await restarted.claim(originalCommand, at: date.addingTimeInterval(61))
        precondition(!expiredReplay.shouldExecute && expiredReplay.receipt.code == "invalid_or_expired")
        for index in 0..<250 {
            let stamp = 1_800_000_100 + Int64(index * 2)
            let instant = Date(timeIntervalSince1970: Double(stamp))
            let next = try replayCommand(UUID(), now: stamp, seconds: 1)
            let claim = try await replay.claim(next, at: instant)
            precondition(claim.shouldExecute)
            try await replay.complete(next, receipt: .init(id: next.id, state: "accepted", code: "done"), at: instant)
        }
        let stillExpired = try await replay.claim(originalCommand, at: date.addingTimeInterval(1000))
        precondition(!stillExpired.shouldExecute, "pruned receipts must not revive expired commands")

        let legacyURL = root.appendingPathComponent("legacy.json")
        let legacyReceipt = DiagnosticsBrokerAcknowledgement(id: UUID(), state: "interrupted", code: "execution_started")
        try JSONEncoder().encode([legacyReceipt]).write(to: legacyURL)
        let legacyJournal = DiagnosticsBrokerCommandJournal(root: legacyURL)
        let migrated = try await legacyJournal.existing(legacyReceipt.id, at: date)
        precondition(migrated != nil)
        let migrationBytes = try Data(contentsOf: legacyURL)
        let retained = try await legacyJournal.existing(legacyReceipt.id, at: date.addingTimeInterval(60))
        precondition(retained != nil)
        let unchangedMigration = try Data(contentsOf: legacyURL)
        precondition(unchangedMigration == migrationBytes, "migration expiry must not slide on replay")
        let released = try await legacyJournal.existing(legacyReceipt.id, at: date.addingTimeInterval(3661))
        precondition(released == nil)
        print("Durable enrollment, receipt binding, expiry recovery and rolling replay journal passed")

        #if canImport(Combine)
        await verifyPublishedResumeBoundary()
        #else
        print("Combine publication-boundary regression requires Apple CI; not exercised on this host")
        #endif
        print("Swift broker pairing, bounded journal and process-loss replay tests passed")
    }
}
