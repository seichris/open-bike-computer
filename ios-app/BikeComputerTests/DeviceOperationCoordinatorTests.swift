import Foundation

@main
struct DeviceOperationCoordinatorTests {
    @MainActor static func main() async throws {
        let name = "DeviceOperationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let owner = DeviceOperationCoordinator(defaults: defaults)
        var removals: [String] = []
        owner.removeConfiguration = { removals.append($0) }
        let first = try owner.acquire(deviceID: "board-A", mode: "map", epoch: 1)
        try owner.configure("BikeComputer-Transfer", for: first)
        let upload = owner.retain(operationID: first.id)!
        owner.release(upload)
        precondition(removals.isEmpty, "upload completion must not disconnect confirmation")
        do {
            _ = try owner.acquire(deviceID: "board-B", mode: "firmware", epoch: 1)
            fatalError("cross-board same-SSID contention admitted")
        } catch DeviceOperationCoordinator.Failure.busy { }
        let pending = try owner.beginApply(first)
        owner.finish(first, remoteClear: true)
        precondition(owner.lease == first && removals.isEmpty, "pending apply owns the generation")
        owner.finishApply(pending, for: first)
        precondition(removals == ["BikeComputer-Transfer"])
        let next = try owner.acquire(deviceID: "board-B", mode: "debug", epoch: 2)
        try owner.configure("BikeComputer-Transfer", for: next)
        owner.release(upload)
        owner.finishApply(pending, for: first)
        owner.finish(first, remoteClear: true)
        precondition(owner.lease == next && removals.count == 1, "late old release removed new owner")
        let browser = owner.retain(operationID: next.id)!
        owner.finish(next, remoteClear: false)
        precondition(removals.count == 1)
        owner.release(browser)
        precondition(removals.count == 2)
        let relaunched = DeviceOperationCoordinator(defaults: defaults)
        do {
            _ = try relaunched.acquire(deviceID: "board-B", mode: "diagnostics", epoch: 3)
            fatalError("unresolved cleanup admitted after relaunch")
        } catch DeviceOperationCoordinator.Failure.cleanupUnresolved { }
        relaunched.reconcileClear(deviceID: "board-A")
        precondition(relaunched.unresolved != nil, "different device cleared cleanup")
        relaunched.reconcileClear(deviceID: "board-B")
        let recovered = try relaunched.acquire(deviceID: "board-B", mode: "diagnostics", epoch: 3)
        relaunched.finish(recovered, remoteClear: true)
        precondition(DeviceOperationCoordinator(defaults: defaults).unresolved == nil)
        let background = try relaunched.acquire(deviceID: "board-B", mode: "map", epoch: 4)
        try relaunched.configure("BikeComputer-Transfer", for: background)
        relaunched.recordAuthorization(background, digest: "one-way-token-digest", generation: 77)
        let restored = DeviceOperationCoordinator(defaults: defaults)
        var restoredRemovals = 0
        restored.removeConfiguration = { _ in restoredRemovals += 1 }
        precondition(restored.restoreClaim(operationID: UUID(), deviceID: "board-B", network: "BikeComputer-Transfer") == nil)
        precondition(restored.restoreClaim(operationID: background.id, deviceID: "board-A", network: "BikeComputer-Transfer") == nil)
        precondition(restored.restoreClaim(operationID: background.id, deviceID: "board-B", network: "wrong") == nil)
        let restoredClaim = restored.restoreClaim(operationID: background.id, deviceID: "board-B", network: "BikeComputer-Transfer")!
        let duplicateClaim = restored.restoreClaim(operationID: background.id, deviceID: "board-B", network: "BikeComputer-Transfer")!
        restored.release(duplicateClaim)
        precondition(restoredRemovals == 0)
        restored.release(restoredClaim)
        precondition(restored.lease == nil && restoredRemovals == 1, "dead foreground root stranded restored task")
        precondition(restored.unresolved != nil && restored.tokenDigest == "one-way-token-digest")
        precondition(restored.transferGeneration == 77)
        let reconciled = try restored.adoptUnresolved(epoch: 5)
        precondition(reconciled.id == background.id && reconciled.connectionEpoch == 5)
        restored.finish(reconciled, remoteClear: true)
        precondition(DeviceOperationCoordinator(defaults: defaults).unresolved == nil)

        let held = try restored.acquire(deviceID: "board-B", mode: "map", epoch: 6)
        let heldUpload = restored.retain(operationID: held.id)!
        do {
            _ = try restored.resumeMapRoot(deviceID: "board-B", epoch: 7, currentOwner: nil)
            fatalError("another live manager stole a map root")
        } catch DeviceOperationCoordinator.Failure.busy { }
        let resumed = try restored.resumeMapRoot(deviceID: "board-B", epoch: 7, currentOwner: held)
        precondition(resumed.id == held.id && resumed.connectionEpoch == 7)
        restored.release(heldUpload)
        precondition(restored.lease == resumed, "resume lost confirmation root when upload released")
        restored.finish(resumed, remoteClear: true)

        let precommit = try restored.acquire(deviceID: "board-B", mode: "map", epoch: 8)
        precondition(!restored.isCleanupComplete)
        let runningUpload = restored.retain(operationID: precommit.id)!
        do {
            try restored.retireStoppedMapForPrecommitRecovery(deviceID: "board-B", currentOwner: precommit)
            fatalError("precommit recovery displaced an OS upload claim")
        } catch DeviceOperationCoordinator.Failure.busy { }
        restored.release(runningUpload)
        let applying = try restored.beginApply(precommit)
        do {
            try restored.retireStoppedMapForPrecommitRecovery(deviceID: "board-B", currentOwner: precommit)
            fatalError("precommit recovery displaced a pending apply")
        } catch DeviceOperationCoordinator.Failure.staleOwner { }
        restored.finishApply(applying, for: precommit)
        do {
            try restored.retireStoppedMapForPrecommitRecovery(deviceID: "board-B", currentOwner: nil)
            fatalError("precommit recovery stole a live root")
        } catch DeviceOperationCoordinator.Failure.busy { }
        try restored.retireStoppedMapForPrecommitRecovery(deviceID: "board-B", currentOwner: precommit)
        precondition(restored.isCleanupComplete)
        let freshTransport = try restored.acquire(deviceID: "board-B", mode: "map", epoch: 8)
        precondition(freshTransport.id != precommit.id, "recovery needs a fresh transport lease")
        restored.finish(freshTransport, remoteClear: false)
        precondition(!restored.isCleanupComplete, "nil live lease must not hide unresolved cleanup")
        restored.reconcileClear(deviceID: "board-B")
        precondition(restored.isCleanupComplete)

        let cancelledParent = Task { @MainActor in
            precondition(Task.isCancelled, "barrier: parent must already be cancelled")
            let cleanup = DeviceOperationCleanupTask.start { !Task.isCancelled }
            return await cleanup.value
        }
        // MainActor has not yielded: cancellation is established before the
        // parent enters the production cleanup-task factory, without sleeps.
        cancelledParent.cancel()
        let independentCleanup = await cancelledParent.value
        precondition(independentCleanup, "cancelled acquisition cancelled cleanup")
        try await verifyInterruptedRecovery()
        defaults.set(Data("corrupt cleanup".utf8), forKey: "device-operation-cleanup-v1")
        let corrupt = DeviceOperationCoordinator(defaults: defaults)
        do {
            _ = try corrupt.acquire(deviceID: "board-B", mode: "map", epoch: 6)
            fatalError("corrupt persisted ownership failed open")
        } catch DeviceOperationCoordinator.Failure.cleanupUnresolved { }
        print("Device operation lease tests passed")
    }

    @MainActor static func verifyInterruptedRecovery() async throws {
        let name = "DeviceRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let owner = DeviceOperationCoordinator(defaults: defaults)
        func interrupted() throws -> DeviceOperationCoordinator.Lease {
            let lease = try owner.acquire(deviceID: "board-A", mode: "debug", epoch: 1)
            owner.recordAuthorization(lease, digest: "expected-digest", generation: 7)
            owner.finish(lease, remoteClear: false)
            return lease
        }
        var ticks = 0, requests = 0
        var revision: UInt64 = 10, epoch: UInt64 = 2
        var mode = "", digest: String? = nil
        var generation: UInt32 = 0
        let status = {
            DeviceOperationCoordinator.RecoveryStatus(
                deviceID: "board-A", connectionEpoch: epoch, ready: true,
                revision: revision, mode: mode, tokenDigest: digest,
                transferGeneration: generation)
        }
        let request = { requests += 1; return true }

        _ = try interrupted()
        let cleared = try await owner.recover(deviceID: "board-A", connectionEpoch: 2,
            status: status, requestStatus: request, pause: {
                ticks += 1
                // Three seconds of lost/incomplete notifications exceed the
                // former two-second admission window. A retry completes them.
                if ticks == 12 { revision += 1 }
            })
        precondition(cleared == nil && owner.isCleanupComplete && requests >= 3,
                     "a delayed fresh empty status must recover interrupted cleanup")

        _ = try interrupted()
        ticks = 0
        do {
            _ = try await owner.recover(deviceID: "board-A", connectionEpoch: 2,
                status: status, requestStatus: request, pause: { ticks += 1 })
            fatalError("cached empty status retired persisted ownership")
        } catch DeviceOperationCoordinator.Failure.cleanupUnresolved { }
        precondition(ticks == 64 && owner.unresolved != nil && owner.lease == nil)

        let retained = owner.unresolved!
        mode = "debug"; digest = "wrong-digest"; generation = 7; revision += 1
        ticks = 0
        let adopted = try await owner.recover(deviceID: "board-A", connectionEpoch: 2,
            status: status, requestStatus: request, pause: {
                ticks += 1; revision += 1
                if ticks == 2 { digest = "expected-digest"; generation = 8 }
                if ticks == 3 { generation = 7 }
            })
        precondition(ticks == 3 && adopted?.id == retained.id && adopted?.connectionEpoch == 2,
                     "adoption needs both the recorded token digest and generation")
        owner.finish(adopted!, remoteClear: true)

        _ = try interrupted()
        do {
            _ = try await owner.recover(deviceID: "board-A", connectionEpoch: 2,
                status: status, requestStatus: request, pause: {
                    epoch = 3; revision += 1; mode = ""; digest = nil
                })
            fatalError("a successor connection cleared predecessor cleanup")
        } catch DeviceOperationCoordinator.Failure.staleOwner { }
        precondition(owner.unresolved != nil && owner.lease == nil)

        let previousRequests = requests
        do {
            _ = try await owner.recover(deviceID: "board-B", connectionEpoch: 3,
                status: status, requestStatus: request, pause: {})
            fatalError("another device recovered the recorded owner")
        } catch DeviceOperationCoordinator.Failure.cleanupUnresolved { }
        precondition(requests == previousRequests, "wrong-device recovery must not send commands")

        do {
            _ = try await owner.recover(deviceID: "board-A", connectionEpoch: 3,
                status: status, requestStatus: request, pause: { throw CancellationError() })
            fatalError("cancelled recovery completed")
        } catch is CancellationError { }
        precondition(owner.unresolved != nil && owner.lease == nil)
        owner.reconcileClear(deviceID: "board-A")
    }
}
