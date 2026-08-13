//
//  OfflineMapOnboardingView.swift
//  BikeComputer
//
//  First-run welcome and guided current-location map install flow.
//

import CoreLocation
import SwiftUI
import UIKit

struct OfflineMapOnboardingView: View {
    @ObservedObject var manager: OfflineMapManager
    let step: OfflineMapOnboardingStep
    let location: CLLocation?
    let isLocationAuthorized: Bool
    let onRequestLocation: () -> Void
    let onChooseArea: () -> Void
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")

                Spacer()
            }

            VStack(spacing: 18) {
                artwork

                Text(step.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(step.message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                actionContent
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private var artwork: some View {
        switch step {
        case .welcome:
            Image("BicinoLogo")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.bicinoBrandRed)
                .frame(width: 88, height: 64)
                .accessibilityLabel("Bicino")

        case .download:
            Image(systemName: "map.circle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(height: 48)
        }
    }

    @ViewBuilder
    private var actionContent: some View {
        switch step {
        case .welcome:
            Button(action: onClose) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

        case .download:
            VStack(spacing: 12) {
                if manager.isBusy {
                    ProgressView(value: manager.transferProgress > 0 ? manager.transferProgress : nil)
                    Text(manager.statusMessage.isEmpty ? "Preparing map" : manager.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else if !isLocationAuthorized {
                    locationActions
                } else if location == nil {
                    ProgressView()
                    Text("Finding your location…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Button(action: onChooseArea) {
                        Label("Choose Area", systemImage: "rectangle.dashed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let error = manager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var locationActions: some View {
        VStack(spacing: 10) {
            Button(action: onRequestLocation) {
                Label("Enable Location", systemImage: "location")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("Open iPhone Settings")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

private extension OfflineMapOnboardingStep {
    var title: String {
        switch self {
        case .welcome:
            return "Welcome to Bicino"
        case .download:
            return "Download Map"
        }
    }

    var message: String {
        switch self {
        case .welcome:
            return "Plan your rides, connect your Bicino One, or turn your iPhone into a cycling computer."
        case .download:
            return "Choose an area to download to your Bike Computer."
        }
    }
}

private extension Color {
    static let bicinoBrandRed = Color(
        red: 1,
        green: 55.0 / 255.0,
        blue: 46.0 / 255.0
    )
}
