/**
 * Headless Navigation Bike Computer - ESP32-S3 Firmware
 * 
 * Hardware: Waveshare ESP32-S3-Touch-AMOLED-1.75
 * Display: CO5300 (QSPI) - 466x466 pixels
 * Touch: CST9217 (I2C)
 * 
 * Architecture: Receives navigation data from iPhone via BLE
 * Data Format: "IconID|Distance|Instruction" (e.g., "2|150|Turn Left")
 */

#include <Arduino.h>
#include <lvgl.h>
#include <Arduino_GFX_Library.h>
#include <NimBLEDevice.h>
#include <Wire.h>

// Include SquareLine Studio generated UI
extern "C" {
  #include "ui.h"
}

// ============================================================================
// HARDWARE PIN DEFINITIONS
// ============================================================================

// QSPI Display Pins (CO5300)
#define TFT_CS    12
#define TFT_CLK   38
#define TFT_D0    4
#define TFT_D1    5
#define TFT_D2    6
#define TFT_D3    7
#define TFT_RST   39

// I2C Touch Pins (CST9217)
#define TOUCH_SDA 15
#define TOUCH_SCL 14
#define TOUCH_INT -1  // Optional interrupt pin
#define TOUCH_RST -1  // Optional reset pin

// Power Management (AXP2101)
#define AXP2101_I2C_ADDRESS 0x34

// Display Specifications
#define SCREEN_WIDTH  466
#define SCREEN_HEIGHT 466

// ============================================================================
// DISPLAY DRIVER SETUP (Arduino_GFX)
// ============================================================================

// QSPI Bus for CO5300
Arduino_ESP32QSPI *bus = new Arduino_ESP32QSPI(
  TFT_CS,   // CS
  TFT_CLK,  // SCK
  TFT_D0,   // D0
  TFT_D1,   // D1
  TFT_D2,   // D2
  TFT_D3    // D3
);

// CO5300 Display Driver - Use minimal constructor like working demo
Arduino_CO5300 *gfx = new Arduino_CO5300(
  bus,
  TFT_RST,      // RST
  0             // Rotation only
);

// ============================================================================
// LVGL DISPLAY BUFFER
// ============================================================================

static lv_disp_draw_buf_t draw_buf;
static lv_color_t *disp_draw_buf;
static lv_disp_drv_t disp_drv;

// ============================================================================
// LVGL DISPLAY FLUSH CALLBACK
// CRITICAL: CO5300 expects Big Endian RGB565 (LV_COLOR_16_SWAP handles this)
// ============================================================================

void my_disp_flush(lv_disp_drv_t *disp, const lv_area_t *area, lv_color_t *color_p)
{
  uint32_t w = (area->x2 - area->x1 + 1);
  uint32_t h = (area->y2 - area->y1 + 1);

  // Use Arduino_GFX's high-level draw16bitRGBBitmap method
  // This handles all byte swapping and communication correctly for CO5300
  gfx->draw16bitRGBBitmap(area->x1, area->y1, (uint16_t *)color_p, w, h);

  // Inform LVGL that flushing is complete
  lv_disp_flush_ready(disp);
}

// ============================================================================
// TOUCH DRIVER (CST9217)
// ============================================================================

#define CST9217_ADDRESS 0x5A

bool touchPressed = false;
uint16_t touchX = 0, touchY = 0;

void readTouch() {
  // Try to read touch data with error handling
  Wire.beginTransmission(CST9217_ADDRESS);
  Wire.write(0x00);  // Register address for touch data
  uint8_t error = Wire.endTransmission(false);
  
  if (error != 0) {
    touchPressed = false;
    return;
  }
  
  // Request 13 bytes of touch data
  uint8_t bytesReceived = Wire.requestFrom((uint8_t)CST9217_ADDRESS, (uint8_t)13, (uint8_t)true);
  
  if (bytesReceived >= 7) {  // Need at least 7 bytes for basic touch data
    uint8_t data[13];
    for (int i = 0; i < bytesReceived && i < 13; i++) {
      data[i] = Wire.read();
    }
    
    // Parse touch data (CST9217 format)
    uint8_t touchPoints = data[2] & 0x0F;
    if (touchPoints > 0 && bytesReceived >= 7) {
      // Extract raw coordinates (12-bit values)
      uint16_t rawX = ((data[3] & 0x0F) << 8) | data[4];
      uint16_t rawY = ((data[5] & 0x0F) << 8) | data[6];
      
      // Scale from raw resolution (~4096) to display resolution (466)
      // CST9217 typically reports 0-4095 range
      touchX = (rawX * SCREEN_WIDTH) / 4096;
      touchY = (rawY * SCREEN_HEIGHT) / 4096;
      
      // Clamp to screen bounds
      if (touchX >= SCREEN_WIDTH) touchX = SCREEN_WIDTH - 1;
      if (touchY >= SCREEN_HEIGHT) touchY = SCREEN_HEIGHT - 1;
      
      touchPressed = true;
    } else {
      touchPressed = false;
    }
  } else {
    touchPressed = false;
  }
}

void my_touchpad_read(lv_indev_drv_t *indev_driver, lv_indev_data_t *data)
{
  readTouch();
  
  if (touchPressed) {
    data->state = LV_INDEV_STATE_PR;
    data->point.x = touchX;
    data->point.y = touchY;
  } else {
    data->state = LV_INDEV_STATE_REL;
  }
}

// ============================================================================
// BLE SERVER (NimBLE)
// ============================================================================

#define SERVICE_UUID        "1819"  // Navigation Service
#define CHARACTERISTIC_UUID "2A6E"  // Navigation Data Characteristic

NimBLEServer *pServer = nullptr;
NimBLECharacteristic *pCharacteristic = nullptr;
bool deviceConnected = false;

// Navigation Data Structure
struct NavigationData {
  uint8_t iconID;
  uint16_t distance;
  char instruction[64];
};

NavigationData navData = {0, 0, ""};

// BLE Callbacks
class ServerCallbacks: public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer) {
    deviceConnected = true;
    Serial.println("BLE: Client connected");
    // Update UI
    if (ui_LabelBLEStatus != NULL) {
      lv_label_set_text(ui_LabelBLEStatus, "BLE: Connected");
      lv_obj_set_style_text_color(ui_LabelBLEStatus, lv_color_hex(0x4CAF50), LV_PART_MAIN | LV_STATE_DEFAULT);
    }
  }

  void onDisconnect(NimBLEServer* pServer) {
    deviceConnected = false;
    Serial.println("BLE: Client disconnected");
    // Update UI
    if (ui_LabelBLEStatus != NULL) {
      lv_label_set_text(ui_LabelBLEStatus, "BLE: Disconnected");
      lv_obj_set_style_text_color(ui_LabelBLEStatus, lv_color_hex(0xFF6B6B), LV_PART_MAIN | LV_STATE_DEFAULT);
    }
    // Restart advertising
    NimBLEDevice::startAdvertising();
  }
};

// Parse incoming navigation data: "IconID|Distance|Instruction"
void parseNavigationData(String data) {
  int firstPipe = data.indexOf('|');
  int secondPipe = data.indexOf('|', firstPipe + 1);
  
  if (firstPipe == -1 || secondPipe == -1) {
    Serial.println("Invalid data format");
    return;
  }
  
  // Extract components
  navData.iconID = data.substring(0, firstPipe).toInt();
  navData.distance = data.substring(firstPipe + 1, secondPipe).toInt();
  
  String instruction = data.substring(secondPipe + 1);
  instruction.toCharArray(navData.instruction, sizeof(navData.instruction));
  
  Serial.printf("Parsed: Icon=%d, Distance=%dm, Instruction=%s\n", 
                navData.iconID, navData.distance, navData.instruction);
  
  // Update UI labels with received navigation data
  if (ui_LabelDistance != NULL) {
    lv_label_set_text_fmt(ui_LabelDistance, "%d m", navData.distance);
  }
  if (ui_LabelInstruction != NULL) {
    lv_label_set_text(ui_LabelInstruction, navData.instruction);
  }
  if (ui_IconPlaceholder != NULL) {
    // Change icon color based on iconID for now (until we add images)
    uint32_t color = 0x2196F3;  // Default blue
    switch(navData.iconID) {
      case 1: color = 0x4CAF50; break; // Green - Continue
      case 2: color = 0xFFC107; break; // Yellow - Turn Left
      case 3: color = 0xFF9800; break; // Orange - Turn Right
      case 4: color = 0xF44336; break; // Red - U-Turn
      default: color = 0x2196F3; break; // Blue - Default
    }
    lv_obj_set_style_bg_color(ui_IconPlaceholder, lv_color_hex(color), LV_PART_MAIN | LV_STATE_DEFAULT);
  }
}

class CharacteristicCallbacks: public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic) {
    std::string value = pCharacteristic->getValue();
    if (value.length() > 0) {
      String data = String(value.c_str());
      Serial.println("Received: " + data);
      parseNavigationData(data);
    }
  }
};

void setupBLE() {
  Serial.println("Initializing BLE...");
  
  NimBLEDevice::init("BikeComputer");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);  // Maximum power
  
  // Create BLE Server
  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());
  
  // Create Service
  NimBLEService *pService = pServer->createService(SERVICE_UUID);
  
  // Create Characteristic (WRITE)
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    NIMBLE_PROPERTY::WRITE
  );
  
  pCharacteristic->setCallbacks(new CharacteristicCallbacks());
  
  // Start service
  pService->start();
  
  // Start advertising
  NimBLEAdvertising *pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->start();
  
  Serial.println("BLE Server started, advertising...");
}

// ============================================================================
// LVGL INITIALIZATION
// ============================================================================

void setupLVGL() {
  Serial.println("Initializing LVGL...");
  
  lv_init();
  
  // Allocate display buffer - larger buffer with PSRAM for better performance
  // Use 1/5 of screen if PSRAM available, otherwise 1/10
  #ifdef BOARD_HAS_PSRAM
    uint32_t bufSize = SCREEN_WIDTH * SCREEN_HEIGHT / 5;
    Serial.printf("Allocating LVGL buffer: %d bytes (using PSRAM)\n", bufSize * sizeof(lv_color_t));
    // Try PSRAM first (SPIRAM), fallback to internal DMA-capable RAM
    disp_draw_buf = (lv_color_t *)heap_caps_malloc(bufSize * sizeof(lv_color_t), MALLOC_CAP_SPIRAM);
    if (!disp_draw_buf) {
      Serial.println("PSRAM allocation failed, trying internal RAM...");
      bufSize = SCREEN_WIDTH * SCREEN_HEIGHT / 10;  // Smaller buffer for internal RAM
      disp_draw_buf = (lv_color_t *)heap_caps_malloc(bufSize * sizeof(lv_color_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    }
  #else
    uint32_t bufSize = SCREEN_WIDTH * SCREEN_HEIGHT / 10;
    Serial.printf("Allocating LVGL buffer: %d bytes (internal RAM)\n", bufSize * sizeof(lv_color_t));
    disp_draw_buf = (lv_color_t *)heap_caps_malloc(bufSize * sizeof(lv_color_t), MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  #endif
  
  if (!disp_draw_buf) {
    Serial.println("ERROR: LVGL buffer allocation failed!");
    while(1) delay(1000);  // Halt - this is fatal
  }
  
  Serial.printf("✓ LVGL buffer allocated: %d bytes\n", bufSize * sizeof(lv_color_t));
  
  // Initialize draw buffer
  lv_disp_draw_buf_init(&draw_buf, disp_draw_buf, NULL, bufSize);
  
  // Initialize display driver
  lv_disp_drv_init(&disp_drv);
  disp_drv.hor_res = SCREEN_WIDTH;
  disp_drv.ver_res = SCREEN_HEIGHT;
  disp_drv.flush_cb = my_disp_flush;
  disp_drv.draw_buf = &draw_buf;
  
  lv_disp_t *disp = lv_disp_drv_register(&disp_drv);
  
  if (disp == NULL) {
    Serial.println("ERROR: Display driver registration failed!");
    while(1) delay(1000);  // Halt - this is fatal
  }
  
  Serial.println("✓ LVGL Display registered");
  
  // Initialize touch driver
  static lv_indev_drv_t indev_drv;
  lv_indev_drv_init(&indev_drv);
  indev_drv.type = LV_INDEV_TYPE_POINTER;
  indev_drv.read_cb = my_touchpad_read;
  lv_indev_drv_register(&indev_drv);
  
  Serial.println("LVGL initialized");
}

// ============================================================================
// ARDUINO SETUP
// ============================================================================

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n\n=== Headless Navigation Bike Computer ===");
  Serial.println("Hardware: Waveshare ESP32-S3-Touch-AMOLED-1.75");
  
  // Report PSRAM status
  #ifdef BOARD_HAS_PSRAM
    if (psramFound()) {
      Serial.printf("PSRAM found: %d bytes\n", ESP.getPsramSize());
      Serial.printf("PSRAM free: %d bytes\n", ESP.getFreePsram());
    } else {
      Serial.println("WARNING: PSRAM not found!");
    }
  #else
    Serial.println("PSRAM support not enabled");
  #endif
  
  // Initialize I2C for touch and power management
  Wire.begin(TOUCH_SDA, TOUCH_SCL);
  Wire.setClock(400000);  // 400kHz I2C clock (Fast Mode)
  delay(50);  // Give I2C time to stabilize
  Serial.println("I2C initialized");
  
  // Initialize AXP2101 Power Management - CRITICAL for display power!
  Serial.println("Enabling display power via AXP2101...");
  Wire.beginTransmission(AXP2101_I2C_ADDRESS);
  if (Wire.endTransmission() == 0) {
    Serial.println("✓ AXP2101 found!");
    
    // Enable DLDO1 output (3.3V for display) - exact same as working demo
    Wire.beginTransmission(AXP2101_I2C_ADDRESS);
    Wire.write(0x90);  // DLDO1 voltage setting register
    Wire.write(0x1C);  // Set to 3.3V
    Wire.endTransmission();
    
    Wire.beginTransmission(AXP2101_I2C_ADDRESS);
    Wire.write(0x90);  // Enable DLDO1
    Wire.write(0x9C);  // Enable bit + 3.3V
    Wire.endTransmission();
    
    delay(100);  // Wait for power to stabilize
    Serial.println("✓ AXP2101 display power enabled");
  } else {
    Serial.println("✗ AXP2101 not found - display may not work!");
  }
  
  // Initialize display
  Serial.println("Initializing display...");
  gfx->begin();
  delay(100);  // Let display stabilize
  
  // Turn on display and set brightness (CRITICAL for AMOLED!)
  Serial.println("Turning on display and setting brightness...");
  gfx->displayOn();
  delay(50);
  gfx->setBrightness(255);  // Maximum brightness 0-255
  delay(50);
  
  // Clear screen for LVGL
  gfx->fillScreen(0x0000);  // BLACK
  Serial.println("Display ready for LVGL");
  
  // Initialize LVGL
  setupLVGL();
  
  // Load SquareLine Studio UI
  Serial.println("Loading UI...");
  ui_init();
  
  // Force initial UI refresh
  lv_obj_invalidate(lv_scr_act());
  lv_refr_now(NULL);
  
  Serial.println("✓ UI loaded and displayed");
  
  // Initialize BLE
  setupBLE();
  
  Serial.println("Setup complete!");
  Serial.println("Waiting for iPhone connection...");
}

// ============================================================================
// UPDATE DEVICE STATS ON UI
// ============================================================================

unsigned long lastStatsUpdate = 0;
const unsigned long STATS_UPDATE_INTERVAL = 1000;  // Update every 1 second

void updateDeviceStats() {
  unsigned long now = millis();
  
  if (now - lastStatsUpdate >= STATS_UPDATE_INTERVAL) {
    lastStatsUpdate = now;
    
    // Update Heap Memory
    if (ui_LabelHeapFree != NULL) {
      uint32_t heapFree = ESP.getFreeHeap() / 1024;  // Convert to KB
      lv_label_set_text_fmt(ui_LabelHeapFree, "Heap: %lu KB", heapFree);
    }
    
    // Update PSRAM Memory
    if (ui_LabelPSRAMFree != NULL) {
      #ifdef BOARD_HAS_PSRAM
        if (psramFound()) {
          uint32_t psramFree = ESP.getFreePsram() / 1024;  // Convert to KB
          lv_label_set_text_fmt(ui_LabelPSRAMFree, "PSRAM: %lu KB", psramFree);
        } else {
          lv_label_set_text(ui_LabelPSRAMFree, "PSRAM: N/A");
        }
      #else
        lv_label_set_text(ui_LabelPSRAMFree, "PSRAM: N/A");
      #endif
    }
  }
}

// ============================================================================
// ARDUINO MAIN LOOP
// ============================================================================

void loop() {
  // Update device stats periodically
  updateDeviceStats();
  
  // Update LVGL (handles rendering and animations)
  lv_timer_handler();
  delay(5);  // 5ms delay = ~200Hz refresh rate
}
