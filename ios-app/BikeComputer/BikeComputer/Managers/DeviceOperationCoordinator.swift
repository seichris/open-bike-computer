import Foundation

/// App-wide admission is deliberately more conservative than per-device admission:
/// iOS has one accessory Wi-Fi route and configuration removal is SSID-keyed.
/// MainActor is the serial executor shared with BLE, never a detached BLE owner.
@MainActor
final class DeviceOperationCoordinator {
    struct Lease: Codable, Equatable, Sendable {
        let id: UUID
        let deviceID: String
        let mode: String
        let connectionEpoch: UInt64
    }
    enum Failure: LocalizedError {
        case busy, cleanupUnresolved, staleOwner
        var errorDescription: String? {
            switch self {
            case .busy: return "Another device operation still owns the transfer session."
            case .cleanupUnresolved: return "Reconnect to the previous device and confirm its transfer mode has ended before starting another operation."
            case .staleOwner: return "The transfer device or connection changed. Reconnect before retrying."
            }
        }
    }
    private struct CleanupRecord: Codable {
        let lease: Lease
        let ssid: String?
        let tokenDigest: String?
        let transferGeneration: UInt32?
    }
    static let shared = DeviceOperationCoordinator()
    private let defaults: UserDefaults
    private let key = "device-operation-cleanup-v1"
    private(set) var lease: Lease?
    private var claims: Set<UUID> = []
    private var pendingApplies: Set<UUID> = []
    private var ssid: String?
    private(set) var unresolved: Lease?
    private var unreadableCleanupRecord = false
    private var recordedSSID: String?
    private(set) var tokenDigest: String?
    private(set) var transferGeneration: UInt32?
    var removeConfiguration: (String) -> Void = { _ in }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            if let record = try? JSONDecoder().decode(CleanupRecord.self, from: data) {
                unresolved = record.lease
                recordedSSID = record.ssid
                tokenDigest = record.tokenDigest
                transferGeneration = record.transferGeneration
            } else {
                unresolved = try? JSONDecoder().decode(Lease.self, from: data)
                unreadableCleanupRecord = unresolved == nil
            }
        }
    }
    func reconcileClear(deviceID: String) {
        guard lease == nil, unresolved?.deviceID == deviceID else { return }
        if let recordedSSID { removeConfiguration(recordedSSID) }
        unresolved = nil
        recordedSSID = nil
        tokenDigest = nil
        transferGeneration = nil
        defaults.removeObject(forKey: key)
    }
    var isCleanupComplete: Bool {
        lease == nil && unresolved == nil && !unreadableCleanupRecord &&
            claims.isEmpty && pendingApplies.isEmpty
    }

    /// Fresh authenticated empty status plus the caller's exact precommit
    /// receipt permits replacing an expired transport, never its logical map
    /// operation. No OS upload, pending apply, or other manager may be displaced.
    func retireStoppedMapForPrecommitRecovery(deviceID: String, currentOwner: Lease?) throws {
        guard !unreadableCleanupRecord, pendingApplies.isEmpty,
              let stored = unresolved, stored.deviceID == deviceID, stored.mode == "map" else {
            throw Failure.staleOwner
        }
        if let lease {
            guard lease == stored, currentOwner == lease, claims == [lease.id] else {
                throw Failure.busy
            }
        } else {
            guard currentOwner == nil, claims.isEmpty else { throw Failure.busy }
        }
        if let network = ssid ?? recordedSSID { removeConfiguration(network) }
        claims.removeAll()
        lease = nil
        unresolved = nil
        ssid = nil
        recordedSSID = nil
        tokenDigest = nil
        transferGeneration = nil
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard let unresolved else { return }
        let record = CleanupRecord(lease: unresolved, ssid: recordedSSID,
                                   tokenDigest: tokenDigest, transferGeneration: transferGeneration)
        defaults.set(try? JSONEncoder().encode(record), forKey: key)
    }
    func recordAuthorization(_ value: Lease, digest: String, generation: UInt32) {
        guard owns(value) else { return }
        tokenDigest = digest
        transferGeneration = generation
        persist()
    }
    func adoptUnresolved(epoch: UInt64) throws -> Lease {
        guard lease == nil, let old = unresolved else { throw Failure.busy }
        let value = Lease(id: old.id, deviceID: old.deviceID, mode: old.mode, connectionEpoch: epoch)
        lease = value
        unresolved = value
        claims = [value.id]
        ssid = recordedSSID
        persist()
        return value
    }
    /// Called only after a fresh authenticated status matches the persisted
    /// mode, device, token digest and generation. Restored OS claims survive.
    func resumeMapRoot(deviceID: String, epoch: UInt64, currentOwner: Lease?) throws -> Lease {
        guard let stored = unresolved, stored.mode == "map", stored.deviceID == deviceID,
              pendingApplies.isEmpty else { throw Failure.staleOwner }
        if let lease {
            guard lease == stored,
                  currentOwner == lease || !claims.contains(lease.id) else { throw Failure.busy }
        } else if currentOwner != nil {
            throw Failure.staleOwner
        }
        let resumed = Lease(id: stored.id, deviceID: stored.deviceID, mode: stored.mode, connectionEpoch: epoch)
        lease = resumed
        unresolved = resumed
        claims.insert(resumed.id)
        ssid = recordedSSID
        persist()
        return resumed
    }
    func restoreClaim(operationID: UUID, deviceID: String, network: String?) -> UUID? {
        guard let stored = unresolved, stored.id == operationID, stored.deviceID == deviceID,
              stored.mode == "map", recordedSSID == network else { return nil }
        if lease == nil {
            lease = stored
            claims = [] // OS task only; there is no surviving foreground task.
            ssid = recordedSSID
        }
        return retain(operationID: operationID)
    }
    func acquire(deviceID: String, mode: String, epoch: UInt64) throws -> Lease {
        guard lease == nil else { throw Failure.busy }
        guard unresolved == nil, !unreadableCleanupRecord else { throw Failure.cleanupUnresolved }
        let value = Lease(id: UUID(), deviceID: deviceID, mode: mode, connectionEpoch: epoch)
        lease = value
        claims = [value.id] // root spans acquisition, upload AND confirmation
        unresolved = value
        recordedSSID = nil
        tokenDigest = nil
        transferGeneration = nil
        persist()
        return value
    }
    func rebindAfterMaintenance(_ value: Lease, epoch: UInt64) throws -> Lease {
        guard owns(value), claims == [value.id], pendingApplies.isEmpty else { throw Failure.staleOwner }
        let rebound = Lease(id: value.id, deviceID: value.deviceID, mode: value.mode, connectionEpoch: epoch)
        lease = rebound
        unresolved = rebound
        persist()
        return rebound
    }
    func owns(_ value: Lease) -> Bool { lease == value }
    func retain(operationID: UUID) -> UUID? {
        guard lease?.id == operationID else { return nil }
        let claim = UUID()
        claims.insert(claim)
        return claim
    }
    func configure(_ network: String, for value: Lease) throws {
        guard owns(value) else { throw Failure.staleOwner }
        ssid = network
        recordedSSID = network
        persist()
    }
    func removeForRetry(_ value: Lease) {
        guard owns(value), pendingApplies.isEmpty, let ssid else { return }
        removeConfiguration(ssid)
    }
    func beginApply(_ value: Lease) throws -> UUID {
        guard owns(value), pendingApplies.isEmpty else { throw Failure.busy }
        let id = UUID()
        pendingApplies.insert(id)
        return id
    }
    func finishApply(_ id: UUID, for value: Lease) {
        guard owns(value), pendingApplies.remove(id) != nil else { return }
        finishIfUnused()
    }
    func release(_ claim: UUID) {
        guard claims.remove(claim) != nil else { return }
        finishIfUnused()
    }
    func finish(_ value: Lease, remoteClear: Bool) {
        guard owns(value) else { return }
        if remoteClear {
            unresolved = nil
            defaults.removeObject(forKey: key)
        }
        release(value.id)
    }
    private func finishIfUnused() {
        guard claims.isEmpty, pendingApplies.isEmpty else { return }
        // Removal and generation retirement run in the same executor turn.
        if let ssid { removeConfiguration(ssid) }
        ssid = nil
        lease = nil
    }
}

/// Shared by every consumer's exit path. An unstructured task deliberately
/// detaches cancellation lifetime, while preserving MainActor BLE isolation.
enum DeviceOperationCleanupTask {
    @MainActor static func start(
        _ operation: @escaping @MainActor () async -> Bool
    ) -> Task<Bool, Never> {
        Task { @MainActor in await operation() }
    }
}
