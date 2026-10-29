import Combine
import CoreLocation
import Foundation
import UIKit

/// Connects live Group Ride riders to the bike computer over authenticated BLE.
/// Eight bounded slots, one acknowledged image transfer, and no remote URLs on BLE.
@MainActor
final class SocialBLERelay: SocialRelayLink {
    private weak var ble: BLEManager?
    private weak var social: SocialCoordinator?
    private var task: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()
    /// RGB565 conversions keyed by avatar asset, so portraits are not re-rendered every tick.
    private var portraits: [String: Data] = [:]
    private lazy var engine = SocialRiderRelayEngine(link: self)

    var isReady: Bool { (ble?.isNavigationReady ?? false) && (ble?.supportsGroupRiders ?? false) }
    func write(_ packet: Data) -> Bool { ble?.sendSocialPacket(packet) ?? false }

    init(ble: BLEManager, social: SocialCoordinator) {
        self.ble = ble; self.social = social
        ble.onSocialAcknowledgement = { [weak self] in self?.engine.receive($0) }
        // A new device session is needed only when the account, room, hardware
        // capability or BLE session really changes. Riders joining, leaving,
        // expiring or moving are handled slot by slot inside the running session.
        social.session.$generation.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.restart() }.store(in: &observers)
        social.live.$ride.map { $0?.id }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.restart() }.store(in: &observers)
        social.$capabilities.map(\.hardware).removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.restart() }.store(in: &observers)
        social.$capabilities.map(\.media).removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.portraits = [:] }.store(in: &observers)
        ble.$supportsGroupRiders.combineLatest(ble.$isNavigationReady).map { $0 && $1 }
            .removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.restart() }.store(in: &observers)
        restart()
    }

    private func restart() {
        task?.cancel()
        portraits = [:]
        let epoch = UInt32.random(in: 1...UInt32.max)
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.isReady else { return }  // Readiness changes restart the relay.
                if await self.engine.begin(epoch: epoch) { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            while !Task.isCancelled {
                await self.tick()
                if self.engine.needsSessionRestart, !Task.isCancelled {
                    self.restart()  // The device lost this session, e.g. after a reset.
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func tick() async {
        guard let social, social.capabilities.hardware, social.session.state == .signedIn else {
            await engine.clearAll()
            return
        }
        let me = social.profile?.id
        let riders = social.visibleRiders.filter { $0.id != me }.map { rider in
            SocialRelayRider(id: rider.id, latitude: rider.latitude, longitude: rider.longitude,
                             ageSeconds: rider.age(at: Date()), accuracy: rider.horizontalAccuracy,
                             course: rider.course, initials: rider.profile.initials,
                             pixels: portrait(for: rider.profile))
        }
        let own = social.live.latestLocation.map { (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        await engine.update(riders: riders, own: own)
    }

    private func portrait(for profile: SocialProfile) -> Data? {
        guard let asset = profile.avatarID, let image = social?.photos[asset] else { return nil }
        if let cached = portraits[asset] { return cached }
        let value = Self.rgb565(image)
        portraits[asset] = value
        return value
    }

    private static func rgb565(_ image: UIImage) -> Data? {
        guard let cg = image.cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: 40*40*4)
        let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 40, height: 40))
            return true
        }
        guard ok else { return nil }
        var result = Data(capacity: 3200)
        for p in stride(from: 0, to: rgba.count, by: 4) {
            var value = (UInt16(rgba[p] >> 3) << 11 | UInt16(rgba[p+1] >> 2) << 5 | UInt16(rgba[p+2] >> 3)).littleEndian
            Swift.withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        return result
    }
}
