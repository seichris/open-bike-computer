//
//  OfflineMapOnboardingView.swift
//  BikeComputer
//
//  Guided current-location map install flow.
//

import CoreLocation
import SwiftUI
import UIKit

struct OfflineMapOnboardingView: View {
    @ObservedObject var manager: OfflineMapManager
    @ObservedObject var bleManager: BLEManager
    let location: CLLocation?
    let isLocationAuthorized: Bool
    let onRequestLocation: () -> Void
    let onChooseArea: () -> Void
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL

    private var currentStep: OfflineMapOnboardingStep {
        if !isLocationAuthorized {
            return .location
        }
        if !bleManager.isNavigationReady {
            return .device
        }
        return .download
    }

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

                Button("Skip", action: onClose)
                    .font(.subheadline.weight(.semibold))
            }

            VStack(spacing: 18) {
                Image(systemName: currentStep.symbol)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(height: 48)

                Text(currentStep.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(currentStep.message)
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
    private var actionContent: some View {
        switch currentStep {
        case .location:
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

        case .device:
            VStack(spacing: 8) {
                ProgressView()
                Text(bleManager.centralStateDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .download:
            VStack(spacing: 12) {
                if manager.isBusy {
                    ProgressView(value: manager.transferProgress > 0 ? manager.transferProgress : nil)
                    Text(manager.statusMessage.isEmpty ? "Preparing map" : manager.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Button(action: onChooseArea) {
                        Label("Choose Area", systemImage: "rectangle.dashed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(location == nil)
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
}

private enum OfflineMapOnboardingStep {
    case location
    case device
    case download

    var symbol: String {
        switch self {
        case .location:
            return "location.circle"
        case .device:
            return "antenna.radiowaves.left.and.right.circle"
        case .download:
            return "map.circle"
        }
    }

    var title: String {
        switch self {
        case .location:
            return "Enable Location"
        case .device:
            return "Connect Your Bike Computer"
        case .download:
            return "Download Map"
        }
    }

    var message: String {
        switch self {
        case .location:
            return "Bike Computer needs your current location to prepare the right offline map."
        case .device:
            return "Boot the device and keep it nearby. The app will continue when BLE is connected."
        case .download:
            return "Download your current area to your Bike Computer."
        }
    }
}
