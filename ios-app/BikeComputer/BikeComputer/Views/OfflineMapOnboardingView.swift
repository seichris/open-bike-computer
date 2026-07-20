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
    let step: OfflineMapOnboardingStep
    let location: CLLocation?
    let isLocationAuthorized: Bool
    let onRequestLocation: () -> Void
    let onSkipLocation: () -> Void
    let onConnectDevice: () -> Void
    let onCheckDeviceMaps: () -> Void
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

                if step == .location {
                    Button("Skip", action: onSkipLocation)
                        .font(.subheadline.weight(.semibold))
                }
            }

            VStack(spacing: 18) {
                Image(systemName: step.symbol)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(height: 48)

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
    private var actionContent: some View {
        switch step {
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
            VStack(spacing: 10) {
                Button(action: onConnectDevice) {
                    Label("Connect Bike Computer", systemImage: "bicycle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Text(bleManager.centralStateDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .checkingDevice:
            VStack(spacing: 12) {
                ProgressView()
                Text("Checking map storage…")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: onCheckDeviceMaps) {
                    Label("Check Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

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

        case .storageUnavailable:
            Button(action: onCheckDeviceMaps) {
                Label("Check Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
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
    var symbol: String {
        switch self {
        case .location:
            return "location.circle"
        case .device:
            return "antenna.radiowaves.left.and.right.circle"
        case .checkingDevice:
            return "externaldrive.badge.questionmark"
        case .download:
            return "map.circle"
        case .storageUnavailable:
            return "sdcard"
        }
    }

    var title: String {
        switch self {
        case .location:
            return "Enable Location"
        case .device:
            return "Connect Your Bike Computer"
        case .checkingDevice:
            return "Checking Your Bike Computer"
        case .download:
            return "Download Map"
        case .storageUnavailable:
            return "Insert an SD Card"
        }
    }

    var message: String {
        switch self {
        case .location:
            return "Bike Computer needs your current location to prepare the right offline map."
        case .device:
            return "Connect your Bike Computer before downloading its first map."
        case .checkingDevice:
            return "The app is checking whether your Bike Computer already has a map."
        case .download:
            return "Choose an area to download to your Bike Computer."
        case .storageUnavailable:
            return "Insert an SD card in your Bike Computer, then check again."
        }
    }
}
