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
#include <Arduino_GFX_Library.h>
#include <NimBLEDevice.h>
#include "navigation_payload_queue.h"
#include "navigation_protocol.h"
#include <SD.h>
#include <SPI.h>
#include <Wire.h>
#include <driver/gpio.h>
#include <lvgl.h>

// Include SquareLine Studio generated UI
extern "C" {
#include "ui.h"
}

// ============================================================================
// HARDWARE PIN DEFINITIONS
// ============================================================================

// QSPI Display Pins (CO5300)
#define TFT_CS 12
#define TFT_CLK 38
#define TFT_D0 4
#define TFT_D1 5
#define TFT_D2 6
#define TFT_D3 7
#define TFT_RST 39

// I2C Touch Pins (CST9217)
#define TOUCH_SDA 15
#define TOUCH_SCL 14
#define TOUCH_INT 21 // Updated from -1

// I2C Expander (TCA9554)
#define TCA9554_I2C_ADDRESS 0x20

// Power Management (AXP2101)
#define AXP2101_I2C_ADDRESS 0x34

// Display Specifications
#define SCREEN_WIDTH 466
#define SCREEN_HEIGHT 466

// SD Card Pins (Waveshare ESP32-S3-Touch-AMOLED-1.75) - VERIFIED SPI
#define SD_SCK 2
#define SD_MOSI 1
#define SD_MISO 3
#define SD_CS 41

// ============================================================================
// DISPLAY DRIVER SETUP (Arduino_GFX)
// ============================================================================

// QSPI Bus for CO5300
Arduino_ESP32QSPI *bus = new Arduino_ESP32QSPI(TFT_CS,  // CS
                                               TFT_CLK, // SCK
                                               TFT_D0,  // D0
                                               TFT_D1,  // D1
                                               TFT_D2,  // D2
                                               TFT_D3   // D3
);

// CO5300 Display Driver - Use minimal constructor like working demo
Arduino_CO5300 *gfx = new Arduino_CO5300(bus,
                                         TFT_RST, // RST
                                         0        // Rotation only
);

// ============================================================================
// LVGL DISPLAY BUFFER
// ============================================================================

static lv_disp_draw_buf_t draw_buf;
static lv_color_t *disp_draw_buf;
static lv_disp_drv_t disp_drv;

// ============================================================================
// LVGL DISPLAY FLUSH CALLBACK
// Using full screen buffer to prevent partial update artifacts on AMOLED
// ============================================================================

// Mutex for display access
// Mutex for display access not needed with thread-safe approach

void my_disp_flush(lv_disp_drv_t *disp, const lv_area_t *area,
                   lv_color_t *color_p) {
  if (area->x1 < 0 || area->y1 < 0 || area->x2 < area->x1 ||
      area->y2 < area->y1 || area->x2 >= SCREEN_WIDTH ||
      area->y2 >= SCREEN_HEIGHT) {
    lv_disp_flush_ready(disp);
    return;
  }

  uint32_t w = (uint32_t)(area->x2 - area->x1 + 1);
  uint32_t h = (uint32_t)(area->y2 - area->y1 + 1);

  // Add bounds checking to prevent corruption
  if (w == 0 || h == 0 || w > SCREEN_WIDTH || h > SCREEN_HEIGHT) {
    lv_disp_flush_ready(disp);
    return;
  }

  // Use startWrite/endWrite with proper synchronization
  gfx->startWrite();
  gfx->setAddrWindow(area->x1, area->y1, w, h);
  gfx->writePixels((uint16_t *)color_p, w * h);
  gfx->endWrite();

  // Minimal delay - full screen buffer ensures complete frame writes
  delayMicroseconds(50);

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
  // Reset sequence for touch is handled by TCA9554 in setup()

  // Try to read touch data with error handling
  Wire.beginTransmission(CST9217_ADDRESS);
  Wire.write(0x00); // Register address for touch data
  uint8_t error = Wire.endTransmission(false);

  if (error != 0) {
    touchPressed = false;
    return;
  }

  // Request 13 bytes of touch data
  uint8_t bytesReceived =
      Wire.requestFrom((uint8_t)CST9217_ADDRESS, (uint8_t)13, (uint8_t)true);

  if (bytesReceived >= 7) {
    uint8_t data[13];
    for (int i = 0; i < bytesReceived && i < 13; i++) {
      data[i] = Wire.read();
    }

    // Parse touch data (CST9217 format)
    uint8_t touchPoints = data[2] & 0x0F;
    if (touchPoints > 0) {
      // Extract raw coordinates (12-bit values)
      uint16_t rawX = ((data[3] & 0x0F) << 8) | data[4];
      uint16_t rawY = ((data[5] & 0x0F) << 8) | data[6];

      // Scale and mirror coordinates if necessary
      // Verified: 466x466 resolution
      touchX = rawX;
      touchY = rawY;

      // Clamp to screen bounds
      if (touchX >= SCREEN_WIDTH)
        touchX = SCREEN_WIDTH - 1;
      if (touchY >= SCREEN_HEIGHT)
        touchY = SCREEN_HEIGHT - 1;

      touchPressed = true;
    } else {
      touchPressed = false;
    }
  } else {
    touchPressed = false;
  }
}

void my_touchpad_read(lv_indev_drv_t *indev_driver, lv_indev_data_t *data) {
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

#define SERVICE_UUID "1819"        // Navigation Service
#define CHARACTERISTIC_UUID "2A6E" // Navigation Data Characteristic

NimBLEServer *pServer = nullptr;
NimBLECharacteristic *pCharacteristic = nullptr;
bool deviceConnected = false;

NavigationData navData = {1, 0, ""};
volatile bool uiUpdateNeeded = false;
volatile bool bleConnectedState = false;
volatile bool bleStateChanged = false;
portMUX_TYPE navPayloadMux = portMUX_INITIALIZER_UNLOCKED;
NavigationPayloadQueue navPayloadQueue;

// BLE Callbacks
class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *pServer) {
    deviceConnected = true;
    bleConnectedState = true;
    bleStateChanged = true;
    Serial.println("BLE: Client connected");
  }

  void onDisconnect(NimBLEServer *pServer) {
    deviceConnected = false;
    bleConnectedState = false;
    bleStateChanged = true;
    Serial.println("BLE: Client disconnected");
    // Restart advertising
    NimBLEDevice::startAdvertising();
  }
};

void queueNavigationPayload(const std::string &value) {
  if (value.empty()) {
    return;
  }

  if (value.length() > NAV_PAYLOAD_MAX_LEN) {
    Serial.printf("Rejected navigation payload: %u bytes exceeds %u byte limit\n",
                  (unsigned)value.length(), (unsigned)NAV_PAYLOAD_MAX_LEN);
    return;
  }

  portENTER_CRITICAL(&navPayloadMux);
  navPayloadQueue.enqueue(value);
  portEXIT_CRITICAL(&navPayloadMux);
}

void processPendingNavigationPayload() {
  char payload[NAV_PAYLOAD_MAX_LEN + 1];

  portENTER_CRITICAL(&navPayloadMux);
  bool hasPayload = navPayloadQueue.dequeue(payload, sizeof(payload));
  portEXIT_CRITICAL(&navPayloadMux);
  if (!hasPayload) {
    return;
  }

  NavigationData parsed;
  if (!parseNavigationData(payload, &parsed)) {
    Serial.println("Invalid navigation payload: expected IconID|Distance|Instruction with unsigned numeric fields");
    return;
  }

  navData = parsed;

  Serial.printf("Parsed: Icon=%u, Distance=%lum, Instruction=%s\n",
                navData.iconID, (unsigned long)navData.distance, navData.instruction);

  uiUpdateNeeded = true;
}

// Update UI safely from main loop
void updateNavigationUI() {
  if (bleStateChanged) {
    bleStateChanged = false;
    if (ui_LabelBLEStatus != NULL) {
      if (bleConnectedState) {
        lv_label_set_text(ui_LabelBLEStatus, "BLE: Connected");
        lv_obj_set_style_text_color(
            ui_LabelBLEStatus, lv_color_hex(0x4CAF50),
            (lv_style_selector_t)(LV_PART_MAIN | LV_STATE_DEFAULT));
      } else {
        lv_label_set_text(ui_LabelBLEStatus, "BLE: Disconnected");
        lv_obj_set_style_text_color(
            ui_LabelBLEStatus, lv_color_hex(0xFF6B6B),
            (lv_style_selector_t)(LV_PART_MAIN | LV_STATE_DEFAULT));
      }
    }
  }

  if (uiUpdateNeeded) {
    uiUpdateNeeded = false;

    if (ui_LabelDistance != NULL) {
      lv_label_set_text_fmt(ui_LabelDistance, "%lu m", (unsigned long)navData.distance);
    }
    if (ui_LabelInstruction != NULL) {
      lv_label_set_text(ui_LabelInstruction, navData.instruction);
    }
    if (ui_IconPlaceholder != NULL) {
      // Draw arrow shapes based on iconID
      lv_color_t arrow_color;

      switch (navData.iconID) {
      case 1:                                 // Continue (straight ahead)
        arrow_color = lv_color_hex(0x4CAF50); // Green
        draw_up_arrow(arrow_color);
        break;
      case 2:                                 // Turn Left
        arrow_color = lv_color_hex(0xFFC107); // Yellow
        draw_left_arrow(arrow_color);
        break;
      case 3:                                 // Turn Right
        arrow_color = lv_color_hex(0xFF9800); // Orange
        draw_right_arrow(arrow_color);
        break;
      case 4:                                 // U-Turn
        arrow_color = lv_color_hex(0xF44336); // Red
        draw_u_turn_arrow(arrow_color);
        break;
      default:
        arrow_color = lv_color_hex(0x4CAF50); // Green
        draw_up_arrow(arrow_color);
        break;
      }
    }
  }
}

class CharacteristicCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *pCharacteristic) {
    std::string value = pCharacteristic->getValue();
    if (value.length() > 0) {
      Serial.printf("Received navigation payload: %u bytes\n", (unsigned)value.length());
      queueNavigationPayload(value);
    }
  }
};

void setupBLE() {
  Serial.println("Initializing BLE...");

  NimBLEDevice::init("BikeComputer");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9); // Maximum power

  // Create BLE Server
  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  // Create Service
  NimBLEService *pService = pServer->createService(SERVICE_UUID);

  // Create Characteristic (WRITE WITHOUT RESPONSE for better performance)
  pCharacteristic = pService->createCharacteristic(CHARACTERISTIC_UUID,
                                                   NIMBLE_PROPERTY::WRITE_NR);

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

// Global variable to track SD mode
enum SDMode { SD_NONE, SD_SPI };
SDMode currentSDMode = SD_NONE;

SPIClass SD_SPI_BUS(HSPI); // Use HSPI to avoid QSPI display conflict

bool initSDCard() {
  Serial.println("Initializing SD card (SPI mode)...");

  // Pins for SPI SD Card: CS=41, MOSI=1, MISO=3, SCK=2
  SD_SPI_BUS.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);

  if (SD.begin(SD_CS, SD_SPI_BUS, 4000000, "/sdcard")) {
    Serial.println("✓ SD card initialized in SPI mode");
    currentSDMode = SD_SPI;

    uint8_t cardType = SD.cardType();
    Serial.print("SD Card Type: ");
    if (cardType == CARD_MMC) {
      Serial.println("MMC");
    } else if (cardType == CARD_SD) {
      Serial.println("SD");
    } else if (cardType == CARD_SDHC) {
      Serial.println("SDHC");
    } else {
      Serial.println("UNKNOWN");
    }

    uint64_t cardSize = SD.cardSize() / (1024 * 1024);
    Serial.printf("SD Card Size: %llu MB\n", cardSize);
    return true;
  } else {
    Serial.println("❌ SD card initialization failed!");
    currentSDMode = SD_NONE;
    return false;
  }
}

bool readFileFromSD(const char *filename) {
  Serial.printf("Reading file: %s\n", filename);

  File file = SD.open(filename);
  if (!file) {
    Serial.printf("Failed to open file: %s\n", filename);
    return false;
  }

  Serial.printf("File size: %d bytes\n", file.size());
  Serial.println("File contents:");

  while (file.available()) {
    String line = file.readStringUntil('\n');
    Serial.println(line);
  }

  file.close();
  Serial.println("File read complete.");
  return true;
}

void listSDFiles() {
  Serial.println("Listing SD card root directory:");

  File root = SD.open("/");
  if (!root) {
    Serial.println("Failed to open root directory");
    return;
  }

  File file = root.openNextFile();
  while (file) {
    if (file.isDirectory()) {
      Serial.print("  DIR : ");
      Serial.println(file.name());
    } else {
      Serial.print("  FILE: ");
      Serial.print(file.name());
      Serial.print("  SIZE: ");
      Serial.println(file.size());
    }
    file.close();
    file = root.openNextFile();
  }
  root.close();
}

// ============================================================================
// LVGL INITIALIZATION
// ============================================================================

void setupLVGL() {
  Serial.println("Initializing LVGL...");

  lv_init();

  // Allocate FULL SCREEN buffer from PSRAM to enable true full_refresh mode
  // This eliminates ALL partial updates and prevents diagonal digit corruption
  uint32_t bufSize = SCREEN_WIDTH * SCREEN_HEIGHT;
  Serial.printf("Allocating LVGL buffer: %d bytes (FULL SCREEN)\n",
                bufSize * sizeof(lv_color_t));

#ifdef BOARD_HAS_PSRAM
  // Use PSRAM (8MB available) with proper alignment for full screen buffer
  disp_draw_buf = (lv_color_t *)heap_caps_aligned_alloc(
      8, bufSize * sizeof(lv_color_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!disp_draw_buf) {
    Serial.println("ERROR: PSRAM allocation failed!");
    // Don't fallback to internal RAM - it's too small for full screen
    while (1)
      delay(1000); // Halt - this is fatal
  }
  Serial.println("✓ Using PSRAM for display buffer");
#else
  Serial.println("ERROR: PSRAM required for full screen buffer!");
  while (1)
    delay(1000); // Halt - this is fatal
#endif

  Serial.printf("✓ LVGL buffer allocated: %d bytes (aligned, full screen)\n",
                bufSize * sizeof(lv_color_t));

  // Initialize draw buffer
  lv_disp_draw_buf_init(&draw_buf, disp_draw_buf, NULL, bufSize);

  // Initialize display driver with optimizations for AMOLED
  lv_disp_drv_init(&disp_drv);
  disp_drv.hor_res = SCREEN_WIDTH;
  disp_drv.ver_res = SCREEN_HEIGHT;
  disp_drv.flush_cb = my_disp_flush;
  disp_drv.draw_buf = &draw_buf;
  disp_drv.full_refresh =
      1; // Force full refresh to prevent partial update corruption
  disp_drv.direct_mode = 0; // Use buffered mode for stability

  lv_disp_t *disp = lv_disp_drv_register(&disp_drv);

  if (disp == NULL) {
    Serial.println("ERROR: Display driver registration failed!");
    while (1)
      delay(1000); // Halt - this is fatal
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
  // I2C Recovery: Clock out any stuck transactions
  pinMode(TOUCH_SCL, OUTPUT);
  for (int i = 0; i < 16; i++) {
    digitalWrite(TOUCH_SCL, LOW);
    delayMicroseconds(5);
    digitalWrite(TOUCH_SCL, HIGH);
    delayMicroseconds(5);
  }

  Wire.begin(TOUCH_SDA, TOUCH_SCL);
  Wire.setClock(100000); // Use 100kHz for better stability with CST9217
  delay(50);             // Give I2C time to stabilize
  Serial.println("I2C initialized");

  // Initialize AXP2101 Power Management - CRITICAL for display power!
  Serial.println("Enabling display power via AXP2101...");
  Wire.beginTransmission(AXP2101_I2C_ADDRESS);
  if (Wire.endTransmission() == 0) {
    Serial.println("✓ AXP2101 found!");

    // Set DLDO1 voltage to 3.3V
    Wire.beginTransmission(AXP2101_I2C_ADDRESS);
    Wire.write(0x99); // DLDO1 voltage register
    Wire.write(0x1C); // 3.3V
    Wire.endTransmission();
    delay(10);

    // Enable DLDO1
    Wire.beginTransmission(AXP2101_I2C_ADDRESS);
    Wire.write(0x90); // LDO on/off control register
    Wire.write(0x02); // Enable DLDO1
    Wire.endTransmission();

    // Power cycle ALDO/BLDO sequences from verified port
    for (uint8_t reg : {0x92, 0x93, 0x94, 0x95, 0x96, 0x97}) {
      Wire.beginTransmission(AXP2101_I2C_ADDRESS);
      Wire.write(reg);
      Wire.write(0x00); // Disable
      Wire.endTransmission();
      delay(5);
      Wire.beginTransmission(AXP2101_I2C_ADDRESS);
      Wire.write(reg);
      Wire.write(0x1F); // Enable max
      Wire.endTransmission();
    }

    delay(150); // Wait for power to stabilize
    Serial.println("✓ AXP2101 display power enabled");
  } else {
    Serial.println("✗ AXP2101 not found - display may not work!");
  }

  // Initialize TCA9554 GPIO Expander for Touch Reset
  Serial.println("Initializing TCA9554 GPIO Expander...");
  Wire.beginTransmission(TCA9554_I2C_ADDRESS);
  if (Wire.endTransmission() == 0) {
    Serial.println("✓ TCA9554 found!");

    // Configure P0 as Output (Touch RST)
    Wire.beginTransmission(TCA9554_I2C_ADDRESS);
    Wire.write(0x03); // Config register
    Wire.write(0x00); // All pins as output
    Wire.endTransmission();

    // Reset sequence for touch
    Wire.beginTransmission(TCA9554_I2C_ADDRESS);
    Wire.write(0x01); // Output port register
    Wire.write(0x00); // All pins LOW
    Wire.endTransmission();
    delay(20);

    Wire.beginTransmission(TCA9554_I2C_ADDRESS);
    Wire.write(0x01);
    Wire.write(0x01); // P0 HIGH
    Wire.endTransmission();
    delay(50);
    Serial.println("✓ Touch controller reset complete");
  } else {
    Serial.println("✗ TCA9554 not found!");
  }

  // Initialize display
  Serial.println("Initializing display...");
  gfx->begin();
  delay(100); // Let display stabilize

  // Turn on display and set brightness (CRITICAL for AMOLED!)
  Serial.println("Turning on display and setting brightness...");
  gfx->displayOn();
  delay(50);
  gfx->setBrightness(DEFAULT_DISPLAY_BRIGHTNESS);
  delay(50);

  // Clear screen for LVGL
  gfx->fillScreen(0x0000); // BLACK
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

  // Initialize SD card
  if (initSDCard()) {
    // List files on SD card
    listSDFiles();

    // Try to read a test file if it exists
    bool testFileExists = SD.exists("/test.txt");

    if (testFileExists) {
      readFileFromSD("/test.txt");
    } else {
      Serial.println(
          "Note: Create a 'test.txt' file on the SD card to test file reading");
    }
  } else {
    Serial.println(
        "SD card not available - continuing without SD functionality");
  }

  Serial.println("Setup complete!");
  Serial.println("Waiting for iPhone connection...");
}

// ============================================================================
// UPDATE DEVICE STATS ON UI
// ============================================================================

unsigned long lastStatsUpdate = 0;
const unsigned long STATS_UPDATE_INTERVAL =
    2000; // Update every 2 seconds (reduced from 1s)

// SD Card - Commented out
// unsigned long lastSDDemo = 0;
// const unsigned long SD_DEMO_INTERVAL = 10000;  // Demo SD reading every 10
// seconds

unsigned long lastDisplayKeepAlive = 0;
const unsigned long DISPLAY_KEEPALIVE_INTERVAL =
    30000; // Refresh display every 30 seconds

void keepDisplayAlive() {
  unsigned long now = millis();

  if (now - lastDisplayKeepAlive >= DISPLAY_KEEPALIVE_INTERVAL) {
    lastDisplayKeepAlive = now;

    // Ensure display stays on
    gfx->displayOn();
  }
}

void updateDeviceStats() {
#if ENABLE_DEBUG_STATS
  unsigned long now = millis();
  static uint32_t lastHeapFree = UINT32_MAX;
  static uint32_t lastPsramFree = UINT32_MAX;
  static bool lastPsramAvailable = true;

  if (now - lastStatsUpdate >= STATS_UPDATE_INTERVAL) {
    lastStatsUpdate = now;

    // Update Heap Memory
    if (ui_LabelHeapFree != NULL) {
      uint32_t heapFree = ESP.getFreeHeap() / 1024; // Convert to KB
      if (heapFree != lastHeapFree) {
        lastHeapFree = heapFree;
        lv_label_set_text_fmt(ui_LabelHeapFree, "Heap: %lu KB", heapFree);
      }
    }

    // Update PSRAM Memory
    if (ui_LabelPSRAMFree != NULL) {
#ifdef BOARD_HAS_PSRAM
      if (psramFound()) {
        uint32_t psramFree = ESP.getFreePsram() / 1024; // Convert to KB
        if (!lastPsramAvailable || psramFree != lastPsramFree) {
          lastPsramAvailable = true;
          lastPsramFree = psramFree;
          lv_label_set_text_fmt(ui_LabelPSRAMFree, "PSRAM: %lu KB", psramFree);
        }
      } else {
        if (lastPsramAvailable) {
          lastPsramAvailable = false;
          lv_label_set_text(ui_LabelPSRAMFree, "PSRAM: N/A");
        }
      }
#else
      if (lastPsramAvailable) {
        lastPsramAvailable = false;
        lv_label_set_text(ui_LabelPSRAMFree, "PSRAM: N/A");
      }
#endif
    }
  }
#else
  static bool debugLabelsHidden = false;
  if (debugLabelsHidden) {
    return;
  }
  if (ui_LabelHeapFree != NULL) {
    lv_obj_add_flag(ui_LabelHeapFree, LV_OBJ_FLAG_HIDDEN);
  }
  if (ui_LabelPSRAMFree != NULL) {
    lv_obj_add_flag(ui_LabelPSRAMFree, LV_OBJ_FLAG_HIDDEN);
  }
  debugLabelsHidden = true;
#endif
}

void demoSDCardReading() {
#if ENABLE_SD_DEMO
  unsigned long now = millis();
  static unsigned long lastSDDemo = 0;
  const unsigned long SD_DEMO_INTERVAL =
      10000; // Demo SD reading every 10 seconds

  if (now - lastSDDemo >= SD_DEMO_INTERVAL) {
    lastSDDemo = now;

    // Only demo if SD card is available
    if (currentSDMode != SD_NONE) {
      Serial.println("\n=== SD Card Demo ===");

      // Check for different demo files
      const char *demoFiles[] = {"/demo.txt", "/test.txt", "/README.txt"};
      bool foundFile = false;

      for (const char *filename : demoFiles) {
        if (SD.exists(filename)) {
          Serial.printf("Found demo file: %s\n", filename);
          readFileFromSD(filename);
          foundFile = true;
          break;
        }
      }

      if (!foundFile) {
        Serial.println(
            "No demo files found. Create one of these files on your SD card:");
        for (const char *filename : demoFiles) {
          Serial.printf("  %s\n", filename);
        }
      }

      Serial.println("=== End SD Demo ===\n");
    }
  }
#endif
}

// ============================================================================
// ARDUINO MAIN LOOP
// ============================================================================

void loop() {
  // Keep display alive to prevent timeout
  keepDisplayAlive();

  // Update device stats periodically
  updateDeviceStats();

  // Update UI from Main Loop (Thread Safe)
  processPendingNavigationPayload();
  updateNavigationUI();

  // Demo SD card file reading periodically
  demoSDCardReading();

  // Update LVGL (handles rendering and animations)
  // With full screen buffer and full_refresh, we can handle updates more
  // efficiently
  lv_timer_handler();

  // Moderate delay for display stability - ~100Hz refresh
  // Full screen buffer eliminates partial update corruption
  delay(10);
}
