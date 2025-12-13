# ESP32-S3 Bike Computer

Bike navigation computer for ESP32-S3-Touch-AMOLED-1.75 (Waveshare)

## Hardware
- **Display:** 466x466 AMOLED (CO5300 driver, round screen)
- **Touch:** CST9217 capacitive touch
- **MCU:** ESP32-S3 with 8MB PSRAM
- **Connectivity:** BLE 5.0

## Key Configuration

### Display Driver
- Uses `Arduino_CO5300` with QSPI interface
- **Critical:** Flush function must use `gfx->draw16bitRGBBitmap()` for correct pixel rendering
- `LV_COLOR_16_SWAP = 0` with manual byte swapping in flush

### LVGL Setup
- Buffer size: 1/5 of screen when PSRAM available (43,316 pixels)
- Color depth: 16-bit RGB565
- PSRAM mode: OPI (Octal) for data only

### Power Management
- AXP2101 controls display power via DLDO1 (3.3V)
- Manual I2C initialization (address 0x34)

## Development

### Upload
```bash
~/.platformio/penv/bin/platformio run --target upload
```

### Monitor Serial
```bash
screen /dev/cu.usbmodem* 115200
```

### BLE Protocol
Send navigation data as: `IconID|Distance|Instruction`  
Example: `2|150|Turn Right`

## Troubleshooting

**Black Screen:**
- Check AXP2101 power management initialization
- Verify `gfx->displayOn()` and `gfx->setBrightness(255)` are called
- Ensure flush function uses `draw16bitRGBBitmap()`

**LVGL Not Rendering:**
- Verify `LV_COLOR_16_SWAP = 0` in `lv_conf.h`
- Check PSRAM allocation succeeded
- Ensure flush callback is registered correctly
- `~/.platformio/penv/bin/platformio run --target upload` to push firmware to the device. (Left button is Boot button. Keep pressed while replugging the cable, to enter bootloader mode)
