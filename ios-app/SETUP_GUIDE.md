
### 6. Build Settings (Optional Optimizations)

For better background performance:

1. Select target → Build Settings
2. Search for "Background Fetch"
3. Enable background fetch interval

## Testing

### Simulator Testing (Limited)

The iOS Simulator has limitations:
- ✅ BLE scanning (won't find real devices)
- ✅ UI and layout testing
- ❌ Actual GPS location (use simulated location)
- ❌ Real BLE connections

**To simulate location:**
1. Run app in Simulator
2. Debug → Location → Custom Location...
3. Or use GPX file: Debug → Simulate Location → [Choose route]

### Device Testing (Recommended)

1. Connect your iPhone to Mac
2. Select your iPhone as destination
3. Run the app
4. Grant location and Bluetooth permissions when prompted
5. Use simulated navigation:

```swift
// In ContentView.swift, change:
navEngine.startNavigation(with: route)

// To:
navEngine.startSimulatedNavigation(with: route)
```

### Testing Checklist

- [ ] App builds without errors
- [ ] Location permission prompt appears
- [ ] Bluetooth permission prompt appears
- [ ] Can scan for BLE devices
- [ ] Can connect to ESP32 (when powered on)
- [ ] Navigation updates display correctly
- [ ] Background location continues when app backgrounded
- [ ] BLE connection maintains in background

## Troubleshooting

### Build Errors

**Error: "Value of type 'X' has no member 'Y'"**
- Ensure all files are added to target membership
- Check for typos in @Published property names

**Error: "Cannot find 'CLLocationManager' in scope"**
- Import CoreLocation in affected files
- Already imported in NavigationEngine.swift

### Runtime Issues

**Location Not Updating**
1. Check Info.plist has location keys
2. Verify location permissions granted (Settings → BikeComputer → Location → Always)
3. Enable "Precise Location" in settings
4. Try running on a real device instead of simulator

**BLE Not Finding Device**
1. Ensure ESP32 is powered on and running
2. Check Serial Monitor shows "BLE Server started, advertising..."
3. Verify Bluetooth is enabled on iPhone
4. Try resetting ESP32
5. Check Service UUID matches (`1819`)

**App Crashes on Launch**
1. Check all required Info.plist keys are present
2. Verify minimum deployment target is iOS 15.0+
3. Clean build folder (Shift+Cmd+K)
4. Delete app from device and reinstall

## Production Deployment

Before submitting to App Store:

### 1. Update Permissions Descriptions

Make them more user-friendly and specific to your use case:

```
NSLocationAlwaysAndWhenInUseUsageDescription:
"BikeComputer provides turn-by-turn navigation for your rides. 
Location access is required to show your position and upcoming turns."
```

### 2. Add Privacy Policy

- Create privacy policy document
- Link it in App Store Connect
- Explain data collection and usage

### 3. Test Background Modes

- Test navigation for extended periods
- Verify app doesn't drain battery excessively
- Ensure location updates continue in background

### 4. Optimize Performance

- Profile with Instruments
- Check for memory leaks
- Optimize BLE update frequency if needed

### 5. App Store Assets

- Screenshots (required)
- App icon (1024x1024px)
- Privacy information
- App description mentioning ESP32 hardware requirement

## Advanced Configuration

### Custom BLE Parameters

Edit `BLEManager.swift`:

```swift
// Change device name to look for:
private let serviceUUID = CBUUID(string: "YOUR_UUID")

// Adjust auto-reconnect behavior:
private var autoReconnect: Bool = false
```

### Navigation Update Threshold

Edit `NavigationEngine.swift`:

```swift
// Change distance threshold for updates:
private let distanceThreshold: Int = 20  // meters
```

### Location Accuracy

Edit `NavigationEngine.swift` in `setupLocationManager()`:

```swift
// Higher accuracy but more battery:
locationManager.desiredAccuracy = kCLLocationAccuracyBest

// Lower accuracy, better battery:
locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
```

## Additional Resources

- [Apple MapKit Documentation](https://developer.apple.com/documentation/mapkit)
- [Core Bluetooth Programming Guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/)
- [Core Location Best Practices](https://developer.apple.com/documentation/corelocation)

## Support

For issues specific to:
- **ESP32 Hardware**: Check main README.md
- **iOS Development**: See Apple Developer Forums
- **BLE Communication**: Verify UUIDs match between iOS and ESP32
