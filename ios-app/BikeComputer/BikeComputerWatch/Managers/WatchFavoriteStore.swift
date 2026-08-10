import Combine
import Foundation

@MainActor
final class WatchFavoriteStore: ObservableObject {
    @Published private(set) var favorites: [SyncedCoordinateFavoriteV1] = []
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var lastSyncError: String?

    private static let cacheKey = "watchNavigation.coordinateFavorites.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.cacheKey),
              let envelope = try? CoordinateFavoritesEnvelopeV1.decode(data)
        else { return }
        apply(envelope)
    }

    func receiveApplicationContext(_ context: [String: Any]) {
        guard let data = context[
            CoordinateFavoritesEnvelopeV1.applicationContextKey
        ] as? Data else { return }
        do {
            let envelope = try CoordinateFavoritesEnvelopeV1.decode(data)
            guard envelope.revision >= revision else { return }
            if envelope.revision == revision {
                guard envelope.favorites == favorites else {
                    lastSyncError = "favorite_revision_conflict"
                    return
                }
                lastSyncError = nil
                return
            }
            apply(envelope)
            defaults.set(try envelope.encoded(), forKey: Self.cacheKey)
            lastSyncError = nil
        } catch {
            lastSyncError = "invalid_favorites"
        }
    }

    private func apply(_ envelope: CoordinateFavoritesEnvelopeV1) {
        revision = envelope.revision
        favorites = envelope.favorites
    }
}
