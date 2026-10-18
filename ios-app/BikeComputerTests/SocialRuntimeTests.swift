import Combine
import CoreLocation
import Foundation

private func require(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

@MainActor
private final class SocketFixture: SocialSocket {
    var first: URLSessionWebSocketTask.Message?
    let drop: Bool
    init(first: URLSessionWebSocketTask.Message? = nil, drop: Bool = false) { self.first=first;self.drop=drop }
    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if let first { self.first=nil;return first }
        if drop { throw URLError(.networkConnectionLost) }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        throw URLError(.timedOut)
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
        return SocketFixture(first:dropSocket ? .data(data) : nil,drop:dropSocket)
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
            service.reset()
        }

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
        for code in ["account_deleting","account_deleted"] {
            ProtocolFixture.state.reset(failing:true,responseCode:code)
            try await client.deleteAccount(body:["expectedProfileID":"owner"])
            require(ProtocolFixture.state.requests.count==2,"lost deletion response retries and completes local sign-out path")
        }
        auth.failure = .server("account_deleted")
        try await client.deleteAccount(body:["expectedProfileID":"owner"])
        auth.failure = nil
        ProtocolFixture.state.reset(failing:false,responseCode:"account_unavailable")
        do {
            try await client.deleteAccount(body:["expectedProfileID":"owner"])
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
        print("Social publisher, expiry, reconnect/revocation, HTTP retry, link and projected-edge regressions passed")
    }
}
