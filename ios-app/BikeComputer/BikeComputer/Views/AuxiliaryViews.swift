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
    let signalStrength: Int
    let onReconnect: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            // Status Light
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundColor(isConnected ? .green : .red)
                .shadow(color: isConnected ? .green.opacity(0.5) : .red.opacity(0.5), 
                       radius: 4)
            
            // "BikeComputer" Label
            Text("BikeComputer")
                .font(.caption)
                .foregroundColor(.secondary)
                    
            // Signal Info
            if isConnected && signalStrength != 0 {
                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
                
                Image(systemName: SignalIcon.icon(for: signalStrength))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                Text("\(signalStrength) dBm")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Reconnect Button (only shown when not connected)
            if !isConnected {
                Button(action: onReconnect) {
                    Label("Reconnect", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemGray6))
        )
        .padding(.horizontal, 30)
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
        .frame(height: 550)
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

