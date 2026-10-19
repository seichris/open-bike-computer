import CryptoKit
import Foundation

/// One rider as the bike computer needs it: canonical WGS-84 position, age,
/// initials and an optional 40×40 RGB565 portrait. No IDs leave the phone.
nonisolated struct SocialRelayRider: Equatable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let ageSeconds: Double
    let accuracy: Double
    let course: Double?
    let initials: String
    let pixels: Data?
}

@MainActor
protocol SocialRelayLink: AnyObject {
    var isReady: Bool { get }
    func write(_ packet: Data) -> Bool
}

/// GRUP v1 sender with stable slots. Unchanged riders keep their slot and the
/// portrait already committed on the device. Only riders who left are cleared
/// and only a replaced slot is reused; a rider whose position expired stays
/// parked (the device hides it) so a return needs no portrait upload. A new
/// device session is started only by `begin`, for real session changes.
@MainActor
final class SocialRiderRelayEngine {
    static let capacity = 8
    static let expirySeconds: TimeInterval = 60
    static let portraitBytes = 40 * 40 * 2

    /// Weak: the BLE relay owns this engine and is its link.
    private weak var link: (any SocialRelayLink)?
    private let uptime: () -> TimeInterval
    private let pause: @MainActor (UInt64) async -> Void
    private(set) var epoch: UInt32 = 0
    private(set) var slots: [String?] = Array(repeating: nil, count: capacity)
    /// Portrait hash committed on the device for each slot.
    private var committed: [Int: Data] = [:]
    /// Uptime at which the device stops showing each slot's last position.
    private var expires: [Int: TimeInterval] = [:]
    private var sequence: UInt32 = 0
    private var acknowledgement: Data?
    private var lastAcknowledgement: Data?
    /// The device rejected this session (for example after a firmware reset).
    private(set) var needsSessionRestart = false

    init(link: any SocialRelayLink, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping @MainActor (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }) {
        self.link = link; self.uptime = uptime; self.pause = pause
    }

    func receive(_ acknowledgement: Data) {
        if acknowledgement.count == 17 { self.acknowledgement = acknowledgement }
    }

    /// Starts a device session. Slot knowledge from an older session is void.
    func begin(epoch: UInt32) async -> Bool {
        self.epoch = epoch
        slots = Array(repeating: nil, count: Self.capacity)
        committed = [:]; expires = [:]; sequence = 0; needsSessionRestart = false
        return await send(packet(0), slot: 255, opcode: 0) == 0
    }

    /// Removes every rider: hardware sharing disabled, room left or signed out.
    func clearAll() async {
        for slot in slots.indices where slots[slot] != nil {
            guard await clear(slot) else { return }
        }
    }

    func update(riders: [SocialRelayRider], own: (latitude: Double, longitude: Double)?) async {
        let session = epoch
        let now = uptime()
        let fresh = riders.filter { $0.ageSeconds < Self.expirySeconds }
        let desired = Array(fresh.sorted { Self.closer($0, $1, own) }.prefix(Self.capacity))
        let wanted = Set(desired.map(\.id))
        let live = Set(fresh.map(\.id))
        // A rider who left, stopped sharing or became unavailable before their
        // position expired disappears immediately. Expired riders stay parked.
        for slot in slots.indices {
            guard let id = slots[slot], !wanted.contains(id), !live.contains(id),
                  now < (expires[slot] ?? 0) else { continue }
            guard await clear(slot), epoch == session else { return }
        }
        for rider in desired where !slots.contains(rider.id) {
            guard let slot = vacancy(wanted: wanted, live: live) else { break }
            if slots[slot] != nil {
                // Replacing a parked or displaced rider: clear before reuse.
                guard await clear(slot), epoch == session else { return }
            }
            slots[slot] = rider.id
        }
        for rider in desired {
            guard epoch == session, !needsSessionRestart else { return }
            guard let slot = slots.firstIndex(of: rider.id) else { continue }
            await publish(rider, slot: slot, now: now)
        }
    }

    private func vacancy(wanted: Set<String>, live: Set<String>) -> Int? {
        if let empty = slots.firstIndex(where: { $0 == nil }) { return empty }
        let reusable = slots.indices.filter { slots[$0].map { !wanted.contains($0) } ?? false }
        // Prefer the longest-expired parked rider, then a live rider no longer among the nearest.
        let parked = reusable.filter { !live.contains(slots[$0] ?? "") }
        if let slot = parked.min(by: { (expires[$0] ?? 0) < (expires[$1] ?? 0) }) { return slot }
        return reusable.first
    }

    private func clear(_ slot: Int) async -> Bool {
        switch await send(packet(2, slot: slot), slot: slot, opcode: 2) {
        case 0:
            slots[slot] = nil
            committed[slot] = nil
            expires[slot] = nil
            return true
        case 1:
            needsSessionRestart = true  // A clear is only refused for an unknown session.
            return false
        default:
            return false
        }
    }

    private func publish(_ rider: SocialRelayRider, slot: Int, now: TimeInterval) async {
        let pixels = rider.pixels.flatMap { $0.count == Self.portraitBytes ? $0 : nil }
        let hash = pixels.map { Data(SHA256.hash(data: $0)) } ?? Data(repeating: 0, count: 32)
        sequence &+= 1
        var state = packet(1, slot: slot)
        state.le(sequence)
        // Firmware maps and GPS use canonical WGS-84. Only phone MapKit uses GCJ-02.
        state.le(UInt32(bitPattern: Int32((rider.latitude*1e6).rounded())))
        state.le(UInt32(bitPattern: Int32((rider.longitude*1e6).rounded())))
        state.le(UInt16(min(59, max(0, rider.ageSeconds.rounded(.up)))))
        state.le(UInt16(min(100, max(0, rider.accuracy.rounded(.up)))))
        state.le(UInt16(rider.course.map { Int($0.rounded()) % 360 } ?? 65535))
        let initials = Array(rider.initials.utf8.filter { $0 >= 32 && $0 <= 126 }.prefix(4))
        state.append(contentsOf: initials)
        state.append(contentsOf: repeatElement(UInt8(0), count: 4-initials.count))
        state.append(hash)
        switch await send(state, slot: slot, opcode: 1) {
        case 0: break
        case 1:
            // Sequences only grow within a session, so a stale result means the
            // device no longer has this session.
            needsSessionRestart = true
            return
        default: return
        }
        expires[slot] = now + max(0, Self.expirySeconds-rider.ageSeconds)
        guard let pixels, committed[slot] != hash else { return }
        var begin = packet(3, slot: slot)
        begin.append(hash)
        guard await send(begin, slot: slot, opcode: 3) == 0, let ack = lastAcknowledgement else { return }
        let resume = Int(ack[9]) + Int(ack[10]) * 256
        guard resume <= pixels.count else { return }
        for offset in stride(from: resume, to: pixels.count, by: 112) {
            var chunk = packet(4, slot: slot)
            chunk.le(UInt16(offset))
            let end = min(offset+112, pixels.count)
            chunk.append(pixels.subdata(in: offset..<end))
            guard await send(chunk, slot: slot, opcode: 4, offset: end) == 0 else { return }
        }
        if await send(packet(5, slot: slot), slot: slot, opcode: 5) == 0 { committed[slot] = hash }
    }

    private func packet(_ opcode: UInt8, slot: Int? = nil) -> Data {
        var data = Data("GRUP".utf8)
        data.append(contentsOf: [1, opcode])
        data.le(epoch)
        if let slot { data.append(UInt8(truncatingIfNeeded: slot)) }
        return data
    }

    /// One outstanding operation with up to three attempts and a two-second ACK
    /// window each. Returns the device result code, or nil without an answer.
    private func send(_ data: Data, slot: Int, opcode: UInt8, offset: Int? = nil) async -> UInt8? {
        let session = epoch
        for _ in 0..<3 {
            guard !Task.isCancelled, epoch == session, let link, link.isReady else { return nil }
            acknowledgement = nil
            guard link.write(data) else { return nil }
            for _ in 0..<40 {
                if acknowledgement == nil { await pause(50_000_000) }
                guard !Task.isCancelled, epoch == session else { return nil }
                guard let ack = acknowledgement else { continue }
                acknowledgement = nil  // Consume it; a late or unrelated ACK must not end the wait early.
                guard ack.uint32(at: 4) == session, ack[8] == UInt8(truncatingIfNeeded: slot),
                      ack[12] == opcode else { continue }
                if ack[11] != 0 { lastAcknowledgement = ack; return ack[11] }
                // Success must also match the current state sequence and transfer offset.
                if opcode != 0 && opcode != 2 && ack.uint32(at: 13) != sequence { continue }
                if let offset, Int(ack[9]) + Int(ack[10]) * 256 != offset { continue }
                lastAcknowledgement = ack
                return 0
            }
        }
        return nil
    }

    private static func closer(_ a: SocialRelayRider, _ b: SocialRelayRider,
                               _ own: (latitude: Double, longitude: Double)?) -> Bool {
        guard let own else { return a.id < b.id }
        let first = distance(own, (a.latitude, a.longitude)), second = distance(own, (b.latitude, b.longitude))
        return first == second ? a.id < b.id : first < second
    }

    private static func distance(_ a: (latitude: Double, longitude: Double), _ b: (Double, Double)) -> Double {
        let p = a.latitude * .pi/180, q = b.0 * .pi/180
        let dp = q-p, dl = (b.1-a.longitude) * .pi/180
        let h = sin(dp/2)*sin(dp/2) + cos(p)*cos(q)*sin(dl/2)*sin(dl/2)
        return 2 * 6_371_008.8 * asin(min(1, sqrt(max(0, h))))
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    func uint32(at index: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[index+$1]) << ($1*8) } }
}
