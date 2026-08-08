import SwiftUI

struct WatchNavigationStatusView: View {
    @ObservedObject var navigationManager: WatchNavigationManager
    @ObservedObject var deviceLink: WatchDeviceLink
    let farStartCancelTitle: String

    @ViewBuilder
    var body: some View {
        switch navigationManager.state {
        case .idle:
            EmptyView()
        case .waitingForLocation:
            Label("Preparing offline route…", systemImage: "location")
                .font(.caption2)
        case .waitingForOnlineLocation:
            Label("Waiting for Watch GPS…", systemImage: "location")
                .font(.caption2)
        case .requestingOnline:
            ProgressView("Calculating route…")
                .font(.caption2)
        case .awaitingStartConfirmation(_, let distance):
            VStack(spacing: 5) {
                Label(
                    "Route starts \(Int(distance.rounded())) m away",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                Button("Start Anyway") {
                    navigationManager.startAnyway()
                }
                .font(.caption2)
                Button(farStartCancelTitle) {
                    navigationManager.stopNavigation()
                }
                .font(.caption2)
            }
        case .navigating:
            activeStatus(offRouteDistance: nil)
        case .offRoute(_, let distance):
            activeStatus(offRouteDistance: distance)
        case .unavailable(let reason):
            VStack(spacing: 4) {
                Label(reason, systemImage: "map.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                if navigationManager.canRetryOnlineInitial {
                    Button("Retry Online Route") {
                        navigationManager.retryOnlineRoute()
                    }
                    .font(.caption2)
                }
                Button("Dismiss Navigation") {
                    navigationManager.stopNavigation()
                }
                .font(.caption2)
            }
        case .stopping:
            ProgressView("Stopping navigation…")
                .font(.caption2)
        }
    }

    private func activeStatus(offRouteDistance: Double?) -> some View {
        VStack(spacing: 4) {
            if let snapshot = navigationManager.snapshot {
                Label(
                    snapshot.instruction,
                    systemImage: "arrow.triangle.turn.up.right.diamond.fill"
                )
                .font(.caption)
                .multilineTextAlignment(.center)
                Text(
                    "\(Int(snapshot.distanceToManeuverMeters.rounded())) m · " +
                    "\(distanceText(snapshot.routeRemainingDistanceMeters)) left"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if let offRouteDistance {
                Text(offRouteDescription(distance: offRouteDistance))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if !navigationManager.onlineStatus.userDescription.isEmpty {
                Text(navigationManager.onlineStatus.userDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let attribution = navigationManager.routeAttribution {
                Text("Route by \(attribution)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(bicinoNavigationStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if navigationManager.canRecalculateOnline {
                Button("Recalculate Route") {
                    navigationManager.recalculateOnlineRoute()
                }
                .font(.caption2)
            }
            Button("Stop Navigation") {
                navigationManager.stopNavigation()
            }
            .font(.caption2)
            .tint(.orange)
        }
    }

    private func offRouteDescription(distance: Double) -> String {
        let prefix = "Off route by \(Int(distance.rounded())) m · "
        switch navigationManager.onlineStatus {
        case .rerouting:
            return prefix + "Rerouting"
        case .rerouteFailed:
            return prefix + "Reroute failed - continuing route"
        case .continuingCachedRoute, .noConnection:
            return prefix + "Offline - continuing route"
        case .online:
            return prefix + "Waiting to reroute"
        case .waitingForLocation, .calculating:
            return prefix + "Preparing reroute"
        case .routeFailed:
            return prefix + "Route calculation failed"
        case .offlinePolicy, .idle:
            return prefix + "Rerouting unavailable offline"
        }
    }

    private func distanceText(_ meters: Double) -> String {
        meters >= 1_000
            ? String(format: "%.1f km", meters / 1_000)
            : "\(Int(meters.rounded())) m"
    }

    private var bicinoNavigationStatus: String {
        switch deviceLink.state {
        case .ready: "Bicino connected"
        case .busy: "Bicino is controlled by iPhone"
        case .notEnrolled: "Bicino not enrolled for Watch"
        case .scanning, .connecting, .discovering, .authenticating,
                .claimingLease:
            "Connecting Bicino…"
        case .bluetoothUnavailable: "Watch Bluetooth unavailable"
        case .failed, .idle: "Bicino not connected"
        }
    }
}
