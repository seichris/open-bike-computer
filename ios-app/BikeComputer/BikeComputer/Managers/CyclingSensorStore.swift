import Combine
import Foundation

private struct CyclingSensorRegistryEnvelope: Codable {
    static let currentVersion = 1

    let version: Int
    let profiles: [CyclingSensorProfile]
}

@MainActor
final class CyclingSensorStore: ObservableObject {
    nonisolated static let defaultStorageKey = "cyclingSensors.registry.v1"

    @Published private(set) var profiles: [CyclingSensorProfile]

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: () -> Date
    private let idGenerator: () -> UUID

    var enabledCapabilities: CyclingSensorCapabilities {
        profiles.reduce(into: CyclingSensorCapabilities()) {
            capabilities, profile in
            guard profile.isEnabled else { return }
            capabilities.formUnion(profile.capabilities)
        }
        .intersection(.supported)
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = CyclingSensorStore.defaultStorageKey,
        now: @escaping () -> Date = Date.init,
        idGenerator: @escaping () -> UUID = UUID.init
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
        self.idGenerator = idGenerator
        profiles = Self.loadProfiles(
            defaults: defaults,
            storageKey: storageKey
        )
    }

    @discardableResult
    func enroll(
        name: String,
        capabilities: CyclingSensorCapabilities,
        lastObservedAt: Date? = nil
    ) -> CyclingSensorProfile? {
        let normalizedCapabilities = capabilities.intersection(.supported)
        guard !normalizedCapabilities.isEmpty else { return nil }
        let createdAt = now()

        let profile = CyclingSensorProfile(
            id: idGenerator(),
            name: normalizedName(
                name,
                fallback: normalizedCapabilities.suggestedSensorName
            ),
            capabilities: normalizedCapabilities,
            isEnabled: true,
            identityKind: .logical,
            createdAt: createdAt,
            lastObservedAt: lastObservedAt
        )
        profiles.append(profile)
        persist()
        return profile
    }

    func rename(profileID: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID })
        else {
            return
        }
        let normalized = normalizedName(name, fallback: profiles[index].name)
        guard profiles[index].name != normalized else { return }
        profiles[index].name = normalized
        persist()
    }

    func setEnabled(_ enabled: Bool, profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].isEnabled != enabled else {
            return
        }
        profiles[index].isEnabled = enabled
        persist()
    }

    func forget(profileID: UUID) {
        let previousCount = profiles.count
        profiles.removeAll { $0.id == profileID }
        guard profiles.count != previousCount else { return }
        persist()
    }

    func profile(id: UUID) -> CyclingSensorProfile? {
        profiles.first { $0.id == id }
    }

    func profiles(
        matching capabilities: CyclingSensorCapabilities
    ) -> [CyclingSensorProfile] {
        profiles.filter {
            !$0.capabilities.intersection(capabilities).isEmpty
        }
    }

    func markObserved(
        capabilities: CyclingSensorCapabilities,
        at date: Date
    ) {
        var changed = false
        for index in profiles.indices {
            guard !profiles[index].capabilities
                .intersection(capabilities)
                .isEmpty else {
                continue
            }
            if let previous = profiles[index].lastObservedAt,
               date.timeIntervalSince(previous) < 30 {
                continue
            }
            profiles[index].lastObservedAt = date
            changed = true
        }
        if changed {
            persist()
        }
    }

    private func normalizedName(_ name: String, fallback: String) -> String {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return fallback
        }
        return String(normalized.prefix(60))
    }

    private func persist() {
        let envelope = CyclingSensorRegistryEnvelope(
            version: CyclingSensorRegistryEnvelope.currentVersion,
            profiles: profiles
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func loadProfiles(
        defaults: UserDefaults,
        storageKey: String
    ) -> [CyclingSensorProfile] {
        guard let data = defaults.data(forKey: storageKey),
              let envelope = try? JSONDecoder().decode(
                  CyclingSensorRegistryEnvelope.self,
                  from: data
              ),
              envelope.version
                == CyclingSensorRegistryEnvelope.currentVersion else {
            return []
        }
        return envelope.profiles.filter {
            !$0.capabilities.intersection(.supported).isEmpty
                && !$0.name
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
        }
    }
}
