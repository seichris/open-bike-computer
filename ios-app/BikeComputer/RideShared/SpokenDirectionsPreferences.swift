import Foundation

nonisolated struct SpokenDirectionsPreferencesV1: Codable, Equatable {
    var enabled = false
    var dynamicInstructions = false
    var volume: UInt8 = 70

    static func load(deviceID: String?, defaults: UserDefaults = .standard) -> Self {
        guard let deviceID, !deviceID.isEmpty,
              let data = defaults.data(forKey: key(deviceID)),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.volume <= 100 else {
            return Self()
        }
        return value
    }

    func save(deviceID: String, defaults: UserDefaults = .standard) {
        guard !deviceID.isEmpty, volume <= 100,
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(deviceID))
    }

    private static func key(_ deviceID: String) -> String { "spokenDirections.v1.\(deviceID)" }
}
