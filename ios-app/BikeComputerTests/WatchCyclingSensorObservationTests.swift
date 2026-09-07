import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
private enum WatchCyclingSensorObservationTests {
    @MainActor
    static func main() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let id = UUID()
        func observation(
            id: UUID = id, start: Date = now.addingTimeInterval(-60),
            at: Date = now, active: Bool = true,
            cadence: Date? = now, power: Date? = nil
        ) -> WatchCyclingSensorObservationV1 {
            WatchCyclingSensorObservationV1(
                sessionID: id, sessionStartedAt: start, capturedAt: at,
                isWorkoutActive: active,
                cadenceObservedAt: active ? cadence : nil,
                powerObservedAt: active ? power : nil
            )
        }
        let live = observation()
        let decoded = try WatchCyclingSensorObservationV1.decode(live.encoded())
        check(
            decoded == live,
            "binary property-list round trip")
        let context = try live.merging(into: [
            "metadata": Data([1]), "health": "ready",
        ])
        check(
            context["metadata"] as? Data == Data([1]), "metadata survives merge"
        )
        check(
            context["health"] as? String == "ready",
            "health state survives merge")
        let wire =
            try PropertyListSerialization.propertyList(
                from: live.encoded(), options: [], format: nil
            ) as! [String: Any]
        check(
            Set(wire.keys)
                == Set([
                    "version", "sessionID", "sessionStartedAt", "capturedAt",
                    "isWorkoutActive", "cadenceObservedAt",
                ]),
            "wire carries only lifecycle and timestamps, no numeric metrics")
        for bad in [
            Data(), Data("invalid".utf8), Data(repeating: 0, count: 2_049),
        ] {
            check(
                (try? WatchCyclingSensorObservationV1.decode(bad)) == nil,
                "malformed and oversized input fails closed")
        }
        var futureWire = wire
        futureWire["version"] = 2
        let futureData = try PropertyListSerialization.data(
            fromPropertyList: futureWire, format: .binary, options: 0
        )
        check(
            (try? WatchCyclingSensorObservationV1.decode(futureData)) == nil,
            "unsupported version is not accepted")
        check(
            !observation(cadence: now.addingTimeInterval(1)).isValid,
            "a sample cannot be newer than its snapshot")
        check(
            !observation(cadence: now.addingTimeInterval(-61)).isValid,
            "a sample cannot predate its session")
        check(
            !observation(at: Date(timeIntervalSinceReferenceDate: .nan))
                .isValid,
            "nonfinite capture time rejected")
        let end = observation(at: now.addingTimeInterval(2), active: false)
        check(end.isValid, "terminal snapshot strips sensor evidence")

        var reducer = CyclingSensorObservationReducer()
        check(
            reducer.ingest(live, from: .watch, at: now), "Watch-only admission")
        check(
            reducer.hasActiveWorkout(at: now),
            "idle mirror does not gate Watch activity")
        check(
            reducer.cadenceObservedAt(at: now) == now,
            "original sample timestamp")
        check(
            reducer.ingest(live, from: .mirror, at: now),
            "parallel mirror admission")
        reducer.setUnavailable(.mirror)
        check(
            reducer.cadenceObservedAt(at: now) == now,
            "mirror loss keeps Watch evidence")
        check(
            reducer.ingest(end, from: .watch, at: end.capturedAt),
            "end accepted")
        check(
            !reducer.hasActiveWorkout(at: end.capturedAt),
            "end clears reporting immediately")
        check(
            reducer.cadenceObservedAt(at: end.capturedAt) == nil,
            "end clears cadence")
        check(
            !reducer.ingest(live, from: .mirror, at: end.capturedAt),
            "late mirror cannot revive end")
        check(
            !reducer.ingest(
                observation(at: end.capturedAt), from: .watch,
                at: end.capturedAt),
            "even a higher timestamp cannot reopen the same ended session")

        let nextID = UUID()
        let next = observation(
            id: nextID, start: now.addingTimeInterval(3),
            at: now.addingTimeInterval(4), cadence: now.addingTimeInterval(4))
        check(
            reducer.ingest(next, from: .watch, at: next.capturedAt),
            "successor session accepted")
        check(
            !reducer.ingest(end, from: .mirror, at: next.capturedAt),
            "old end rejected")
        check(
            reducer.sessionID == nextID
                && reducer.hasActiveWorkout(at: next.capturedAt),
            "rejecting old end is atomic")
        let invalidSuccessor = observation(
            id: UUID(), start: now.addingTimeInterval(3.5),
            at: now.addingTimeInterval(3.9), active: false)
        check(
            !reducer.ingest(
                invalidSuccessor, from: .watch, at: next.capturedAt),
            "older capture rejected before replacing session")
        check(
            reducer.sessionID == nextID
                && reducer.cadenceObservedAt(at: next.capturedAt) != nil,
            "rejected packet leaves existing evidence unchanged")

        var expired = CyclingSensorObservationReducer()
        check(
            !expired.ingest(
                live, from: .watch, at: now.addingTimeInterval(5.001)),
            "stale cached context cannot discover or report on launch")
        check(
            !expired.hasActiveWorkout(at: now.addingTimeInterval(5.001)),
            "no stale activity")
        check(
            !expired.ingest(
                live, from: .watch, at: now.addingTimeInterval(-0.001)),
            "future capture rejected")
        let oldSample = observation(cadence: now.addingTimeInterval(-6))
        check(
            expired.ingest(oldSample, from: .watch, at: now),
            "fresh lifecycle still accepted")
        check(
            expired.cadenceObservedAt(at: now) == nil,
            "fresh context does not rejuvenate old sample")
        var grace = CyclingSensorObservationReducer()
        check(
            grace.ingest(live, from: .watch, at: now.addingTimeInterval(5)),
            "inclusive discovery boundary")
        check(
            grace.cadenceObservedAt(at: now.addingTimeInterval(10)) == now,
            "inclusive reporting boundary")
        check(
            grace.cadenceObservedAt(at: now.addingTimeInterval(10.001)) == nil,
            "silent source expires")
        check(
            grace.nextExpiry(after: now) == now.addingTimeInterval(10.001),
            "expiry deadline uses sample time")
        check(
            !grace.ingest(live, from: .watch, at: now.addingTimeInterval(6)),
            "cache replay is stale")
        check(
            grace.cadenceObservedAt(at: now.addingTimeInterval(9)) == now,
            "replay does not re-date accepted sample")
        grace.setUnavailable(.watch)
        check(
            !grace.hasActiveWorkout(at: now),
            "unpair/removal clears only available evidence")

        var idle = CyclingSensorObservationReducer()
        let tombstone = WatchCyclingSensorObservationV1.inactive(at: now)
        check(
            !idle.ingest(tombstone, from: .mirror, at: now),
            "idle phone cannot end Watch workout")
        check(
            idle.ingest(tombstone, from: .watch, at: now),
            "confirmed Watch idle tombstone")
        check(
            !idle.ingest(live, from: .mirror, at: now),
            "idle barrier rejects prior context")
        check(
            idle.ingest(next, from: .watch, at: next.capturedAt),
            "new workout after idle accepted")

        var publication = WatchCyclingSensorPublicationV1()
        publication.offer(live)
        check(
            publication.publicationDelay(at: now) == 0, "first sensor immediate"
        )
        check(
            publication.publicationDelay(at: now.addingTimeInterval(1)) == 0,
            "failed submission remains pending")
        publication.didPublish(at: now)
        check(
            publication.publicationDelay(at: now) == nil,
            "successful identical context is not resent")
        let refresh = observation(
            at: now.addingTimeInterval(1), cadence: now.addingTimeInterval(1))
        publication.offer(refresh)
        check(
            publication.publicationDelay(at: refresh.capturedAt) == 1,
            "refresh coalesced to two seconds")
        let newest = observation(
            at: now.addingTimeInterval(1.5),
            cadence: now.addingTimeInterval(1.5))
        publication.offer(newest)
        publication.offer(live)
        check(
            publication.latest == newest,
            "one-slot queue keeps newest and rejects late offer")
        check(
            publication.publicationDelay(at: now.addingTimeInterval(2)) == 0,
            "trailing refresh eventually due")
        publication.offer(end)
        check(
            publication.publicationDelay(at: end.capturedAt) == 0,
            "terminal state bypasses refresh throttle")
        publication.offer(
            observation(
                at: now.addingTimeInterval(3),
                cadence: now.addingTimeInterval(3)
            ))
        check(
            publication.latest == end,
            "late active callback cannot overwrite an undelivered tombstone")
        publication.didPublish(at: end.capturedAt)
        publication.offer(next)
        check(
            publication.publicationDelay(at: next.capturedAt) == 0,
            "successor session immediate")
        // Exercise the actual publisher adapter, including pre-activation,
        // coalescing, failed submission, bounded retry, and trailing delivery.
        var activated = false
        var clock = now
        var attempts = 0
        var fails = false
        var sent: [WatchCyclingSensorObservationV1] = []
        let publisher = WatchCyclingSensorObservationPublisher(
            isActivated: { activated },
            publish: { observation in
                attempts += 1
                if fails { return false }
                sent.append(observation)
                return true
            },
            now: { clock }
        )
        publisher.offer(live)
        publisher.offer(refresh)
        check(attempts == 0, "no writes before session activation")
        activated = true
        clock = refresh.capturedAt
        publisher.flush()
        check(
            sent == [refresh],
            "activation flushes only latest pending observation")
        publisher.flush()
        check(
            attempts == 1,
            "activation/metadata replay does not resend unchanged state")
        clock = newest.capturedAt
        publisher.offer(newest)
        check(attempts == 1, "actual publisher throttles timestamp refresh")
        clock = now.addingTimeInterval(3)
        fails = true
        publisher.flush()
        check(attempts == 2, "due refresh attempts submission")
        publisher.offer(end)
        publisher.flush()
        check(
            attempts == 2, "new envelopes cannot defeat a failed-write deadline"
        )
        clock = now.addingTimeInterval(5)
        publisher.flush()
        check(attempts == 3, "failed publication retries at deadline")
        fails = false
        clock = now.addingTimeInterval(9)
        publisher.flush()
        check(
            sent == [refresh, end],
            "retry retains terminal rather than older numeric evidence")

        var trailing: [WatchCyclingSensorObservationV1] = []
        let liveClock = Date()
        let livePublisher = WatchCyclingSensorObservationPublisher(
            isActivated: { true },
            publish: {
                trailing.append($0)
                return true
            }
        )
        livePublisher.offer(
            observation(
                start: liveClock.addingTimeInterval(-60),
                at: liveClock, cadence: liveClock))
        try await Task.sleep(nanoseconds: 50_000_000)
        let lastSample = Date()
        livePublisher.offer(
            observation(
                start: liveClock.addingTimeInterval(-60),
                at: lastSample, cadence: lastSample))
        let deadline = Date().addingTimeInterval(3)
        while trailing.count < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        check(
            trailing.count == 2
                && trailing.last?.cadenceObservedAt == lastSample,
            "trailing timer flushes the last sample without another offer")
        print("Watch cycling sensor observation tests passed")
    }
}
