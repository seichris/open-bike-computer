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
private final class RideFixture: SocialRideNetworking {
    var seconds=0.0
    var sequences:[Int]=[]
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
         "sharing":serverSharing,"stats":false,"epoch":"consent-\(leaseEpoch)","serverTime":1000.0,"sharingExpiresAt":15400.0]
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
            leaseEpoch+=1;acceptedSequence = -1;serverSharing=location;result=room
        } else if path.hasSuffix("/state") {
            let payload=try JSONSerialization.jsonObject(with:body!) as! [String:Any]
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
    static func main() async throws {
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
}
