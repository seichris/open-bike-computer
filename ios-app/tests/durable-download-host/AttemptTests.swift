
@MainActor
private final class Observations {
    var progress: [Double] = []
    var bytes: [Int64] = []
    var completions = 0
    var backgroundCompletions = 0
}

// Compiled in the same file as the unchanged production coordinator so this
// harness can control real callback boundaries without shipping test hooks.
extension DurableMapDownloadCoordinator {
    @MainActor
    static func runAttemptRegressions() async throws {
        var assertions = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }
        func settle(_ condition: @MainActor () -> Bool) async {
            for _ in 0..<10_000 {
                if condition() { return }
                await Task.yield()
            }
            preconditionFailure("actor callback did not complete")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        let c = DurableMapDownloadCoordinator(configuration: configuration, directory: root)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let response = HTTPURLResponse(url: URL(string: "https://maps.example/map")!,
            statusCode: 200, httpVersion: nil, headerFields: nil)!
        let constraints = OfflineMapDownloadConstraints(exactBytes: 4, maximumBytes: 1024,
            allowedDownloadHosts: ["maps.example"], artifactSHA256: String(repeating: "a", count: 64))
        func prepare(_ task: ControlledDownloadTask, on coordinator: DurableMapDownloadCoordinator,
                     constraints: OfflineMapDownloadConstraints) throws -> Descriptor {
            let descriptor = Descriptor(constraints: constraints, attemptID: UUID())
            task.taskDescription = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)
            task.resultResponse = response
            try coordinator.persistOwnership(descriptor, phase: .active)
            return descriptor
        }
        func temporary(_ bytes: String) throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString)
            try Data(bytes.utf8).write(to: url)
            return url
        }
        func error(_ text: String) -> NSError {
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                userInfo: [NSURLSessionDownloadTaskResumeData: Data(text.utf8)])
        }

        // Cancel A, start B for the same artifact, then deliver every stale A
        // boundary. None may cancel B, publish bytes, resume B or update its UI.
        let a = ControlledDownloadTask(1)
        let da = try prepare(a, on: c, constraints: constraints)
        let key = da.key!
        let oa = Observations()
        let callA = Task { @MainActor in
            defer { oa.completions += 1 }
            return try await c.wait(for: a, descriptor: da,
                onProgress: { oa.progress.append($0) }, onByteProgress: { oa.bytes.append($0.completedBytes) })
        }
        await settle { c.waiters[key] != nil }
        let invocationA = c.waiters[key]!.invocationID
        callA.cancel()
        do { _ = try await callA.value; preconditionFailure("cancel A succeeded") }
        catch is CancellationError {} catch { preconditionFailure("wrong cancellation: \(error)") }
        expect(a.cancelled == 1, "A cancels exactly once")
        expect(oa.completions == 1, "A continuation completes once")

        let b = ControlledDownloadTask(2)
        let db = try prepare(b, on: c, constraints: constraints)
        let ob = Observations()
        let callB = Task { @MainActor in
            defer { ob.completions += 1 }
            return try await c.wait(for: b, descriptor: db,
                onProgress: { ob.progress.append($0) }, onByteProgress: { ob.bytes.append($0.completedBytes) })
        }
        await settle { c.waiters[key]?.task.taskIdentifier == 2 }
        c.cancel(key, invocationID: invocationA)
        expect(b.cancelled == 0, "late A cancellation must not cancel B")
        expect(c.waiters[key]?.task.taskIdentifier == 2, "B still owns the waiter")
        let canonical = try db.file("download", directory: root)
        let resume = try db.file("resume", directory: root)
        try Data("BBBB".utf8).write(to: canonical)
        try Data("resume-B".utf8).write(to: resume)
        c.urlSession(session, downloadTask: a, didFinishDownloadingTo: try temporary("AAAA"))
        c.urlSession(session, task: a, didCompleteWithError: error("error-A"))
        c.urlSession(session, downloadTask: a, didWriteData: 4, totalBytesWritten: 4, totalBytesExpectedToWrite: 4)
        expect(try! Data(contentsOf: canonical) == Data("BBBB".utf8), "stale A must not overwrite canonical B")
        expect(try! Data(contentsOf: resume) == Data("resume-B".utf8), "stale A error must not overwrite B resume data")
        expect(ob.progress.isEmpty && ob.bytes.isEmpty, "stale A progress must not update B")
        expect(ob.completions == 0, "stale A completion must not finish B")
        c.handleEvents { ob.backgroundCompletions += 1 }
        c.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        expect(ob.backgroundCompletions == 0, "background handoff waits for cancellation data")
        a.resumeCompletion?(Data("cancel-A".utf8))
        await settle { c.pendingCancellationCallbacks == 0 }
        expect(try! Data(contentsOf: resume) == Data("resume-B".utf8), "late cancel data must not overwrite B")
        expect(ob.backgroundCompletions == 1, "background handoff completes once after cancellation data")
        c.urlSession(session, downloadTask: b, didWriteData: 2, totalBytesWritten: 2, totalBytesExpectedToWrite: 4)
        expect(ob.progress == [0.5] && ob.bytes == [2], "B progress is still delivered")
        c.urlSession(session, downloadTask: b, didFinishDownloadingTo: try temporary("BBBB"))
        let bResult = try await callB.value
        expect(bResult == canonical && ob.completions == 1, "B finishes exactly once")
        expect(try c.ownership(db)?.phase == .finished, "completion ownership is persisted")
        c.urlSession(session, downloadTask: b, didFinishDownloadingTo: try temporary("XXXX"))
        c.urlSession(session, task: b, didCompleteWithError: error("late-B"))
        expect(try! Data(contentsOf: canonical) == Data("BBBB".utf8), "duplicate terminal callback cannot replace bytes")
        expect(try! Data(contentsOf: resume) == Data("resume-B".utf8), "terminal errors cannot create new resume state")
        expect(ob.completions == 1, "terminal callback does not double-resume")

        // A valid restored background completion must publish without any waiter.
        let restoredConstraints = OfflineMapDownloadConstraints(exactBytes: 4, maximumBytes: 1024,
            allowedDownloadHosts: ["maps.example"], artifactSHA256: String(repeating: "b", count: 64))
        let restoredTask = ControlledDownloadTask(3)
        let restoredDescriptor = try prepare(restoredTask, on: c, constraints: restoredConstraints)
        let relaunched = DurableMapDownloadCoordinator(configuration: configuration, directory: root)
        expect(relaunched.waiters.isEmpty, "relaunch has no in-memory waiter")
        relaunched.urlSession(session, downloadTask: restoredTask, didFinishDownloadingTo: try temporary("CCCC"))
        let restoredFile = try restoredDescriptor.file("download", directory: root)
        expect(try! Data(contentsOf: restoredFile) == Data("CCCC".utf8), "orphan completion retained across process state")
        expect(try relaunched.ownership(restoredDescriptor)?.phase == .finished, "restored completion is terminal")
        let later = DurableMapDownloadCoordinator(configuration: configuration, directory: root)
        let reused = try await later.download(from: URL(string: "https://maps.example/fresh-grant")!,
            constraints: restoredConstraints, onProgress: { _ in }, onByteProgress: { _ in })
        expect(reused == restoredFile, "later invocation reuses restored completed bytes without networking")
        relaunched.urlSession(session, task: a, didCompleteWithError: error("old-process-A"))
        expect(try! Data(contentsOf: resume) == Data("resume-B".utf8), "persistent ownership rejects old process callbacks")

        // Cancellation before registration exercises the inline check plus the
        // queued cancellation handler; the continuation/task still finish once.
        let early = ControlledDownloadTask(4)
        let de = try prepare(early, on: c, constraints: constraints)
        let oe = Observations()
        let earlyCall = Task { @MainActor in
            defer { oe.completions += 1 }
            return try await c.wait(for: early, descriptor: de, onProgress: { _ in }, onByteProgress: { _ in })
        }
        earlyCall.cancel()
        do { _ = try await earlyCall.value; preconditionFailure("early cancel succeeded") }
        catch is CancellationError {} catch { preconditionFailure("wrong early error") }
        await settle { early.resumeCompletion != nil }
        expect(early.cancelled == 1 && oe.completions == 1, "pre-registration cancellation is exactly once")
        c.urlSession(session, task: early, didCompleteWithError: error("delegate-resume"))
        early.resumeCompletion?(Data("cancel-resume".utf8))
        await settle { c.pendingCancellationCallbacks == 0 }
        expect(try! Data(contentsOf: resume) == Data("cancel-resume".utf8), "current cancellation retains resume data")
        expect(try c.ownership(de)?.phase == .failed, "cancel completion retires attempt")
        expect(c.resumeData(for: Descriptor(constraints: constraints)) == Data("cancel-resume".utf8),
            "matching artifact and transport policy may reuse cancelled resume data")
        let changedPolicy = OfflineMapDownloadConstraints(exactBytes: 4, maximumBytes: 1024,
            allowedDownloadHosts: ["replacement.example"], artifactSHA256: constraints.artifactSHA256)
        expect(c.resumeData(for: Descriptor(constraints: changedPolicy)) == nil,
            "changed host policy must not reuse an opaque request for an older host")
        c.urlSession(session, task: early, didCompleteWithError: error("duplicate-cancel"))
        expect(try! Data(contentsOf: resume) == Data("cancel-resume".utf8), "retired cancellation cannot rewrite resume data")

        // Missing/corrupt durable authority must fail the matching caller, not
        // publish bytes, hang its continuation, or silently reset ownership.
        let corrupt = ControlledDownloadTask(5)
        let dc = try prepare(corrupt, on: c, constraints: constraints)
        let corruptCall = Task { @MainActor in
            try await c.wait(for: corrupt, descriptor: dc, onProgress: { _ in }, onByteProgress: { _ in })
        }
        await settle { c.waiters[key]?.task.taskIdentifier == 5 }
        try Data("corrupt".utf8).write(to: dc.file("owner", directory: root))
        c.urlSession(session, downloadTask: corrupt, didFinishDownloadingTo: try temporary("XXXX"))
        do { _ = try await corruptCall.value; preconditionFailure("corrupt ownership admitted") }
        catch is OfflineMapCatalogError {} catch { preconditionFailure("wrong authority failure") }
        expect(try! Data(contentsOf: canonical) == Data("BBBB".utf8), "corrupt authority cannot overwrite cached artifact")
        expect(c.waiters[key] == nil, "corrupt authority does not leave a hung caller")
        print("Durable download attempt regressions passed: \(assertions) assertions")
    }
}

@main struct AttemptRegressionRunner {
    @MainActor static func main() async throws {
        try await DurableMapDownloadCoordinator.runAttemptRegressions()
    }
}
