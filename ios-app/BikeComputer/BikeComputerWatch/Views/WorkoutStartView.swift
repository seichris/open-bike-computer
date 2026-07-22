import SwiftUI

struct WorkoutStartView: View {
    @ObservedObject var manager: WatchWorkoutManager
    @State private var showingRecoveryResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "bicycle")
                    .font(.title)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                Text("Outdoor Cycle")
                    .font(.headline)

                setupContent

                if manager.locationAuthorizationState == .denied {
                    Label("Route, altitude, and GPS speed unavailable", systemImage: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if manager.state == .failed {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Dismiss") {
                        manager.dismissSummary()
                    }
                    .buttonStyle(.borderless)
                }

                Link("Privacy Policy", destination: AppPrivacyPolicy.url)
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
        }
        .alert(
            "Reset Workout Recovery?",
            isPresented: $showingRecoveryResetConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Recovery", role: .destructive) {
                manager.confirmResetCorruptRecovery()
            }
        } message: {
            Text(
                "This may abandon an unfinished ride. BikeComputer will preserve the damaged recovery file for diagnosis before resetting setup."
            )
        }
    }

    @ViewBuilder
    private var setupContent: some View {
        switch manager.setupState {
        case .checking:
            ProgressView("Checking Health access…")
                .font(.caption)
        case .needsAuthorization:
            Text("Allow Health access to record this cycling workout and route.")
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("Set Up Health") {
                manager.requestAuthorization()
            }
            .tint(.blue)
        case .authorizing:
            ProgressView("Finish setup…")
                .font(.caption)
        case .ready:
            Button {
                manager.startOutdoorCycling()
            } label: {
                Label("Start Ride", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
            .disabled(manager.state == .failed)
        case .denied:
            Text("BikeComputer can’t start a workout without permission to save workouts in Health.")
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("Check Again") {
                manager.requestAuthorization()
            }
        case .unavailable:
            Text("Health data isn’t available on this Watch.")
                .font(.caption)
                .multilineTextAlignment(.center)
        case .failed:
            if manager.hasCorruptRecoveryState {
                Text("BikeComputer found damaged workout recovery data. Setup is blocked to protect a possible unfinished ride.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Button("Recover Setup") {
                    showingRecoveryResetConfirmation = true
                }
                .tint(.orange)
            } else if manager.hasUnavailableRecoveryState {
                Text("Workout recovery data couldn’t be read. Unlock the Watch and try again.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    manager.retrySetup()
                }
            } else {
                Text("Health setup couldn’t be completed. Try again when the Watch is unlocked.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    manager.retrySetup()
                }
            }
        }
    }

    private var failureMessage: String {
        switch manager.snapshot.errorCode {
        case .authorizationDenied:
            "Health access was denied. No workout was saved."
        case .anotherWorkoutActive:
            "Another app took over the Watch workout session. Check the Watch before starting again."
        case .setupRequired:
            "Finish workout setup before starting."
        case .watchUnavailable:
            "This Watch is unavailable for workouts."
        case .finalSummaryUnavailable:
            "The final workout summary was not available. Check Health before starting again."
        case .terminalChoiceConflict:
            "The other finish choice was already committed."
        case .terminalChoiceUnconfirmed:
            "The requested finish choice could not be confirmed."
        case .sessionFailed, .unknown, nil:
            "The workout couldn’t be started or recovered."
        }
    }
}
