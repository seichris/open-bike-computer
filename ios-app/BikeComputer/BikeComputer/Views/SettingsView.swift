//
//  SettingsView.swift
//  BikeComputer
//
//  Settings view for runtime map configuration via BLE
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var bleManager: BLEManager
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Connection")) {
                    HStack {
                        Text("ESP32")
                        Spacer()
                        Text(bleManager.isConnected ? "Connected" : "Disconnected")
                            .foregroundColor(bleManager.isConnected ? .green : .red)
                    }
                    HStack {
                        Text("Device Settings")
                        Spacer()
                        Text(bleManager.supportsDeviceSettings ? "Available" : "Unavailable")
                            .foregroundColor(bleManager.supportsDeviceSettings ? .green : .secondary)
                    }
                }
                
                Section(header: Text("Map Rendering"), footer: Text("Higher values = faster rendering but less detail.")) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Min Polygon Size")
                            Spacer()
                            Text("\(Int(bleManager.minPolygonSize)) px²")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $bleManager.minPolygonSize, in: 0...50, step: 5)
                            .onChange(of: bleManager.minPolygonSize) { newValue in
                                bleManager.sendSetting(id: 1, value: Int32(newValue))
                        }
                    }
                }
                .disabled(!bleManager.supportsDeviceSettings)
                
                Section(header: Text("Detail Level")) {
                    Picker("Detail", selection: $bleManager.detailLevel) {
                        Text("Low").tag(0)
                        Text("Medium").tag(1)
                        Text("High").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: bleManager.detailLevel) { newValue in
                        bleManager.sendSetting(id: 2, value: Int32(newValue))
                    }
                }
                .disabled(!bleManager.supportsDeviceSettings)
                
                Section(header: Text("Route Overlay")) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Line Width")
                            Spacer()
                            Text("\(Int(bleManager.routeLineWidth)) px")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $bleManager.routeLineWidth, in: 2...8, step: 1)
                            .onChange(of: bleManager.routeLineWidth) { newValue in
                                bleManager.sendSetting(id: 3, value: Int32(newValue))
                        }
                    }
                }
                .disabled(!bleManager.supportsDeviceSettings)
                
                Section(header: Text("Display Rotation"), footer: Text("Rotate display 90° CCW. Requires reboot.")) {
                    Toggle("Rotate 90°", isOn: Binding(
                        get: { bleManager.displayRotation == 1 },
                        set: { newValue in
                            bleManager.displayRotation = newValue ? 1 : 0
                            bleManager.sendSetting(id: 4, value: Int32(bleManager.displayRotation))
                        }
                    ))
                }
                .disabled(!bleManager.supportsDeviceSettings)
                
                Section(header: Text("Map Mode")) {
                    Picker("Rotation", selection: $bleManager.mapRotationMode) {
                        Text("North Up (Red)").tag(0)
                        Text("Head Up (Blue)").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: bleManager.mapRotationMode) { newValue in
                        // ID 6 = mapRotationMode
                        bleManager.sendSetting(id: 6, value: Int32(newValue))
                    }
                }
                .disabled(!bleManager.supportsDeviceSettings)
                
                Section(header: Text("Zoom Level"), footer: Text("0 = Super Zoom, 5 = Farthest")) {
                    Picker("Zoom", selection: $bleManager.zoomLevel) {
                        Text("0").tag(0)
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                        Text("4").tag(4)
                        Text("5").tag(5)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: bleManager.zoomLevel) { newValue in
                        // ID 7 = zoomLevel
                        bleManager.sendSetting(id: 7, value: Int32(newValue))
                    }
                }
                .disabled(!bleManager.supportsDeviceSettings)
                
                Section(header: Text("Feature Visibility"), footer: Text("Show/Hide map features.")) {
                    Toggle("Buildings", isOn: $bleManager.showBuildings)
                        .onChange(of: bleManager.showBuildings) { _ in bleManager.sendVisibilityMask() }
                    Toggle("Parks & Nature", isOn: $bleManager.showNature)
                        .onChange(of: bleManager.showNature) { _ in bleManager.sendVisibilityMask() }
                    Toggle("Paths", isOn: $bleManager.showMinorRoads)
                        .onChange(of: bleManager.showMinorRoads) { _ in bleManager.sendVisibilityMask() }
                }
                .disabled(!bleManager.supportsDeviceSettings)
                
                Section(header: Text("Device")) {
                    Button(action: {
                        bleManager.sendSetting(id: 5, value: 1) // Reboot command
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reboot Device")
                        }
                        .foregroundColor(.blue)
                    }
                    .disabled(!bleManager.isConnected || !bleManager.supportsDeviceSettings)
                }

                Section(header: Text("BLE Debug")) {
                    HStack {
                        Text("Central")
                        Spacer()
                        Text(bleManager.centralStateDescription)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Navigation")
                        Spacer()
                        Text(bleManager.isNavigationReady ? "Ready" : "Not Ready")
                            .foregroundColor(bleManager.isNavigationReady ? .green : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Trusted Device")
                        Text(bleManager.trustedPeripheralDescription)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    Button(action: {
                        bleManager.reconnect()
                    }) {
                        Label("Reconnect", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    Button(action: {
                        bleManager.sendDebugNavigationPacket()
                    }) {
                        Label("Send Test Navigation", systemImage: "arrow.turn.up.left")
                    }
                    .disabled(!bleManager.isNavigationReady)

                    Button(role: .destructive, action: {
                        bleManager.forgetTrustedPeripheral()
                    }) {
                        Label("Forget Device", systemImage: "trash")
                    }

                    Button(action: {
                        UIPasteboard.general.string = bleManager.debugLogText
                    }) {
                        Label("Copy Debug Log", systemImage: "doc.on.doc")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(bleManager.debugEvents.enumerated()), id: \.offset) { _, event in
                            Text(event)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Map Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(BLEManager())
}
