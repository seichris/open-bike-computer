//
//  AuxiliaryViews.swift
//  BikeComputer
//
//  Auxiliary UI components (connection status, calculation status, etc.)
//

import SwiftUI

extension View {
    @ViewBuilder
    func mapOverlayGlassSurface(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(
                    color: .black.opacity(0.14),
                    radius: 7,
                    x: 0,
                    y: 3
                )
        }
    }
}

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

    private var statusSymbolName: String {
        isConnected
            ? "antenna.radiowaves.left.and.right"
            : "antenna.radiowaves.left.and.right.slash"
    }

    private var statusSymbolColor: Color {
        isConnected ? .black : Color(uiColor: .systemGray3)
    }
    
    var body: some View {
        Button(action: onReconnect) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbolName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(statusSymbolColor)
                    .accessibilityHidden(true)

                Text(displayName)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(isConnected ? .primary : .black)
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
