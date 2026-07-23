import Foundation

nonisolated protocol WorkoutRecoveryPersistence {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
    func quarantine(_ data: Data) throws
    func loadTakeoverJournal() throws -> Data?
    func saveTakeoverJournal(_ data: Data) throws
    func clearTakeoverJournal() throws
}

nonisolated extension WorkoutRecoveryPersistence {
    func quarantine(_ data: Data) throws {
        throw RecoveryStoreError.quarantineUnsupported
    }

    func loadTakeoverJournal() throws -> Data? { nil }

    func saveTakeoverJournal(_ data: Data) throws {
        throw RecoveryStoreError.takeoverJournalUnsupported
    }

    func clearTakeoverJournal() throws {}
}

nonisolated struct WorkoutRecoveryFilePersistence: WorkoutRecoveryPersistence {
    let fileURL: URL

    private var takeoverJournalURL: URL {
        fileURL.appendingPathExtension("takeover-journal")
    }

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL)
    }

    func save(_ data: Data) throws {
        try writeDurably(data, to: fileURL)
    }

    func quarantine(_ data: Data) throws {
        let extensionSuffix = fileURL.pathExtension.isEmpty
            ? ""
            : ".\(fileURL.pathExtension)"
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let quarantineURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(baseName)-corrupt-\(UUID().uuidString)\(extensionSuffix)"
            )
        try writeDurably(data, to: quarantineURL)
    }

    func loadTakeoverJournal() throws -> Data? {
        guard FileManager.default.fileExists(
            atPath: takeoverJournalURL.path
        ) else {
            return nil
        }
        return try Data(contentsOf: takeoverJournalURL)
    }

    func saveTakeoverJournal(_ data: Data) throws {
        try writeDurably(data, to: takeoverJournalURL)
    }

    func clearTakeoverJournal() throws {
        guard FileManager.default.fileExists(
            atPath: takeoverJournalURL.path
        ) else {
            return
        }
        try FileManager.default.removeItem(at: takeoverJournalURL)
    }

    private func writeDurably(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        let handle = try FileHandle(forUpdating: destination)
        defer { try? handle.close() }
        try handle.synchronize()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = destination
        try? mutableURL.setResourceValues(values)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

private nonisolated struct UnavailableWorkoutRecoveryPersistence: WorkoutRecoveryPersistence {
    struct Unavailable: Error {}

    func load() throws -> Data? { throw Unavailable() }
    func save(_ data: Data) throws { throw Unavailable() }
    func clear() throws { throw Unavailable() }
    func quarantine(_ data: Data) throws { throw Unavailable() }
}

nonisolated final class WatchWorkoutRecoveryStore {
    enum LoadState: Equatable {
        case missing
        case valid
        case unavailable
        case corrupt
    }

    struct FinishRequest: Codable, Equatable {
        let disposition: WorkoutFinishDisposition
        let requestedAt: Date
        var phase: WorkoutFinalizationPhase
        var routeStatus: WorkoutRouteSaveStatus?
        var terminalErrorCode: WorkoutSafeErrorCodeV1?

        init(
            disposition: WorkoutFinishDisposition,
            requestedAt: Date,
            phase: WorkoutFinalizationPhase = .requested,
            routeStatus: WorkoutRouteSaveStatus? = nil,
            terminalErrorCode: WorkoutSafeErrorCodeV1? = nil
        ) {
            self.disposition = disposition
            self.requestedAt = requestedAt
            self.phase = phase
            self.routeStatus = routeStatus
            self.terminalErrorCode = terminalErrorCode
        }

        private enum CodingKeys: String, CodingKey {
            case disposition
            case requestedAt
            case phase
            case routeStatus
            case terminalErrorCode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            disposition = try container.decode(
                WorkoutFinishDisposition.self,
                forKey: .disposition
            )
            requestedAt = try container.decode(Date.self, forKey: .requestedAt)
            phase = try container.decodeIfPresent(
                WorkoutFinalizationPhase.self,
                forKey: .phase
            ) ?? .requested
            routeStatus = try container.decodeIfPresent(
                WorkoutRouteSaveStatus.self,
                forKey: .routeStatus
            )
            terminalErrorCode = try container.decodeIfPresent(
                WorkoutSafeErrorCodeV1.self,
                forKey: .terminalErrorCode
            )
        }
    }

    struct Identity: Codable, Equatable {
        let sessionID: UUID
        /// The validated HealthKit external UUID when a cleanup-only local
        /// transport identity was created before builder metadata appeared.
        /// Keeping this separate avoids changing an already-published session
        /// ID and preserves receiver ordering across the late bind.
        var healthKitSessionID: UUID?
        let sessionToken: UInt16
        let transportGenerationID: UUID?
        let startDate: Date
        var sequenceHighWatermark: UInt64
        var remoteControlCheckpoint:
            WorkoutRemoteControlSequenceGate.Checkpoint? = nil
        /// A remotely requested segment boundary is journaled with the replay
        /// checkpoint before its HealthKit event write begins. This closes the
        /// crash window where the checkpoint was durable but the event was not.
        var remoteSegmentIntent: RemoteSegmentIntent? = nil
        var remoteTerminalAcknowledgement:
            RemoteTerminalAcknowledgement? = nil
        var finishRequest: FinishRequest?
        /// A rider-confirmed corrupt-state reset cannot recover the lost
        /// Save/Discard choice. Keep that provenance durable until the rider
        /// explicitly chooses; any earlier terminal transition is discard-only.
        var corruptResetPendingFinishChoice: Bool?
        /// True only while a locally generated cleanup UUID stands in for a
        /// metadata-less recovered builder. It may later bind once to the
        /// builder's genuine validated UUID, but can never become saveable.
        var corruptResetSyntheticCleanupIdentity: Bool?
    }

    struct RemoteSegmentIntent: Codable, Equatable {
        let controlSenderID: UUID?
        let acknowledgedSequence: UInt64
        let capturedAt: Date
        let completedSegment: WorkoutCompletedSegmentV1
        let cumulativeElapsedTime: TimeInterval
        let cumulativeDistanceMeters: Double?
        let cumulativeDistanceSource: WorkoutMetricSourceV1?

        var isValid: Bool {
            acknowledgedSequence > 0
                && capturedAt.timeIntervalSinceReferenceDate.isFinite
                && completedSegment.index > 0
                && completedSegment.startedAt
                    .timeIntervalSinceReferenceDate.isFinite
                && completedSegment.endedAt
                    .timeIntervalSinceReferenceDate.isFinite
                && completedSegment.endedAt >= completedSegment.startedAt
                && completedSegment.duration.isFinite
                && completedSegment.duration >= 0
                && completedSegment.distanceMeters.map {
                    $0.isFinite && $0 >= 0
                } ?? true
                && cumulativeElapsedTime.isFinite
                && cumulativeElapsedTime >= completedSegment.duration
                && cumulativeDistanceMeters.map {
                    $0.isFinite && $0 >= 0
                } ?? true
        }

        func matches(_ envelope: WorkoutEnvelopeV1) -> Bool {
            envelope.control == .markSegment
                && envelope.controlSenderID == controlSenderID
                && envelope.sequence == acknowledgedSequence
                && envelope.capturedAt == capturedAt
        }
    }

    struct RemoteTerminalAcknowledgement: Codable, Equatable {
        let control: WorkoutControlV1
        let controlSenderID: UUID?
        let acknowledgedSequence: UInt64
        /// Captured time of the accepted iPhone control, used for exact replay.
        let capturedAt: Date
        /// Pre-reserved Watch sequence for idempotent acknowledgement replay.
        let envelopeSequence: UInt64
        let envelopeCapturedAt: Date

        var disposition: WorkoutFinishDisposition? {
            switch control {
            case .endAndSave:
                .save
            case .discard:
                .discard
            case .requestCurrentSnapshot, .pause, .resume, .markSegment:
                nil
            }
        }
    }

    struct TerminalTombstone: Codable, Equatable {
        let sessionID: UUID
        let startDate: Date
        let savedAt: Date
        let routeStatus: WorkoutRouteSaveStatus
        let disposition: WorkoutFinishDisposition
        /// A corrupt-reset cleanup may finish before HealthKit publishes its
        /// genuine external UUID. In that one case the synthetic tombstone
        /// remains matchable by the recovered session's exact start date.
        let allowsLateHealthKitSessionIDMatch: Bool

        init(
            sessionID: UUID,
            startDate: Date,
            savedAt: Date,
            routeStatus: WorkoutRouteSaveStatus,
            disposition: WorkoutFinishDisposition,
            allowsLateHealthKitSessionIDMatch: Bool = false
        ) {
            self.sessionID = sessionID
            self.startDate = startDate
            self.savedAt = savedAt
            self.routeStatus = routeStatus
            self.disposition = disposition
            self.allowsLateHealthKitSessionIDMatch =
                allowsLateHealthKitSessionIDMatch
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID
            case startDate
            case savedAt
            case routeStatus
            case disposition
            case allowsLateHealthKitSessionIDMatch
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decode(UUID.self, forKey: .sessionID)
            startDate = try container.decode(Date.self, forKey: .startDate)
            savedAt = try container.decode(Date.self, forKey: .savedAt)
            routeStatus = try container.decode(
                WorkoutRouteSaveStatus.self,
                forKey: .routeStatus
            )
            // Tombstones written before discard terminalization existed were
            // all confirmed saves.
            disposition = try container.decodeIfPresent(
                WorkoutFinishDisposition.self,
                forKey: .disposition
            ) ?? .save
            allowsLateHealthKitSessionIDMatch = try container.decodeIfPresent(
                Bool.self,
                forKey: .allowsLateHealthKitSessionIDMatch
            ) ?? false
        }
    }

    private struct CorruptResetAuthorization: Codable, Equatable {
        let authorizedAt: Date
    }

    private struct PersistedState: Codable {
        var activeIdentity: Identity?
        var terminalTombstones: [TerminalTombstone]
        var corruptResetAuthorization: CorruptResetAuthorization?
    }

    /// Write-ahead provenance for a cross-app takeover. This lives outside the
    /// primary identity file so a failed identity save followed by process
    /// death cannot turn a displaced partial ride into an unexplained result.
    private struct TakeoverJournal: Codable, Equatable {
        let sessionID: UUID
        let disposition: WorkoutFinishDisposition
        let requestedAt: Date
        let explicitRiderChoice: Bool
    }

    private let persistence: any WorkoutRecoveryPersistence
    private var identity: Identity?
    private var terminalTombstones: [TerminalTombstone]
    private var corruptResetAuthorization: CorruptResetAuthorization?
    private var takeoverJournal: TakeoverJournal?
    private var sequenceLease: WorkoutSequenceLease?
    private(set) var loadState: LoadState

    convenience init() {
        self.init(persistence: Self.makeDefaultPersistence())
    }

    init(persistence: any WorkoutRecoveryPersistence) {
        self.persistence = persistence
        identity = nil
        terminalTombstones = []
        corruptResetAuthorization = nil
        takeoverJournal = nil
        loadState = .missing
        reload()
    }

    func reload() {
        sequenceLease = nil
        do {
            guard let data = try persistence.load() else {
                identity = nil
                terminalTombstones = []
                corruptResetAuthorization = nil
                takeoverJournal = nil
                try? persistence.clearTakeoverJournal()
                loadState = .missing
                return
            }
            guard let state = Self.decodeState(from: data) else {
                identity = nil
                terminalTombstones = []
                corruptResetAuthorization = nil
                takeoverJournal = nil
                loadState = .corrupt
                return
            }
            identity = state.activeIdentity
            terminalTombstones = state.terminalTombstones
            corruptResetAuthorization = state.corruptResetAuthorization
            loadState = .valid
            try loadAndMergeTakeoverJournal()
        } catch {
            identity = nil
            terminalTombstones = []
            corruptResetAuthorization = nil
            takeoverJournal = nil
            loadState = .unavailable
        }
    }

    var recoveredIdentity: Identity? { identity }
    var recoveredTerminalTombstones: [TerminalTombstone] { terminalTombstones }
    var hasCorruptResetAuthorization: Bool {
        corruptResetAuthorization != nil
    }
    func authorizesCorruptResetRecovery(startDate: Date) -> Bool {
        guard let authorizedAt = corruptResetAuthorization?.authorizedAt,
              startDate.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        // A reset can clean up only a session that already existed when the
        // rider approved it. Never let stale authority capture a future ride.
        return startDate <= authorizedAt
    }
    var hasCorruptResetProtection: Bool {
        corruptResetAuthorization != nil
            || identity?.corruptResetPendingFinishChoice == true
    }
    var hasCorruptResetPendingIdentity: Bool {
        identity?.corruptResetPendingFinishChoice == true
    }

    func begin(startDate: Date) throws -> Identity {
        guard [.missing, .valid].contains(loadState), identity == nil else {
            throw RecoveryStoreError.unreadableOrOccupiedState
        }
        let identity = Identity(
            sessionID: UUID(),
            healthKitSessionID: nil,
            sessionToken: Self.makeNonzeroToken(),
            transportGenerationID: UUID(),
            startDate: startDate,
            sequenceHighWatermark: 0,
            finishRequest: nil,
            corruptResetPendingFinishChoice: nil,
            corruptResetSyntheticCleanupIdentity: nil
        )
        try persist(identity)
        self.identity = identity
        sequenceLease = nil
        return identity
    }

    func useRecoveredIdentity(
        startDate: Date,
        stableSessionID: UUID? = nil,
        discardTerminalAt: Date? = nil
    ) throws -> Identity {
        if let currentIdentity = identity,
           abs(currentIdentity.startDate.timeIntervalSince(startDate)) <= 2,
           currentIdentity.corruptResetPendingFinishChoice == true,
           currentIdentity.corruptResetSyntheticCleanupIdentity == true,
           currentIdentity.finishRequest?.disposition == .discard,
           currentIdentity.healthKitSessionID == nil,
           let stableSessionID,
           stableSessionID != Self.zeroUUID,
           stableSessionID != currentIdentity.sessionID {
            var reboundIdentity = currentIdentity
            reboundIdentity.healthKitSessionID = stableSessionID
            reboundIdentity.corruptResetSyntheticCleanupIdentity = true
            try persist(reboundIdentity)
            identity = reboundIdentity
            sequenceLease = nil
            return reboundIdentity
        }
        if let identity,
           abs(identity.startDate.timeIntervalSince(startDate)) <= 2,
           stableSessionID == nil
                || stableSessionID == identity.healthKitSessionID
                || (identity.healthKitSessionID == nil
                    && stableSessionID == identity.sessionID) {
            return identity
        }

        let isCorruptResetRecovery = corruptResetAuthorization != nil
        guard identity == nil,
              loadState == .missing || isCorruptResetRecovery,
              startDate.timeIntervalSinceReferenceDate.isFinite,
              !isCorruptResetRecovery
                || authorizesCorruptResetRecovery(startDate: startDate),
              let stableSessionID,
              stableSessionID != Self.zeroUUID,
              discardTerminalAt?.timeIntervalSinceReferenceDate.isFinite
                ?? true,
              discardTerminalAt == nil || isCorruptResetRecovery else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }

        // A fully validated HealthKit identity is authoritative only when the
        // local file is confirmed absent. Corrupt or unavailable state could
        // still contain a discard request or terminal tombstones and must not
        // be overwritten. Adopt the exact UUID only
        // after the replacement state is durably written; never invent a new
        // external UUID for an already-running workout.
        let recoveredIdentity = Identity(
            sessionID: stableSessionID,
            healthKitSessionID: nil,
            sessionToken: Self.makeNonzeroToken(),
            transportGenerationID: UUID(),
            startDate: startDate,
            sequenceHighWatermark: 0,
            finishRequest: discardTerminalAt.map {
                FinishRequest(
                    disposition: .discard,
                    requestedAt: $0,
                    phase: .requested
                )
            },
            corruptResetPendingFinishChoice: isCorruptResetRecovery ? true : nil,
            corruptResetSyntheticCleanupIdentity: nil
        )
        try persist(
            recoveredIdentity,
            preserveCorruptResetAuthorization: false
        )
        identity = recoveredIdentity
        corruptResetAuthorization = nil
        sequenceLease = nil
        return recoveredIdentity
    }

    /// Creates a durable discard-only identity for a rider-abandoned recovered
    /// session whose HealthKit builder never received valid identity metadata.
    /// The generated UUID is local cleanup bookkeeping only and is never used
    /// to save the workout.
    func useCorruptResetDiscardIdentity(
        startDate: Date,
        requestedAt: Date
    ) throws -> Identity {
        guard identity == nil,
              loadState == .valid,
              authorizesCorruptResetRecovery(startDate: startDate),
              startDate.timeIntervalSinceReferenceDate.isFinite,
              requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        let cleanupIdentity = Identity(
            sessionID: UUID(),
            healthKitSessionID: nil,
            sessionToken: Self.makeNonzeroToken(),
            transportGenerationID: UUID(),
            startDate: startDate,
            sequenceHighWatermark: 0,
            finishRequest: FinishRequest(
                disposition: .discard,
                requestedAt: requestedAt,
                phase: .requested
            ),
            corruptResetPendingFinishChoice: true,
            corruptResetSyntheticCleanupIdentity: true
        )
        try persist(
            cleanupIdentity,
            preserveCorruptResetAuthorization: false
        )
        identity = cleanupIdentity
        corruptResetAuthorization = nil
        sequenceLease = nil
        return cleanupIdentity
    }

    func nextSequence() -> UInt64? {
        if sequenceLease == nil || sequenceLease?.isExhausted == true {
            guard (try? reserveSequenceLease()) == true else { return nil }
        }
        return sequenceLease?.take()
    }

    @discardableResult
    func persistRemoteControlCheckpoint(
        _ checkpoint: WorkoutRemoteControlSequenceGate.Checkpoint,
        finishing disposition: WorkoutFinishDisposition? = nil,
        requestedAt: Date? = nil,
        explicitRiderChoice: Bool = true,
        terminalErrorCode: WorkoutSafeErrorCodeV1? = nil,
        terminalAcknowledgement: RemoteTerminalAcknowledgement? = nil
    ) throws -> WorkoutFinishDisposition? {
        guard checkpoint.isValid,
              (disposition == nil) == (requestedAt == nil),
              terminalAcknowledgement.map({ acknowledgement in
                  guard acknowledgement.disposition != nil,
                        acknowledgement.capturedAt
                            .timeIntervalSinceReferenceDate.isFinite,
                        acknowledgement.envelopeSequence > 0,
                        acknowledgement.envelopeCapturedAt
                            .timeIntervalSinceReferenceDate.isFinite else {
                      return false
                  }
                  if let senderID = acknowledgement.controlSenderID {
                      return checkpoint.seenSenderIDs.contains(senderID)
                          && (checkpoint.currentSenderID != senderID
                              || checkpoint.highestSequence
                                  >= acknowledgement.acknowledgedSequence)
                  }
                  return checkpoint.legacyHighestSequence
                      >= acknowledgement.acknowledgedSequence
              }) ?? true,
              var identity else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        identity.remoteControlCheckpoint = checkpoint
        let effectiveDisposition: WorkoutFinishDisposition?
        var takeoverJournalRequest: (
            disposition: WorkoutFinishDisposition,
            requestedAt: Date,
            explicitRiderChoice: Bool
        )?
        if let disposition, let requestedAt {
            let resolvedTerminalErrorCode = WorkoutTerminalErrorPolicy.resolve(
                summaryError: terminalErrorCode,
                persistedFinishError: identity.finishRequest?.terminalErrorCode
                    ?? (takeoverJournal?.sessionID == identity.sessionID
                        ? .anotherWorkoutActive
                        : nil)
            )
            effectiveDisposition = try applyFinishRequest(
                to: &identity,
                disposition: disposition,
                requestedAt: requestedAt,
                explicitRiderChoice: explicitRiderChoice,
                terminalErrorCode: resolvedTerminalErrorCode
            )
            if resolvedTerminalErrorCode == .anotherWorkoutActive,
               let effectiveDisposition {
                takeoverJournalRequest = (
                    disposition: effectiveDisposition,
                    requestedAt: requestedAt,
                    explicitRiderChoice: explicitRiderChoice
                )
            }
        } else {
            effectiveDisposition = nil
        }
        if let terminalAcknowledgement {
            guard terminalAcknowledgement.disposition
                    == identity.finishRequest?.disposition,
                  terminalAcknowledgement.envelopeSequence
                    <= identity.sequenceHighWatermark else {
                throw RecoveryStoreError.missingOrInvalidIdentity
            }
            identity.remoteTerminalAcknowledgement =
                terminalAcknowledgement
        }
        if let takeoverJournalRequest {
            try writeTakeoverJournal(
                sessionID: identity.sessionID,
                disposition: takeoverJournalRequest.disposition,
                requestedAt: takeoverJournalRequest.requestedAt,
                explicitRiderChoice:
                    takeoverJournalRequest.explicitRiderChoice
            )
            // If the primary transaction fails, later recovery writes must
            // flush checkpoint and acknowledgement obligation together.
            self.identity = identity
        }
        try persist(identity)
        self.identity = identity
        return effectiveDisposition
    }

    func persistRemoteSegmentControl(
        checkpoint: WorkoutRemoteControlSequenceGate.Checkpoint,
        intent: RemoteSegmentIntent
    ) throws {
        guard checkpoint.isValid,
              intent.isValid,
              intent.controlSenderID.map({ senderID in
                  checkpoint.seenSenderIDs.contains(senderID)
                      && (checkpoint.currentSenderID != senderID
                          || checkpoint.highestSequence
                              >= intent.acknowledgedSequence)
              }) ?? (
                  checkpoint.legacyHighestSequence
                      >= intent.acknowledgedSequence
              ),
              var identity else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        identity.remoteControlCheckpoint = checkpoint
        identity.remoteSegmentIntent = intent
        try persist(identity)
        self.identity = identity
    }

    func clearRemoteSegmentIntent(
        matching envelope: WorkoutEnvelopeV1
    ) throws {
        guard var identity else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        guard identity.remoteSegmentIntent?.matches(envelope) == true else {
            return
        }
        identity.remoteSegmentIntent = nil
        try persist(identity)
        self.identity = identity
    }

    @discardableResult
    func markFinishing(
        disposition: WorkoutFinishDisposition,
        requestedAt: Date,
        explicitRiderChoice: Bool = true,
        terminalErrorCode: WorkoutSafeErrorCodeV1? = nil
    ) throws -> WorkoutFinishDisposition {
        guard var identity else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        let resolvedTerminalErrorCode = WorkoutTerminalErrorPolicy.resolve(
            summaryError: terminalErrorCode,
            persistedFinishError: identity.finishRequest?.terminalErrorCode
                ?? (takeoverJournal?.sessionID == identity.sessionID
                    ? .anotherWorkoutActive
                    : nil)
        )
        let retainedExplicitJournalChoice = !explicitRiderChoice
            ? takeoverJournal.flatMap { journal in
                journal.sessionID == identity.sessionID
                    && journal.explicitRiderChoice
                    ? journal.disposition
                    : nil
            }
            : nil
        let effectiveExplicitRiderChoice = explicitRiderChoice
            || retainedExplicitJournalChoice != nil
        let effectiveDisposition = try applyFinishRequest(
            to: &identity,
            disposition: retainedExplicitJournalChoice ?? disposition,
            requestedAt: requestedAt,
            explicitRiderChoice: effectiveExplicitRiderChoice,
            terminalErrorCode: resolvedTerminalErrorCode
        )
        if resolvedTerminalErrorCode == .anotherWorkoutActive {
            try writeTakeoverJournal(
                sessionID: identity.sessionID,
                disposition: effectiveDisposition,
                requestedAt: requestedAt,
                explicitRiderChoice: effectiveExplicitRiderChoice
            )
            self.identity = identity
        }
        try persist(identity)
        self.identity = identity
        return effectiveDisposition
    }

    func markTerminalError(
        _ terminalErrorCode: WorkoutSafeErrorCodeV1
    ) throws {
        guard var identity,
              var request = identity.finishRequest else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        let resolvedErrorCode = WorkoutTerminalErrorPolicy.resolve(
            summaryError: terminalErrorCode,
            persistedFinishError: request.terminalErrorCode
                ?? (takeoverJournal?.sessionID == identity.sessionID
                    ? .anotherWorkoutActive
                    : nil)
        )
        guard request.terminalErrorCode != resolvedErrorCode else { return }
        request.terminalErrorCode = resolvedErrorCode
        identity.finishRequest = request
        if resolvedErrorCode == .anotherWorkoutActive {
            try writeTakeoverJournal(
                sessionID: identity.sessionID,
                disposition: request.disposition,
                requestedAt: request.requestedAt,
                explicitRiderChoice: true
            )
            self.identity = identity
        }
        try persist(identity)
        self.identity = identity
    }

    private func applyFinishRequest(
        to identity: inout Identity,
        disposition: WorkoutFinishDisposition,
        requestedAt: Date,
        explicitRiderChoice: Bool,
        terminalErrorCode: WorkoutSafeErrorCodeV1?
    ) throws -> WorkoutFinishDisposition {
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        let effectiveDisposition = identity.corruptResetPendingFinishChoice == true
            && !explicitRiderChoice
            ? .discard
            : disposition
        if explicitRiderChoice {
            identity.corruptResetPendingFinishChoice = false
        }
        identity.finishRequest = FinishRequest(
            disposition: effectiveDisposition,
            requestedAt: requestedAt,
            phase: .requested,
            terminalErrorCode: terminalErrorCode
                ?? identity.finishRequest?.terminalErrorCode
        )
        return effectiveDisposition
    }

    func markCollectionEnded() throws {
        try advanceFinalization(to: .collectionEnded)
    }

    func markPreparedRoute(_ status: WorkoutRouteSaveStatus) throws {
        guard var identity,
              var request = identity.finishRequest,
              request.disposition == .save else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        request.routeStatus = status
        identity.finishRequest = request
        try persist(identity)
        self.identity = identity
    }

    func markFinishAttempted() throws {
        try advanceFinalization(to: .finishAttempted)
    }

    func markFinishFailed() throws {
        guard var identity,
              var request = identity.finishRequest,
              request.disposition == .save,
              request.phase == .finishAttempted else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        request.phase = .collectionEnded
        identity.finishRequest = request
        try persist(identity)
        self.identity = identity
    }

    func markWorkoutSaved() throws {
        try advanceFinalization(to: .workoutSaved)
    }

    func archiveConfirmedSavedIdentity(at savedAt: Date = Date()) throws -> TerminalTombstone {
        guard let identity,
              let request = identity.finishRequest,
              request.disposition == .save,
              [.finishAttempted, .workoutSaved].contains(request.phase),
              savedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        return try archiveTerminalIdentity(
            identity,
            request: request,
            at: savedAt
        )
    }

    func archiveConfirmedDiscardedIdentity(
        at discardedAt: Date = Date()
    ) throws -> TerminalTombstone {
        guard let identity,
              let request = identity.finishRequest,
              request.disposition == .discard,
              discardedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        return try archiveTerminalIdentity(
            identity,
            request: request,
            at: discardedAt
        )
    }

    private func archiveTerminalIdentity(
        _ identity: Identity,
        request: FinishRequest,
        at terminalDate: Date
    ) throws -> TerminalTombstone {
        let tombstone = TerminalTombstone(
            sessionID: identity.healthKitSessionID ?? identity.sessionID,
            startDate: identity.startDate,
            savedAt: terminalDate,
            routeStatus: request.disposition == .save
                ? request.routeStatus ?? .unknown
                : .unavailable,
            disposition: request.disposition,
            allowsLateHealthKitSessionIDMatch:
                request.disposition == .discard
                    && identity.corruptResetSyntheticCleanupIdentity == true
                    && identity.healthKitSessionID == nil
        )
        var updatedTombstones = terminalTombstones.filter {
            $0.sessionID != tombstone.sessionID
        }
        updatedTombstones.append(tombstone)
        if updatedTombstones.count > 8 {
            updatedTombstones.removeFirst(updatedTombstones.count - 8)
        }
        try persistState(
            activeIdentity: nil,
            terminalTombstones: updatedTombstones
        )
        self.identity = nil
        self.terminalTombstones = updatedTombstones
        sequenceLease = nil
        return tombstone
    }

    func terminalTombstone(
        externalUUID: String?,
        recoveredSessionStartDate: Date? = nil
    ) -> TerminalTombstone? {
        guard let externalUUID,
              let sessionID = UUID(uuidString: externalUUID),
              sessionID != Self.zeroUUID else {
            return nil
        }
        if let exactMatch = terminalTombstones.last(where: {
            $0.sessionID == sessionID
        }) {
            return exactMatch
        }
        guard let recoveredSessionStartDate,
              recoveredSessionStartDate.timeIntervalSinceReferenceDate.isFinite
        else {
            return nil
        }
        return terminalTombstones.last {
            $0.allowsLateHealthKitSessionIDMatch
                && $0.disposition == .discard
                && $0.startDate == recoveredSessionStartDate
        }
    }

    func removeTerminalTombstone(sessionID: UUID) throws {
        let updatedTombstones = terminalTombstones.filter {
            $0.sessionID != sessionID
        }
        guard updatedTombstones.count != terminalTombstones.count else { return }
        try persistState(
            activeIdentity: identity,
            terminalTombstones: updatedTombstones
        )
        terminalTombstones = updatedTombstones
    }

    func clear() throws {
        try persistState(
            activeIdentity: nil,
            terminalTombstones: terminalTombstones,
            preserveCorruptResetAuthorization: true
        )
        identity = nil
        sequenceLease = nil
    }

    func quarantineCorruptState() throws {
        guard loadState == .corrupt,
              let data = try persistence.load(),
              Self.decodeState(from: data) == nil else {
            reload()
            throw RecoveryStoreError.stateChanged
        }

        // A rider-confirmed reset never destroys the only copy. Preserve the
        // exact unreadable bytes durably before replacing the active file.
        let authorization = CorruptResetAuthorization(authorizedAt: Date())
        let replacement = PersistedState(
            activeIdentity: nil,
            terminalTombstones: [],
            corruptResetAuthorization: authorization
        )
        let replacementData = try PropertyListEncoder().encode(replacement)
        try persistence.quarantine(data)
        // Atomically replace the corrupt active file with a durable one-shot
        // authorization. There is no crash window in which a recoverable
        // stopped/ended HealthKit session has neither its original bytes nor
        // rider-approved discard-only recovery state.
        try persistence.save(replacementData)
        identity = nil
        terminalTombstones = []
        corruptResetAuthorization = authorization
        sequenceLease = nil
        loadState = .valid
    }

    private func reserveSequenceLease() throws -> Bool {
        guard var identity,
              identity.sequenceHighWatermark != UInt64.max else {
            return false
        }
        let lease = WorkoutSequenceLease(after: identity.sequenceHighWatermark)
        guard !lease.isExhausted else { return false }
        identity.sequenceHighWatermark = lease.persistedHighWatermark

        // The high watermark must be durably reserved before any value from
        // the lease is returned to transport code.
        try persist(identity)
        self.identity = identity
        self.sequenceLease = lease
        return true
    }

    private func advanceFinalization(
        to phase: WorkoutFinalizationPhase
    ) throws {
        guard var identity,
              var request = identity.finishRequest,
              request.disposition == .save,
              Self.rank(phase) >= Self.rank(request.phase) else {
            throw RecoveryStoreError.missingOrInvalidIdentity
        }
        request.phase = phase
        identity.finishRequest = request
        try persist(identity)
        self.identity = identity
    }

    private func persist(
        _ identity: Identity,
        preserveCorruptResetAuthorization: Bool = true
    ) throws {
        try persistState(
            activeIdentity: identity,
            terminalTombstones: terminalTombstones,
            preserveCorruptResetAuthorization: preserveCorruptResetAuthorization
        )
    }

    private func persistState(
        activeIdentity: Identity?,
        terminalTombstones: [TerminalTombstone],
        preserveCorruptResetAuthorization: Bool = true
    ) throws {
        guard [.missing, .valid].contains(loadState) else {
            throw RecoveryStoreError.unreadableOrOccupiedState
        }
        let authorization = preserveCorruptResetAuthorization
            ? corruptResetAuthorization
            : nil
        if activeIdentity == nil,
           terminalTombstones.isEmpty,
           authorization == nil {
            try persistence.clear()
            loadState = .missing
            clearTakeoverJournalBestEffort()
            return
        }
        let state = PersistedState(
            activeIdentity: activeIdentity,
            terminalTombstones: terminalTombstones,
            corruptResetAuthorization: authorization
        )
        let data = try PropertyListEncoder().encode(state)
        try persistence.save(data)
        loadState = .valid
        if let activeIdentity {
            clearTakeoverJournalIfCovered(by: activeIdentity)
        } else if let takeoverJournal,
                  terminalTombstones.contains(where: {
                      $0.sessionID == takeoverJournal.sessionID
                  }) {
            clearTakeoverJournalBestEffort()
        }
    }

    private func loadAndMergeTakeoverJournal() throws {
        guard let data = try persistence.loadTakeoverJournal() else {
            takeoverJournal = nil
            return
        }
        guard let journal = try? PropertyListDecoder().decode(
            TakeoverJournal.self,
            from: data
        ),
        journal.sessionID != Self.zeroUUID,
        journal.requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecoveryStoreError.invalidTakeoverJournal
        }
        guard var identity, identity.sessionID == journal.sessionID else {
            try? persistence.clearTakeoverJournal()
            takeoverJournal = nil
            return
        }
        if var request = identity.finishRequest {
            request.terminalErrorCode = WorkoutTerminalErrorPolicy.resolve(
                summaryError: request.terminalErrorCode,
                persistedFinishError: .anotherWorkoutActive
            )
            identity.finishRequest = request
        } else {
            identity.finishRequest = FinishRequest(
                disposition: journal.disposition,
                requestedAt: journal.requestedAt,
                terminalErrorCode: .anotherWorkoutActive
            )
            if journal.explicitRiderChoice {
                identity.corruptResetPendingFinishChoice = false
            }
        }
        self.identity = identity
        takeoverJournal = journal
    }

    private func writeTakeoverJournal(
        sessionID: UUID,
        disposition: WorkoutFinishDisposition,
        requestedAt: Date,
        explicitRiderChoice: Bool
    ) throws {
        let journal = TakeoverJournal(
            sessionID: sessionID,
            disposition: disposition,
            requestedAt: requestedAt,
            explicitRiderChoice: explicitRiderChoice
        )
        let data = try PropertyListEncoder().encode(journal)
        try persistence.saveTakeoverJournal(data)
        takeoverJournal = journal
    }

    private func clearTakeoverJournalIfCovered(by identity: Identity) {
        guard let takeoverJournal,
              takeoverJournal.sessionID == identity.sessionID,
              identity.finishRequest?.terminalErrorCode
                == .anotherWorkoutActive else {
            return
        }
        clearTakeoverJournalBestEffort()
    }

    private func clearTakeoverJournalBestEffort() {
        guard takeoverJournal != nil else { return }
        do {
            try persistence.clearTakeoverJournal()
            takeoverJournal = nil
        } catch {
            // The write-ahead record is idempotent and scoped to one session.
            // Keeping it is safer than reporting failure after the primary
            // identity already became durable.
        }
    }

    private static func decodeState(from data: Data) -> PersistedState? {
        if let state = try? PropertyListDecoder().decode(PersistedState.self, from: data) {
            if let activeIdentity = state.activeIdentity,
               validatedIdentity(activeIdentity) == nil {
                return nil
            }
            guard state.terminalTombstones.allSatisfy(isValidTombstone) else {
                return nil
            }
            guard state.corruptResetAuthorization?.authorizedAt
                .timeIntervalSinceReferenceDate.isFinite ?? true else {
                return nil
            }
            return PersistedState(
                activeIdentity: state.activeIdentity.flatMap(validatedIdentity),
                terminalTombstones: state.terminalTombstones,
                corruptResetAuthorization: state.corruptResetAuthorization
            )
        }
        // Migrate the original v1 file, which encoded Identity at the root.
        guard let legacyIdentity = try? PropertyListDecoder().decode(
            Identity.self,
            from: data
        ),
              let validatedLegacyIdentity = validatedIdentity(legacyIdentity) else {
            return nil
        }
        return PersistedState(
            activeIdentity: validatedLegacyIdentity,
            terminalTombstones: [],
            corruptResetAuthorization: nil
        )
    }

    private static func validatedIdentity(_ identity: Identity) -> Identity? {
        guard identity.sessionID != zeroUUID,
              identity.healthKitSessionID.map({ $0 != zeroUUID }) ?? true,
              identity.sessionToken != 0,
              identity.transportGenerationID != zeroUUID,
              identity.startDate.timeIntervalSinceReferenceDate.isFinite,
              identity.remoteControlCheckpoint?.isValid ?? true,
              identity.remoteSegmentIntent?.isValid ?? true,
              identity.finishRequest?.requestedAt.timeIntervalSinceReferenceDate.isFinite
                ?? true else {
            return nil
        }
        if let intent = identity.remoteSegmentIntent {
            guard let checkpoint = identity.remoteControlCheckpoint else {
                return nil
            }
            if let senderID = intent.controlSenderID {
                guard checkpoint.seenSenderIDs.contains(senderID),
                      checkpoint.currentSenderID != senderID
                        || checkpoint.highestSequence
                            >= intent.acknowledgedSequence else {
                    return nil
                }
            } else {
                guard checkpoint.legacyHighestSequence
                        >= intent.acknowledgedSequence else {
                    return nil
                }
            }
        }
        if let acknowledgement = identity.remoteTerminalAcknowledgement {
            guard let checkpoint = identity.remoteControlCheckpoint,
                  acknowledgement.disposition
                    == identity.finishRequest?.disposition,
                  acknowledgement.capturedAt
                    .timeIntervalSinceReferenceDate.isFinite,
                  acknowledgement.envelopeSequence > 0,
                  acknowledgement.envelopeSequence
                    <= identity.sequenceHighWatermark,
                  acknowledgement.envelopeCapturedAt
                    .timeIntervalSinceReferenceDate.isFinite
            else {
                return nil
            }
            if let senderID = acknowledgement.controlSenderID {
                guard checkpoint.seenSenderIDs.contains(senderID),
                      checkpoint.currentSenderID != senderID
                        || checkpoint.highestSequence
                            >= acknowledgement.acknowledgedSequence else {
                    return nil
                }
            } else {
                guard checkpoint.legacyHighestSequence
                        >= acknowledgement.acknowledgedSequence else {
                    return nil
                }
            }
        }
        if identity.corruptResetSyntheticCleanupIdentity == true {
            guard identity.corruptResetPendingFinishChoice == true,
                  identity.finishRequest?.disposition == .discard else {
                return nil
            }
        }
        if identity.healthKitSessionID != nil {
            guard identity.corruptResetSyntheticCleanupIdentity == true,
                  identity.corruptResetPendingFinishChoice == true,
                  identity.finishRequest?.disposition == .discard else {
                return nil
            }
        }
        return identity
    }

    private static func isValidTombstone(_ tombstone: TerminalTombstone) -> Bool {
        tombstone.sessionID != zeroUUID
            && tombstone.startDate.timeIntervalSinceReferenceDate.isFinite
            && tombstone.savedAt.timeIntervalSinceReferenceDate.isFinite
    }

    private static func makeNonzeroToken() -> UInt16 {
        UInt16.random(in: 1...UInt16.max)
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private static func rank(_ phase: WorkoutFinalizationPhase) -> Int {
        switch phase {
        case .requested: 0
        case .collectionEnded: 1
        case .finishAttempted: 2
        case .workoutSaved: 3
        }
    }

    private static func makeDefaultPersistence() -> any WorkoutRecoveryPersistence {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return UnavailableWorkoutRecoveryPersistence()
        }
        return WorkoutRecoveryFilePersistence(
            fileURL: directory
                .appendingPathComponent("BikeComputer", isDirectory: true)
                .appendingPathComponent("active-watch-workout-v1.plist")
        )
    }
}

private nonisolated enum RecoveryStoreError: Error {
    case missingOrInvalidIdentity
    case unreadableOrOccupiedState
    case quarantineUnsupported
    case takeoverJournalUnsupported
    case invalidTakeoverJournal
    case stateChanged
}
