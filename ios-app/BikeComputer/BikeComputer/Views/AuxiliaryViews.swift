//
//  AuxiliaryViews.swift
//  BikeComputer
//
//  Auxiliary UI components (connection status, calculation status, etc.)
//

import SwiftUI

// MARK: - Connection Status View

struct ConnectionStatusView: View {
    let isConnected: Bool
    let deviceName: String
    let hasRegisteredDevice: Bool
    let onReconnect: () -> Void

    private var displayName: String {
        guard isConnected else { return "Bicino" }
        let trimmedName = deviceName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmedName.isEmpty ? "Bicino" : trimmedName
    }

    private var statusColor: Color {
        isConnected ? .green : Color(uiColor: .systemGray3)
    }
    
    var body: some View {
        Button(action: onReconnect) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.caption)
                    .foregroundColor(statusColor)
                    .shadow(
                        color: isConnected ? .green.opacity(0.5) : .clear,
                        radius: 4
                    )

                Text(displayName)
                    .font(.caption)
                    .foregroundColor(isConnected ? .primary : statusColor)
                    .shadow(
                        color: isConnected
                            ? .white.opacity(0.8)
                            : .clear,
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isConnected
                ? "\(displayName) connected"
                : hasRegisteredDevice
                    ? "Reconnect Bicino"
                    : "Connect Bicino"
        )
    }
}

// MARK: - Calculation Status View

struct CalculationStatusView: View {
    let status: String
    
    var body: some View {
        VStack(spacing: 15) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Calculating Route...")
                .font(.title2)
                .foregroundColor(.secondary)

            if !status.isEmpty {
                Text(status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Ready to Navigate View

struct ReadyToNavigateView: View {
    let isConnected: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "map")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Ready to Navigate")
                .font(.title2)
                .foregroundColor(.secondary)
            
            if isConnected {
                Text("Tap 'Start Navigation' to begin")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("Connect to bike computer first")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
        }
        .frame(height: 550)
    }
}

// MARK: - Signal Icon Helper

enum SignalIcon {
    static func icon(for rssi: Int) -> String {
        if rssi > -50 {
            return "wifi"
        } else if rssi > -70 {
            return "wifi.slash"
        } else {
            return "wifi.exclamationmark"
        }
    }
}
