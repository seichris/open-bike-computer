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
        VStack(spacing: 8) {
            if let snapshot = navigationManager.snapshot {
                Text(
                    "\(instructionText(snapshot.instruction)) in " +
                    compactDistance(snapshot.distanceToManeuverMeters)
                )
                .font(.headline)
                .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    navigationTile(
                        text: offRouteDistance.map {
                            "Off route by \(compactDistance($0))"
                        } ?? "On route",
                        icon: offRouteDistance == nil
                            ? "checkmark.circle.fill"
                            : "location.slash.fill",
                        color: offRouteDistance == nil ? .green : .orange
                    )
                    navigationTile(
                        text: "\(compactDistance(snapshot.routeRemainingDistanceMeters)) left",
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        color: .green
                    )
                }

                if let routingNotice {
                    Label(routingNotice, systemImage: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let routeAttribution {
                    Text("Route by \(routeAttribution)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let deviceFailureMessage {
                    Label(
                        deviceFailureMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var routingNotice: String? {
        switch navigationManager.onlineStatus {
        case .noConnection, .continuingCachedRoute, .rerouting,
                .rerouteFailed:
            navigationManager.onlineStatus.userDescription
        case .idle, .offlinePolicy, .waitingForLocation, .calculating,
                .routeFailed, .online:
            nil
        }
    }

    private var routeAttribution: String? {
        guard let attribution = navigationManager.routeAttribution,
              attribution != RouteProviderPolicyV1.importedGPX.attribution else {
            return nil
        }
        return attribution
    }

    private var deviceFailureMessage: String? {
        switch deviceLink.state {
        case .notEnrolled:
            "Set up Apple Watch for this Bicino on iPhone"
        case .bluetoothUnavailable:
            "Bicino Bluetooth unavailable"
        case .busy:
            deviceLink.lastError ?? "Bicino is controlled by iPhone"
        case .failed:
            deviceLink.lastError ?? "Bicino connection failed"
        case .idle, .scanning, .connecting, .discovering, .authenticating,
                .claimingLease, .stopping, .ready:
            nil
        }
    }

    private func navigationTile(
        text: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(text)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func compactDistance(_ meters: Double) -> String {
        meters >= 1_000
            ? String(format: "%.1fkm", meters / 1_000)
            : "\(Int(meters.rounded()))m"
    }

    private func instructionText(_ instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let suffix = " checkpoint"
        guard trimmed.lowercased().hasSuffix(suffix) else {
            return trimmed
        }
        return String(trimmed.dropLast(suffix.count))
    }
}
