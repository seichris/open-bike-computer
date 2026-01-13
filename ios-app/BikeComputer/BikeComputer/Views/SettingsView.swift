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
                
                Section(header: Text("Map Rendering"), footer: Text("Skip polygons smaller than this size to improve performance. Higher values = faster rendering but less detail.")) {
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
                
                Section(header: Text("Display Rotation"), footer: Text("Rotate the display. Requires device reboot to apply.")) {
                    Picker("Rotation", selection: $bleManager.displayRotation) {
                        Text("0°").tag(0)
                        Text("90°").tag(1)
                        Text("180°").tag(2)
                        Text("270°").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: bleManager.displayRotation) { newValue in
                        bleManager.sendSetting(id: 4, value: Int32(newValue))
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
