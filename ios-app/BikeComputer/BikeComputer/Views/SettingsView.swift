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
                
                Section(header: Text("Map Rendering"), footer: Text("Feature toggles control map categories; polygon size filters tiny filled areas.")) {
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
                
                Section(header: Text("Detail Level"), footer: Text("Controls small-area density without overriding feature visibility.")) {
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
                        Slider(value: $bleManager.routeLineWidth, in: 2...48, step: 1)
                            .onChange(of: bleManager.routeLineWidth) { newValue in
                                bleManager.sendSetting(id: 3, value: Int32(newValue))
                        }
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Position Marker Size")
                            Spacer()
                            Text("\(Int(bleManager.positionMarkerScale))x")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $bleManager.positionMarkerScale, in: 1...5, step: 1)
                            .onChange(of: bleManager.positionMarkerScale) { newValue in
                                bleManager.sendSetting(id: 10, value: Int32(newValue))
                        }
                    }
                }
                .disabled(!bleManager.supportsDeviceSettings)

                Section(header: Text("Map Streets")) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Street Width Boost")
                            Spacer()
                            Text("+\(Int(bleManager.streetLineWidthBoost)) px")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $bleManager.streetLineWidthBoost, in: 0...24, step: 1)
                            .onChange(of: bleManager.streetLineWidthBoost) { newValue in
                                bleManager.sendSetting(id: 9, value: Int32(newValue))
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
                        Text("North Up").tag(0)
                        Text("Course Up").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: bleManager.mapRotationMode) { newValue in
                        // ID 6 = mapRotationMode
                        bleManager.sendSetting(id: 6, value: Int32(newValue))
                    }
                }
                .disabled(!bleManager.supportsDeviceSettings)

                Section(header: Text("Screen Navigation")) {
                    Toggle("Tap to Switch Screens", isOn: $bleManager.tapToSwitchScreens)
                        .onChange(of: bleManager.tapToSwitchScreens) { newValue in
                            bleManager.sendSetting(id: 11, value: newValue ? 1 : 0)
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
                
                Section(header: Text("Navigation Overlays"), footer: Text("Show or hide live navigation layers drawn above the map.")) {
                    Toggle("Route Line", isOn: $bleManager.showRouteOverlay)
                        .onChange(of: bleManager.showRouteOverlay) { _ in bleManager.sendVisibilityMask() }
                    Toggle("Current Position", isOn: $bleManager.showCurrentPosition)
                        .onChange(of: bleManager.showCurrentPosition) { _ in bleManager.sendVisibilityMask() }
                }
                .disabled(!bleManager.supportsDeviceSettings)

                Section(header: Text("Roads & Paths"), footer: Text("Control which street and trail classes appear on the device map.")) {
                    Toggle("Major Roads", isOn: $bleManager.showMajorRoads)
                        .onChange(of: bleManager.showMajorRoads) { _ in bleManager.sendVisibilityMask() }
                    Toggle("Local Streets", isOn: $bleManager.showLocalStreets)
                        .onChange(of: bleManager.showLocalStreets) { _ in bleManager.sendVisibilityMask() }
                    Toggle("Paths & Tracks", isOn: $bleManager.showPaths)
                        .onChange(of: bleManager.showPaths) { _ in bleManager.sendVisibilityMask() }
                    Toggle("Railways", isOn: $bleManager.showRailways)
                        .onChange(of: bleManager.showRailways) { _ in bleManager.sendVisibilityMask() }
                }
                .disabled(!bleManager.supportsDeviceSettings)

                Section(header: Text("Places & Terrain"), footer: Text("Control background map areas and lower-priority context.")) {
                    Toggle("Buildings", isOn: $bleManager.showBuildings)
                        .onChange(of: bleManager.showBuildings) { _ in bleManager.sendVisibilityMask() }
                    Toggle("Parks & Nature", isOn: $bleManager.showGreenSpace)
                        .onChange(of: bleManager.showGreenSpace) { _ in bleManager.sendVisibilityMask() }
                    Toggle("Water", isOn: $bleManager.showWater)
                        .onChange(of: bleManager.showWater) { _ in bleManager.sendVisibilityMask() }
                    Toggle("Other Areas", isOn: $bleManager.showOtherAreas)
                        .onChange(of: bleManager.showOtherAreas) { _ in bleManager.sendVisibilityMask() }
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
