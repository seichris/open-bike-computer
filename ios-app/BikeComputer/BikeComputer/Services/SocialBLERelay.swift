import Combine
import CoreLocation
import CryptoKit
import Foundation
import UIKit

/// Eight bounded slots, one acknowledged image transfer, and no remote URLs on BLE.
@MainActor
final class SocialBLERelay {
    private weak var ble: BLEManager?
    private weak var social: SocialCoordinator?
    private var task: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    private var acknowledgement: Data?
    private var epoch: UInt32 = 0
    private var slots: [String] = []
    private var loaded: [Int: Data] = [:]
    private var sequence: UInt32 = 0
    private var binding = ""

    init(ble: BLEManager, social: SocialCoordinator) {
        self.ble = ble; self.social = social
        ble.onSocialAcknowledgement = { [weak self] in self?.acknowledgement = $0 }
        social.session.$generation.sink { [weak self] _ in self?.restart() }.store(in: &observers)
        social.live.$ride.map { $0?.id }.removeDuplicates().sink { [weak self] _ in self?.restart() }.store(in: &observers)
        social.$capabilities.removeDuplicates().sink { [weak self] _ in self?.restart() }.store(in: &observers)
        ble.$supportsGroupRiders.combineLatest(ble.$isNavigationReady).sink { [weak self] _ in self?.restart() }.store(in: &observers)
        restart()
    }

    private func restart() {
        task?.cancel(); task = nil; epoch = UInt32.random(in: 1...UInt32.max)
        slots = []; loaded = [:]; sequence = 0
        let expected = epoch
        task = Task { [weak self] in
            guard let self, let ble = self.ble, ble.supportsGroupRiders, ble.isNavigationReady else { return }
            while !(await self.send(self.packet(0), slot: 255, opcode: 0, expected: expected)) {
                guard !Task.isCancelled, self.epoch == expected else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            while !Task.isCancelled && self.epoch == expected {
                await self.update(expected: expected)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func packet(_ opcode: UInt8, slot: Int? = nil) -> Data {
        var data = Data("GRUP".utf8); data.append(contentsOf: [1, opcode]); data.le(epoch)
        if let slot { data.append(UInt8(slot)) }; return data
    }

    private func send(_ data: Data, slot: Int, opcode: UInt8, offset: Int? = nil, expected: UInt32) async -> Bool {
        for _ in 0..<3 {
            guard !Task.isCancelled, epoch == expected, let ble, ble.isNavigationReady, ble.supportsGroupRiders else { return false }
            acknowledgement = nil
            guard ble.sendSocialPacket(data) else { return false }
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, epoch == expected else { return false }
                if let ack = acknowledgement, ack.count == 17,
                   ack.uint32(at: 4) == expected, ack[8] == UInt8(slot), ack[12] == opcode,
                   (opcode == 0 || opcode == 2 || ack.uint32(at: 13) == sequence),
                   offset == nil || Int(ack[9]) + Int(ack[10])*256 == offset {
                    return ack[11] == 0
                }
            }
        }
        return false
    }

    private func update(expected: UInt32) async {
        guard let social, social.capabilities.hardware, social.live.ride != nil, social.session.state == .signedIn else {
            if !slots.isEmpty { for slot in slots.indices { guard await send(packet(2, slot: slot), slot: slot, opcode: 2, expected: expected) else { return } }; slots=[];loaded=[:] }
            return
        }
        let riders = social.live.riders.filter { $0.id != social.profile?.id && $0.age(at: Date()) < 60 }
            .sorted {
                guard let own = social.live.latestLocation else { return $0.id < $1.id }
                return own.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) < own.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
            }.prefix(8).sorted { $0.id < $1.id }
        let next = riders.map(\.id)
        if next != slots {
            for slot in slots.indices { guard await send(packet(2,slot: slot),slot: slot,opcode: 2,expected: expected) else { return } }
            guard epoch == expected else { return }; slots=next;loaded=[:]
        }
        for (slot,rider) in riders.enumerated() {
            guard !Task.isCancelled,epoch==expected else {return}
            let pixels = rider.profile.avatarID.flatMap { social.photos[$0] }.flatMap(Self.rgb565)
            let hash = pixels.map { Data(SHA256.hash(data: $0)) } ?? Data(repeating: 0,count: 32)
            sequence &+= 1
            var state=packet(1,slot: slot);state.le(sequence)
            // Firmware maps and GPS use canonical WGS-84. Only phone MapKit uses GCJ-02.
            let coordinate=rider.coordinate
            state.le(UInt32(bitPattern:Int32((coordinate.latitude*1e6).rounded())))
            state.le(UInt32(bitPattern:Int32((coordinate.longitude*1e6).rounded())))
            state.le(UInt16(min(59,rider.age(at:Date()).rounded(.up))))
            state.le(UInt16(min(100,max(0,rider.horizontalAccuracy.rounded(.up)))))
            state.le(UInt16(rider.course.map { Int($0.rounded()) % 360 } ?? 65535))
            let initials=Array(rider.profile.initials.utf8.filter { $0>=32 && $0<=126 }.prefix(4))
            state.append(contentsOf: initials);state.append(contentsOf: repeatElement(UInt8(0),count:4-initials.count));state.append(hash)
            guard await send(state,slot:slot,opcode:1,expected:expected) else {continue}
            if let pixels, loaded[slot] != hash {
                var begin=packet(3,slot:slot);begin.append(hash)
                guard await send(begin,slot:slot,opcode:3,expected:expected) else {continue}
                guard let ack = acknowledgement, ack.count == 17 else { continue }
                let resumeOffset = Int(ack[9]) + Int(ack[10]) * 256
                guard resumeOffset <= pixels.count else { continue }
                var succeeded=true
                for offset in stride(from:resumeOffset,to:pixels.count,by:112) {
                    var chunk=packet(4,slot:slot);chunk.le(UInt16(offset));let end=min(offset+112,pixels.count)
                    chunk.append(pixels.subdata(in:offset..<end))
                    if !(await send(chunk,slot:slot,opcode:4,offset:end,expected:expected)) {succeeded=false;break}
                }
                if succeeded,await send(packet(5,slot:slot),slot:slot,opcode:5,expected:expected) {loaded[slot]=hash}
            }
        }
    }

    private static func rgb565(_ image: UIImage) -> Data? {
        guard let cg=image.cgImage else{return nil}
        var rgba=[UInt8](repeating:0,count:40*40*4)
        let ok=rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context=CGContext(data:bytes.baseAddress,width:40,height:40,bitsPerComponent:8,bytesPerRow:160,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            context.draw(cg,in:CGRect(x:0,y:0,width:40,height:40));return true
        }
        guard ok else{return nil};var result=Data(capacity:3200)
        for p in stride(from:0,to:rgba.count,by:4) {
            result.le(UInt16(rgba[p]>>3)<<11 | UInt16(rgba[p+1]>>2)<<5 | UInt16(rgba[p+2]>>3))
        };return result
    }
}
private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value:T) { var v=value.littleEndian;Swift.withUnsafeBytes(of:&v){append(contentsOf:$0)} }
    func uint32(at:Int)->UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[at+$1]) << ($1*8) } }
}
