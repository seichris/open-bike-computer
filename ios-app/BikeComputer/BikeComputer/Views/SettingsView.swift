//
//  SettingsView.swift
//  BikeComputer
//
//  Settings view for runtime map configuration via BLE
//

import SwiftUI

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
                
                Section(header: Text("Display Rotation"), footer: Text("Rotate display 90° CCW. Requires reboot.\n(Note: 180°/270° not supported by CO5300 hardware)")) {
                    Toggle("Rotate 90°", isOn: Binding(
                        get: { bleManager.displayRotation == 1 },
                        set: { newValue in
                            bleManager.displayRotation = newValue ? 1 : 0
                            bleManager.sendSetting(id: 4, value: Int32(bleManager.displayRotation))
                        }
                    ))
                }
                
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
                    .disabled(!bleManager.isConnected)
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
