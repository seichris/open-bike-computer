# Headless Navigation Bike Computer

A specialized bike computer system using ESP32-S3 AMOLED display and iPhone for map routing.

## Architecture

**Headless Navigation**: iPhone handles complex routing (MapKit), ESP32 displays simplified instructions.

- **Central Device**: iPhone (Swift/SwiftUI)
- **Peripheral Device**: Waveshare ESP32-S3 Touch AMOLED 1.75" (Round Display)
- **Communication**: Bluetooth Low Energy (BLE)

## Hardware Specifications

### ESP32-S3 Board
- **Board**: Waveshare ESP32-S3-Touch-AMOLED-1.75
- **Display**: CO5300 (QSPI Interface) - 466 x 466 pixels
- **Touch**: CST9217 (I2C)
- **Memory**: OPI PSRAM, QSPI Flash

### Pinout

**QSPI Display (CO5300)**:
- CS: GPIO 12
- CLK: GPIO 38
- D0: GPIO 4
- D1: GPIO 5
- D2: GPIO 6
- D3: GPIO 7
- RST: GPIO 39

**I2C Touch (CST9217)**:
- SDA: GPIO 15
- SCL: GPIO 14

## Project Structure

```
xeg/
├── esp32/                      # ESP32 Firmware (PlatformIO)
│   ├── platformio.ini         # Platform configuration
│   ├── src/
│   │   ├── main.cpp           # Main firmware code
│   │   └── ui/                # SquareLine Studio UI files
│   └── lib/                   # Additional libraries
│
└── ios-app/                   # iOS Application (Swift/SwiftUI)
    └── BikeComputer/
        └── Managers/
            ├── NavigationEngine.swift  # MapKit routing logic
            └── BLEManager.swift        # Bluetooth communication
```

## ESP32 Firmware

### Features
- **Display Driver**: Arduino_GFX with CO5300 QSPI driver
- **BLE Server**: NimBLE-Arduino for low-power communication
- **UI Framework**: LVGL 8.3 with SquareLine Studio integration
- **Data Format**: Receives "IconID|Distance|Instruction" packets

### Building & Flashing

1. Install PlatformIO IDE or PlatformIO Core
2. Open the `esp32` folder in VS Code with PlatformIO extension
3. Build and upload:

```bash
cd esp32
pio run --target upload
```

### BLE Service Details
- **Service UUID**: `1819` (Navigation Service)
- **Characteristic UUID**: `2A6E` (Write)
- **Device Name**: `BikeComputer`

### Data Protocol

Format: `IconID|Distance|Instruction`

Example: `2|150|Turn Left`

**Icon ID Mapping**:
- `0`: Straight/Continue
- `1`: Slight Left
- `2`: Turn Left
- `3`: Slight Right
- `4`: Turn Right
- `5`: U-Turn
- `6`: Merge
- `7`: Roundabout
- `8`: Destination

## iOS Application

### Features
- **Navigation Engine**: Monitors MKRoute and extracts maneuvers
- **Smart Updates**: Only sends data when changed significantly (>10m or new instruction)
- **Auto-Connect**: Automatically finds and connects to ESP32
- **Background Support**: Continues navigation when app is backgrounded

### Requirements
- iOS 15.0+
- Xcode 14.0+
- Location permissions (Always)
- Bluetooth permissions

### Integration Example

```swift
import SwiftUI
import MapKit

struct ContentView: View {
    @StateObject private var bleManager = BLEManager()
    @StateObject private var navEngine = NavigationEngine()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Bike Computer")
                .font(.largeTitle)
            
            // BLE Status
            HStack {
                Circle()
                    .fill(bleManager.isConnected ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(bleManager.isConnected ? "Connected" : "Disconnected")
            }
            
            // Navigation Status
            if navEngine.isNavigating {
                VStack {
                    Text(navEngine.currentInstruction)
                        .font(.headline)
                    Text("\(navEngine.distanceToManeuver)m")
                        .font(.title)
                    Text("Icon ID: \(navEngine.currentIconID)")
                        .font(.caption)
                }
            }
            
            Button("Start Test Navigation") {
                startTestNavigation()
            }
        }
        .padding()
        .onAppear {
            navEngine.setBLEManager(bleManager)
            bleManager.startScanning()
        }
    }
    
    func startTestNavigation() {
        // Get a route from MapKit
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 37.8049, longitude: -122.4094)))
        request.transportType = .automobile
        
        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            if let route = response?.routes.first {
                navEngine.startNavigation(with: route)
            }
        }
    }
}
```

### Info.plist Requirements

Add these keys to your `Info.plist`:

```xml
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>We need your location for turn-by-turn navigation</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>We need your location for turn-by-turn navigation</string>

<key>NSBluetoothAlwaysUsageDescription</key>
<string>We need Bluetooth to connect to your bike computer</string>

<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>location</string>
</array>
```

## Development Workflow

### 1. Design UI in SquareLine Studio

1. Create a new LVGL 8.3 project with 466x466 resolution
2. Design your navigation UI with labels for:
   - `ui_LabelInstruction` - Instruction text
   - `ui_LabelDistance` - Distance to maneuver
   - `ui_ImageArrow` - Arrow icon
3. Export UI files to `esp32/src/ui/`

### 2. Update main.cpp UI Integration

Uncomment and adjust the UI update code in `parseNavigationData()`:

```cpp
if (ui_LabelDistance != NULL) {
    lv_label_set_text_fmt(ui_LabelDistance, "%d m", navData.distance);
}
if (ui_LabelInstruction != NULL) {
    lv_label_set_text(ui_LabelInstruction, navData.instruction);
}
```

### 3. Test with Simulated Navigation

The iOS app includes simulated navigation for testing without GPS:

```swift
// Use this instead of startNavigation() for testing
navEngine.startSimulatedNavigation(with: route)
```

## Troubleshooting

### ESP32 Display Issues

**Problem**: Display shows wrong colors or corrupted graphics

**Solution**: The CO5300 requires Big Endian RGB565. The flush callback in `main.cpp` handles byte swapping:

```cpp
uint16_t swapped = (pixel >> 8) | (pixel << 8);
```

### BLE Connection Issues

**Problem**: iPhone can't find ESP32

**Solutions**:
1. Verify ESP32 is powered and running (check Serial Monitor)
2. Ensure Bluetooth is enabled on iPhone
3. Check that Service UUID matches (`1819`)
4. Restart both devices

**Problem**: Connection drops frequently

**Solutions**:
1. Move devices closer (BLE range ~10m)
2. Reduce metal interference
3. Check power supply stability on ESP32

### Location Updates Not Working

**Problem**: Navigation not updating

**Solutions**:
1. Verify location permissions (Always)
2. Check GPS signal strength
3. Enable "Precise Location" in iOS settings
4. Use simulated navigation for indoor testing

## Performance Optimization

### ESP32
- LVGL buffer size: 1/10 screen = ~22KB (balance between RAM and performance)
- BLE write without response for minimal latency
- 5ms loop delay = ~200Hz UI refresh

### iOS
- Distance filter: 5m (update every 5 meters of movement)
- Update threshold: 10m (only send when distance changes >10m)
- Background location updates enabled

## Power Consumption

- **ESP32 Active Display**: ~150mA @ 3.3V
- **ESP32 BLE Connected**: +20mA
- **Total**: ~170mA (~0.56W)
- **Estimated Runtime**: 5-6 hours on 1000mAh battery

## Future Enhancements

- [ ] Battery level monitoring
- [ ] Speed and cadence sensor integration
- [ ] Offline map support
- [ ] Route recording/GPX export
- [ ] Custom icon sets
- [ ] Weather overlay
- [ ] ANT+ sensor support

## License

MIT License - feel free to modify and use in your projects.

## Credits

- Arduino_GFX by moononournation
- LVGL by LVGL LLC
- NimBLE-Arduino by h2zero
- SquareLine Studio by LVGL LLC
