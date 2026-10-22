import Combine
import CoreLocation
import Foundation

private func require(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

@MainActor
private final class SocketFixture: SocialSocket {
    /// Messages the test pushes into this live socket.
    var queue: [URLSessionWebSocketTask.Message]
    let drop: Bool
    private(set) var delivered = 0
    init(first: URLSessionWebSocketTask.Message? = nil, drop: Bool = false) { queue=first.map { [$0] } ?? [];self.drop=drop }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
    func receive() async throws -> URLSessionWebSocketTask.Message {
        while queue.isEmpty {
            if drop { throw URLError(.networkConnectionLost) }
            try await Task.sleep(nanoseconds: 5_000_000)  // Ends when the live service resets.
        }
        delivered+=1
        return queue.removeFirst()
    }
}

@MainActor
private final class ProfileEditFixture {
    var generation = UUID()
    var version = 1
    var seenVersions: [Int] = []
    var name = "Chris"
    var notifications = true
    var held: CheckedContinuation<Void, Never>?
    var retiredEditRan = false
}

@MainActor
private final class RideFixture: SocialRideNetworking {
    var seconds=0.0
    var sequences:[Int]=[]
    var lastState:[String:Any]=[:]
    var serverStats=false
    var lostFirst=false,terminal=false,dropSocket=false,revoked=false
    var reads=0
    var leaseEpoch=0,acceptedSequence = -1
    var serverSharing=false
    var holdStart=false,holdStop=false
    var held:CheckedContinuation<Void,Never>?
    var stateFailures=0,socketDrops=0
    private(set) var sockets:[SocketFixture]=[]
    var snapshot:URLSessionWebSocketTask.Message { .data(try! JSONSerialization.data(withJSONObject:room)) }
    var room:[String:Any] {
        ["id":"ride-1","owner":"owner","title":"Test","status":"active","expiresAt":100000.0,
         "route":[:],"members":[],"riders":dropSocket ? [["profile":["id":"friend","displayName":"Friend"],
            "latitude":1.0,"longitude":2.0,"capturedAt":1000.0,"receivedAt":1000.0,
            "horizontalAccuracy":5.0,"sequence":1,"age":0.0]] : [],
         "sharing":serverSharing,"stats":serverStats,"epoch":"consent-\(leaseEpoch)","serverTime":1000.0,"sharingExpiresAt":15400.0]
    }
    func selected() throws -> SocialGroupRide {
        try JSONDecoder().decode(SocialGroupRide.self,from:JSONSerialization.data(withJSONObject:room))
    }
    /// A live snapshot as some server replica read it, possibly before a consent change.
    func snapshot(epoch:Int,sharing:Bool,serverTime:Double) -> URLSessionWebSocketTask.Message {
        var value=room;value["epoch"]="consent-\(epoch)";value["sharing"]=sharing;value["serverTime"]=serverTime
        return .data(try! JSONSerialization.data(withJSONObject:value))
    }
    func request(_ path:String,method:String,body:Data?,contentType:String,query:[URLQueryItem]) async throws -> Data {
        var result:[String:Any]=room
        if path.hasSuffix("/consent") && method=="POST" {
            let payload=try JSONSerialization.jsonObject(with:body!) as! [String:Any]
            let location=payload["location"] as! Bool
            if (location && holdStart) || (!location && holdStop) {
                holdStart=false;holdStop=false
                await withCheckedContinuation { held=$0 }
            }
            guard payload["epoch"] as? String == "consent-\(leaseEpoch)" else { throw SocialFailure.server("consent_changed") }
            leaseEpoch+=1;acceptedSequence = -1;serverSharing=location;serverStats=payload["stats"] as? Bool ?? false;result=room
        } else if path.hasSuffix("/state") {
            let payload=try JSONSerialization.jsonObject(with:body!) as! [String:Any]
            lastState=payload
            sequences.append(payload["sequence"] as! Int)
            if terminal || !serverSharing || payload["epoch"] as? String != "consent-\(leaseEpoch)" { throw SocialFailure.server("sharing_disabled") }
            guard sequences.last! > acceptedSequence else { throw SocialFailure.server("stale_state") }
            if stateFailures>0 { stateFailures-=1;throw SocialFailure.server("service_unavailable") }
            acceptedSequence=sequences.last!
            if lostFirst && sequences.count==1 { throw URLError(.timedOut) }
            result=["accepted":sequences.last!]
        } else if path.hasSuffix("/messages") { result=["items":[]] }
        else if method=="GET" {
            reads+=1
            if revoked && reads>1 { throw SocialFailure.server("membership_required") }
        }
        return try JSONSerialization.data(withJSONObject:result)
    }
    func socket(rideID:String) async throws -> any SocialSocket {
        let data=try JSONSerialization.data(withJSONObject:room)
        let socket:SocketFixture
        if socketDrops>0 { socketDrops-=1;socket=SocketFixture(drop:true) }
        else { socket=SocketFixture(first:dropSocket ? .data(data) : nil,drop:dropSocket) }
        sockets.append(socket)
        return socket
    }
}

@MainActor
private final class AuthFixture: SocialAuthenticating {
    var generation=UUID()
    var refreshes:[Bool]=[]
    var failure: SocialFailure?
    func token(forceRefresh:Bool) async throws -> String {
        if let failure { throw failure }
        refreshes.append(forceRefresh);return forceRefresh ? "fresh" : "original"
    }
}

private final class HTTPFixture: @unchecked Sendable {
    let lock=NSLock()
    var requests:[URLRequest]=[]
    var failFirst=false
    var responseCode:String?
    func reset(failing:Bool, responseCode:String? = nil) { lock.lock();defer{lock.unlock()};requests=[];failFirst=failing;self.responseCode=responseCode }
    func respond(_ request:URLRequest) throws -> (Int,Data) {
        lock.lock();defer{lock.unlock()};requests.append(request)
        if failFirst && requests.count==1 { throw URLError(.timedOut) }
        if let responseCode { return (403,try JSONSerialization.data(withJSONObject:["code":responseCode])) }
        return (requests.count==1 ? 401 : 200,Data("{\"ok\":true}".utf8))
    }
}
private final class ProtocolFixture: URLProtocol, @unchecked Sendable {
    static let state=HTTPFixture()
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status:Int,data:Data
        do { (status,data)=try Self.state.respond(request) }
        catch { client?.urlProtocol(self,didFailWithError:error);return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
@MainActor
struct SocialRuntimeTests {
    static func wait(_ condition: () -> Bool) async throws {
        let deadline=Date().addingTimeInterval(3)
        while !condition() && Date()<deadline { try await Task.sleep(nanoseconds:5_000_000) }
        require(condition(),"asynchronous social condition reached its deadline")
    }
    static func automaticJoinSharing() async throws {
        let network = RideFixture()
        let live = LiveRideService(client: network, pollNanoseconds: 10_000_000)
        live.prepareLocation = { true }
        live.updateLocation(CLLocation(coordinate: .init(latitude: 1, longitude: 2), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 4, timestamp: Date()))
        try await live.select(network.selected(), shareOnJoin: true)
        require(live.isSharing && network.serverStats, "explicit joining enables GPS and ride stats")
        try await wait { !network.lastState.isEmpty }
        require(network.lastState["speed"] != nil && network.lastState["distanceMeters"] != nil &&
                network.lastState["movingSeconds"] != nil && network.lastState["elapsedSeconds"] != nil,
                "default publication includes speed, distance, moving and elapsed time")
        try await live.select(network.selected())
        require(!live.isSharing, "opening a room alone never restarts stopped sharing")
        live.prepareLocation = { false }
        try await live.select(network.selected(), shareOnJoin: true)
        require(live.ride != nil && !live.isSharing && live.error?.contains("joined") == true,
                "denied location keeps successful membership and explains the sharing failure")
        live.prepareLocation = { true }
        live.locationAuthorizationChanged(authorized: true)
        try await wait { live.isSharing }
        await live.stopSharing()
        live.locationAuthorizationChanged(authorized: true)
        require(!live.isSharing, "a later permission event never overrides explicit Stop sharing")
        live.reset()
        let store = SocialRideInvitationStore(store: SocialMemoryStore())
        let invitation = SocialRideInvitation(code: "same-capability-secret-123456789", previewID: "00000000-0000-4000-8000-000000000001")
        store.write(invitation, owner: "owner", ride: "ride")
        require(store.read(owner: "owner", ride: "ride") == invitation, "reopening restores the same invitation")
        require(store.read(owner: "another-owner", ride: "ride") == nil, "invites never cross accounts")
        let capability = try JSONDecoder().decode(SocialCapabilities.self, from: Data("{\"media\":true}".utf8))
        require(capability.media && !capability.invitePreviews, "old servers safely omit preview capability")
        require(!capability.savedMapKitRoutes, "old servers keep Apple Maps sharing disabled until the backend supports it")
        let current = try JSONDecoder().decode(SocialCapabilities.self, from: Data("{\"routes\":true,\"savedMapKitRoutes\":true}".utf8))
        require(current.savedMapKitRoutes, "updated servers advertise saved Apple Maps route support")
        require(SocialLinkTarget(url: URL(string: "https://bicino.com/social/ride/00000000-0000-4000-8000-000000000001#capability-secret-123456789")!)?.kind == "ride", "preview links preserve native joining")
    }

    /// The phone stream has no Core Location distance filter, so a stop now
    /// delivers 1 Hz jittered fixes. They must not become shared ride stats.
    static func sharedRideProgressIgnoresStationaryJitter() {
        let base = Date()
        func fix(_ northMeters: Double, _ second: Int, speed: CLLocationSpeed) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 1.3 + northMeters / 111_000, longitude: 103.8),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: speed,
                timestamp: base.addingTimeInterval(Double(second)))
        }
        var progress = SharedRideProgress()
        let jitter = [0.0, 2.5, -1.5, 3.0, -2.0, 4.0, -3.5]
        for second in 0..<600 {
            // Stationary fixes report zero or unavailable Doppler speed.
            progress.add(fix(jitter[second % jitter.count], second, speed: second.isMultiple(of: 2) ? 0 : -1))
        }
        require(progress.distanceMeters == 0 && progress.movingSeconds == 0,
                "a ten-minute stop adds no shared distance or moving time")
        for step in 1...60 {
            progress.add(fix(Double(step) * 6, 599 + step, speed: 6))
        }
        require(abs(progress.distanceMeters - fix(360, 0, speed: 0).distance(from: fix(0, 0, speed: 0))) < 1 &&
                abs(progress.movingSeconds - 60) < 0.001, "riding after a stop counts distance and only riding time")
        let ridden = progress.distanceMeters
        for step in 1...30 {
            progress.add(fix(360 + Double(step) * 2, 659 + step, speed: -1))
        }
        require(progress.distanceMeters - ridden > 60 - SharedRideProgress.minimumDisplacementMeters &&
                progress.movingSeconds > 60, "slow riding without Doppler speed still accumulates")
        let beforeGap = progress.distanceMeters
        progress.add(fix(1_000, 760, speed: 6))
        require(progress.distanceMeters == beforeGap, "a silent interval is never credited as ride distance")
    }

    static func main() async throws {
        profileSetupPresentation()
        sharedRideProgressIgnoresStationaryJitter()
        try await automaticJoinSharing()
        try await SocialSavedRouteSharingTests.run()
        try await profileMutationSerialization()
        let fixture=RideFixture();fixture.lostFirst=true
        let live=LiveRideService(client:fixture,uptime:{fixture.seconds},pollNanoseconds:10_000_000)
        live.prepareLocation={true}
        try await live.select(fixture.selected())
        live.updateLocation(CLLocation(coordinate:.init(latitude:1,longitude:2),altitude:0,horizontalAccuracy:5,verticalAccuracy:5,timestamp:Date()))
        try await live.startSharing(stats:false)
        try await wait { fixture.sequences.count>=2 }
        require(Array(fixture.sequences.prefix(2))==[0,1],"a lost accepted response never reuses its sequence")
        require(live.isSharing,"network loss does not revoke local sharing")
        fixture.seconds=14401
        try await wait { !live.isSharing }
        require(live.error?.contains("ended")==true,"bounded sharing expiry is explained")
        live.reset()

        let denied=RideFixture();denied.terminal=true
        let deniedLive=LiveRideService(client:denied,pollNanoseconds:10_000_000)
        deniedLive.prepareLocation={true};try await deniedLive.select(denied.selected())
        deniedLive.updateLocation(CLLocation(coordinate:.init(latitude:1,longitude:2),altitude:0,horizontalAccuracy:5,verticalAccuracy:5,timestamp:Date()))
        try await deniedLive.startSharing(stats:false)
        try await wait { !deniedLive.isSharing }
        require(denied.sequences.count==1,"terminal sharing rejection stops further publication")
        deniedLive.reset()

        for revoke in [false,true] {
            let network=RideFixture();network.dropSocket=true;network.revoked=revoke
            let service=LiveRideService(client:network)
            try await service.select(network.selected())
            try await wait { network.reads>=2 }
            if revoke {
                try await wait { service.ride==nil }
                require(service.riders.isEmpty,"confirmed membership revocation clears riders")
            } else {
                require(service.riders.count==1,"socket rotation retains fresh positions and portraits")
            }
            service.reset()
        }

        for delayedStart in [true,false] {
            let network=RideFixture()
            let service=LiveRideService(client:network)
            service.prepareLocation={true};try await service.select(network.selected())
            if !delayedStart { try await service.startSharing(stats:false) }
            network.holdStart=delayedStart;network.holdStop = !delayedStart
            let old=Task { () throws -> Void in
                if delayedStart { try await service.startSharing(stats:false) }
                else { await service.stopSharing() }
            }
            try await wait { network.held != nil }
            if delayedStart { await service.stopSharing() }
            else { try await service.startSharing(stats:false) }
            network.held?.resume();network.held=nil
            do { try await old.value } catch SocialFailure.cancelled { }
            require(service.isSharing == !delayedStart && network.serverSharing == !delayedStart,
                    "a delayed consent request cannot overtake the latest start/stop choice")
            // Snapshots read before any of those accepted changes cannot undo the latest choice,
            // even when another replica's clock stamps them later.
            try await wait { !network.sockets.isEmpty }
            let socket=network.sockets.last!
            for retired in 0..<network.leaseEpoch {
                socket.queue.append(network.snapshot(epoch:retired,sharing:delayedStart,serverTime:9_999_999))
            }
            try await wait { socket.delivered>=network.leaseEpoch }
            require(service.isSharing == !delayedStart && service.ride?.epoch == "consent-\(network.leaseEpoch)",
                    "reordered start/stop leaves only the latest consent generation in effect")
            service.reset()
        }

        // Consent generation, not server time, orders live snapshots against this phone's choices.
        let ordered=RideFixture()
        let orderedLive=LiveRideService(client:ordered,pollNanoseconds:10_000_000)
        orderedLive.prepareLocation={true}
        try await orderedLive.select(ordered.selected())
        try await wait { !ordered.sockets.isEmpty }
        let stream=ordered.sockets.last!
        try await orderedLive.startSharing(stats:false)
        require(orderedLive.isSharing && ordered.leaseEpoch==1,"sharing was accepted")
        // Read before the accepted consent, but stamped later by a replica with a fast clock.
        stream.queue.append(ordered.snapshot(epoch:0,sharing:false,serverTime:9_999_999))
        try await wait { stream.delivered>=1 }
        require(orderedLive.isSharing && ordered.serverSharing,"a stale sharing:false snapshot cannot cancel accepted sharing")
        // A current-generation snapshot from a replica with a slow clock still applies.
        stream.queue.append(ordered.snapshot(epoch:1,sharing:true,serverTime:1))
        try await wait { stream.delivered>=2 }
        require(orderedLive.isSharing && orderedLive.ride?.serverTime==1,"current consent snapshots apply regardless of server clock")
        // The server ending this same consent (expiry keeps the epoch) is honored.
        ordered.serverSharing=false
        stream.queue.append(ordered.snapshot(epoch:1,sharing:false,serverTime:1))
        try await wait { !orderedLive.isSharing }
        require(orderedLive.ride?.sharing==false,"a matching current revocation stops local sharing")
        orderedLive.reset()

        // A viewer's reconnect notice clears on the next healthy snapshot.
        let viewer=RideFixture();viewer.socketDrops=1
        let watching=LiveRideService(client:viewer,pollNanoseconds:10_000_000,reconnectNanoseconds:10_000_000)
        var notices:[LiveRideService.Notice?]=[]
        let noticeObserver=watching.$error.sink { _ in notices.append(watching.notice) }
        try await watching.select(viewer.selected())
        try await wait { viewer.sockets.count>=2 }
        viewer.sockets.last!.queue.append(viewer.snapshot)
        try await wait { notices.contains(.reconnecting) && watching.error==nil }
        require(!watching.isSharing && watching.notice==nil,"a healthy snapshot clears a viewer's reconnect notice")
        noticeObserver.cancel()
        watching.reset()

        // Publishing and sharing-ended notices persist until resolved, but never into the next ride.
        let rider=RideFixture();rider.stateFailures=1_000
        let sharing=LiveRideService(client:rider,pollNanoseconds:10_000_000,reconnectNanoseconds:10_000_000)
        sharing.prepareLocation={true}
        try await sharing.select(rider.selected())
        sharing.updateLocation(CLLocation(coordinate:.init(latitude:1,longitude:2),altitude:0,horizontalAccuracy:5,verticalAccuracy:5,timestamp:Date()))
        try await sharing.startSharing(stats:false)
        try await wait { sharing.notice == .publishFailed && !rider.sockets.isEmpty }
        rider.sockets.last!.queue.append(rider.snapshot)
        try await wait { rider.sockets.last!.delivered>=1 }
        require(sharing.notice == .publishFailed,"a healthy snapshot does not hide a publishing failure")
        rider.stateFailures=0
        try await wait { sharing.notice==nil }
        rider.terminal=true
        // The publisher sends only newer fixes; a fresh fix reaches the terminal response.
        sharing.updateLocation(CLLocation(coordinate:.init(latitude:1,longitude:2.001),altitude:0,horizontalAccuracy:5,verticalAccuracy:5,timestamp:Date().addingTimeInterval(1)))
        try await wait { sharing.notice == .sharingEnded }
        rider.sockets.last!.queue.append(rider.snapshot)
        try await wait { rider.sockets.last!.delivered>=2 }
        require(sharing.notice == .sharingEnded && !sharing.isSharing,"sharing-ended persists until the rider acts")
        try await sharing.select(rider.selected())
        require(sharing.notice==nil && sharing.error==nil,"notices never carry into the next ride")
        sharing.reset()

        let auth=AuthFixture();let config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[ProtocolFixture.self]
        let urlSession=URLSession(configuration:config)
        let client=BicinoSocialClient(session:auth,baseURL:URL(string:"https://social.example.test/v1/social"),urlSession:urlSession)
        _ = try await client.json("group-rides/preview",method:"POST",body:["code":"secret-is-in-the-body"])
        require(auth.refreshes==[false,true],"401 causes one forced token refresh")
        let requests=ProtocolFixture.state.requests
        require(requests.count==2 && requests[0].value(forHTTPHeaderField:"Idempotency-Key")==requests[1].value(forHTTPHeaderField:"Idempotency-Key"),"authentication retries preserve their operation key")
        require(requests[0].url!.path=="/v1/social/group-rides/preview","capability code is absent from request URL")
        require(requests[1].value(forHTTPHeaderField:"Authorization")=="Bearer fresh","retry uses the refreshed token")
        ProtocolFixture.state.reset(failing:true)
        _ = try await client.json("group-rides",method:"POST",body:["routeID":"owned-route"])
        let retried=ProtocolFixture.state.requests
        require(retried.count==2 && retried[0].value(forHTTPHeaderField:"Idempotency-Key")==retried[1].value(forHTTPHeaderField:"Idempotency-Key"),"lost mutation responses retry the same operation instead of creating another room")
        ProtocolFixture.state.reset(failing:true)
        do {
            _ = try await client.json("group-rides/ride-1/state",method:"POST",body:["sequence":1])
            preconditionFailure("state transport failure must reach its publisher")
        } catch is URLError { }
        require(ProtocolFixture.state.requests.count==1,"state retransmission belongs to the monotonic publisher")
        // A lost deletion response retries with its operation key; the account's own
        // authenticated answer that deletion is under way completes it.
        let orchestrator=SocialAccountDeletion(store:SocialTestStore(),client:client,anonymous:client)
        for code in ["account_deleting","account_deleted"] {
            ProtocolFixture.state.reset(failing:true,responseCode:code)
            let completed=try await orchestrator.delete(profileID:"owner",accountUID:"uid-owner",reauthenticate:{ nil })
            require(completed.profileID=="owner" && orchestrator.pending==nil,"accepted deletion completes after a lost response")
            require(ProtocolFixture.state.requests.count==2,"the transport retry reuses the deletion operation")
        }
        // A provider identity that disappeared is not proof: only the receipt can confirm it.
        auth.failure = .identityMissing
        ProtocolFixture.state.reset(failing:false)
        do {
            _ = try await orchestrator.delete(profileID:"owner",accountUID:"uid-owner",reauthenticate:{ nil })
            preconditionFailure("a missing identity must not be treated as completed deletion")
        } catch SocialFailure.identityMissing { }
        let resolve=ProtocolFixture.state.requests.last!
        require(resolve.url!.path=="/v1/social/deletion-receipts/resolve" && resolve.value(forHTTPHeaderField:"Authorization")==nil,
                "receipt confirmation is anonymous and keeps its secret out of the URL")
        require(orchestrator.pending != nil,"an unconfirmed receipt is retained for recovery")
        auth.failure = nil
        ProtocolFixture.state.reset(failing:false,responseCode:"account_unavailable")
        do {
            _ = try await orchestrator.delete(profileID:"owner",accountUID:"uid-owner",reauthenticate:{ nil })
            preconditionFailure("unconfirmed deletion must not be treated as complete")
        } catch SocialFailure.server("account_unavailable") { }
        urlSession.invalidateAndCancel()

        let secret="capability-secret-1234567890"
        for scheme in ["https://bicino.com/social","bikecomputer://social","bikecomputer-dev://social"] {
            require(SocialLinkTarget(url:URL(string:scheme+"/ride#"+secret)!)?.id==secret,"native and web fragments route identically")
            require(SocialLinkTarget(url:URL(string:scheme+"/ride/"+secret)!)==nil,"secrets in request paths are rejected")
        }
        let bounds=CGRect(x:0,y:0,width:466,height:466)
        for angle in stride(from:0.0,to:360.0,by:45) {
            let dx=sin(angle * .pi/180),dy = -cos(angle * .pi/180)
            let projected=CGPoint(x:233+1000*dx,y:233+1000*dy)
            let edge=SocialMapGeometry.edgeCenter(projected:projected,bounds:bounds)!
            require((edge.x-233)*dx>=0 && (edge.y-233)*dy>=0,"edge follows the projected point after panning or rotation")
        }
        require(abs(SocialMapGeometry.edgeCenter(projected:CGPoint(x:-100,y:100),bounds:bounds)!.x-42)<0.00001,"a panned rider stays on the projected side of the map")
        try await SocialMaintenanceTests.run()
        print("Social publisher, expiry, reconnect/revocation, notices, HTTP retry, deletion, link and projected-edge regressions passed")
    }

    private static func profileMutationSerialization() async throws {
        let queue = SocialProfileMutationQueue()
        let fixture = ProfileEditFixture()
        let generation = fixture.generation
        let name = Task { @MainActor in
            try await queue.perform(generation: generation, currentGeneration: { fixture.generation }) {
                fixture.seenVersions.append(fixture.version)
                await withCheckedContinuation { fixture.held = $0 }
                fixture.name = "New name"
                fixture.version += 1
            }
        }
        try await wait { fixture.held != nil }
        let privacy = Task { @MainActor in
            try await queue.perform(generation: generation, currentGeneration: { fixture.generation }) {
                fixture.seenVersions.append(fixture.version)
                fixture.notifications = false
                fixture.version += 1
            }
        }
        await Task.yield()
        require(fixture.seenVersions == [1], "a preference edit waits for the preceding profile field response")
        fixture.held?.resume(); fixture.held = nil
        try await name.value
        try await privacy.value
        require(fixture.seenVersions == [1, 2] && fixture.name == "New name" && !fixture.notifications,
            "successive autosaves use the latest version and preserve each other's settings")

        do {
            try await queue.perform(generation: generation, currentGeneration: { fixture.generation }) {
                throw SocialFailure.unavailable
            }
            preconditionFailure("a failed save must be reported")
        } catch SocialFailure.unavailable { }
        try await queue.perform(generation: generation, currentGeneration: { fixture.generation }) {
            fixture.version += 1
        }
        require(fixture.version == 4, "a failed save does not block later changes")

        let held = Task { @MainActor in
            try await queue.perform(generation: generation, currentGeneration: { fixture.generation }) {
                await withCheckedContinuation { fixture.held = $0 }
            }
        }
        try await wait { fixture.held != nil }
        let retired = Task { @MainActor in
            try await queue.perform(generation: generation, currentGeneration: { fixture.generation }) {
                fixture.retiredEditRan = true
            }
        }
        await Task.yield()
        fixture.generation = UUID()
        fixture.held?.resume(); fixture.held = nil
        do { try await held.value; preconditionFailure("an old account's response must be rejected") }
        catch SocialFailure.accountChanged { }
        do { try await retired.value; preconditionFailure("a queued edit must not cross an account change") }
        catch SocialFailure.accountChanged { }
        require(!fixture.retiredEditRan, "an old account's pending settings never run against a new account")
    }

    private static func profileSetupPresentation() {
        require(SocialUsername.normalized("  @Chris_1 \n") == "chris_1",
            "rider lookup accepts a pasted handle with an at-sign, case and whitespace")
        require(SocialUsername.normalized("Chris_1") == "chris_1",
            "rider lookup also accepts a username without an at-sign")
        require(SocialUsername.normalized("@@chris") == "@chris",
            "lookup does not silently repair malformed handles")
        let suite = "SocialProfileSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = SocialProfileSetupHistory(defaults: defaults)
        let empty = SocialProfile(id: "first", username: nil, displayName: "Rider",
            avatarID: nil, version: 1, privacy: nil)
        require(history.shouldOffer(for: empty), "a new profile is offered setup")
        history.recordOffer(for: empty)
        let relaunched = SocialProfileSetupHistory(defaults: UserDefaults(suiteName: suite)!)
        require(!relaunched.shouldOffer(for: empty), "skipping setup survives a relaunch and later sign-in")
        require(empty.needsProfileSetup, "skipping keeps the completion reminder available")
        let other = SocialProfile(id: "second", username: nil, displayName: "Rider",
            avatarID: nil, version: 1, privacy: nil)
        require(relaunched.shouldOffer(for: other), "one account's skip does not suppress another account's setup")
        let complete = SocialProfile(id: "complete", username: "chris", displayName: "Chris",
            avatarID: nil, version: 2, privacy: nil)
        require(!history.shouldOffer(for: complete), "a completed profile without an optional photo needs no prompt")
        var draft = SocialProfileDraft(profile: empty)
        require(draft.name.isEmpty && !draft.isValid, "new users choose their public name rather than accepting a placeholder")
        draft.name = "  Chris  "
        draft.username = "  CHRIS_1  "
        require(draft.isValid && draft.normalizedName == "Chris" && draft.normalizedUsername == "chris_1",
            "saved names are trimmed and usernames normalized")
        for username in ["ab", "1rider", "has space", String(repeating: "a", count: 31)] {
            draft.username = username
            require(!draft.isValid, "invalid usernames cannot be submitted")
        }
        draft.username = "chris"
        draft.name = "   "
        require(!draft.isValid, "a blank public name cannot be submitted")

    }
}
