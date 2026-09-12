#if defined(WAVESHARE_EPAPER_397)
#include "epaper_display.hpp"
#include "epaper_policy.hpp"
#include "frame_mailbox.hpp"
#include "ssd1677.hpp"
#include "epaper_ui.hpp"
#include "waitingScr.hpp"
#include "board_traits.hpp"
#include "../panel/WAVESHARE_EPAPER_397.hpp"
#include "../power_management/power_management.hpp"
#include "../ble_navigation/ble_navigation.hpp"
#include "../ui_scheduler/ui_scheduler.hpp"
#include <Arduino.h>
#include <driver/spi_master.h>
#include <esp_heap_caps.h>
#include <lvgl.h>
#include <algorithm>
#include <atomic>

extern lv_display_t *display; // Owned by the shared LVGL setup module.
volatile uint32_t displayFlushCount = 0, lastDisplayFlushMs = 0;
volatile uint32_t lastDisplayFlushDurationUs = 0, maxDisplayFlushDurationUs = 0;

namespace epaper {
namespace {
portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
uint8_t *desired = nullptr, *flight = nullptr, *shown = nullptr;
uint16_t *lvglBuffer = nullptr;
TaskHandle_t worker = nullptr;
FrameMailbox mailbox;
bool urgent = true;
bool sleepRequested = false, wakeRequested = false;
std::atomic<uint32_t> currentPairing{0};
std::atomic<uint32_t> currentContext{1};
#ifdef EPAPER_DISPLAY_TEST
std::atomic<bool> injectBusyFault{false};
unsigned testPattern = 0;
#endif
Status snapshot;
PresentationPolicy policy;

class Transport {
public:
  bool begin() {
    using namespace board_traits;
    pinMode(epdReset, OUTPUT);
    pinMode(epdDc, OUTPUT);
    pinMode(epdBusy, INPUT);
    digitalWrite(epdReset, HIGH);
    spi_bus_config_t bus{};
    bus.mosi_io_num = epdMosi;
    bus.miso_io_num = -1;
    bus.sclk_io_num = epdClock;
    bus.quadwp_io_num = -1;
    bus.quadhd_io_num = -1;
    bus.max_transfer_sz = sizeof(staging_);
    if (spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK)
      return false;
    spi_device_interface_config_t config{};
    config.clock_speed_hz = 4000000;
    config.mode = 0;
    config.spics_io_num = epdCs;
    config.queue_size = 1;
    return spi_bus_add_device(SPI2_HOST, &config, &device_) == ESP_OK;
  }
  void reset() {
    digitalWrite(board_traits::epdReset, HIGH); delay(20);
    digitalWrite(board_traits::epdReset, LOW); delay(2);
    digitalWrite(board_traits::epdReset, HIGH); delay(20);
  }
  bool waitReady(uint32_t timeout) {
    const uint32_t start = millis();
    while (digitalRead(board_traits::epdBusy) == HIGH) {
      if (uint32_t(millis() - start) >= timeout) return false;
      delay(10);
    }
    return true;
  }
  bool waitWaveform(uint32_t timeout) {
#ifdef EPAPER_DISPLAY_TEST
    if (injectBusyFault.load()) { delay(timeout); return false; }
#endif
    // Observe both edges. A disconnected/stuck-low BUSY wire cannot attest a
    // visible comparison code merely because an SPI transaction completed.
    const uint32_t start = millis();
    while (digitalRead(board_traits::epdBusy) == LOW) {
      if (uint32_t(millis() - start) >= 500) return false;
      delay(1);
    }
    return waitReady(timeout);
  }
  bool write(bool data, const uint8_t *bytes, size_t count) {
    digitalWrite(board_traits::epdDc, data ? HIGH : LOW);
    while (count) {
      const size_t chunk = std::min(count, sizeof(staging_));
      std::memcpy(staging_, bytes, chunk);
      spi_transaction_t transaction{};
      transaction.length = chunk * 8;
      transaction.tx_buffer = staging_;
      // Only this task owns the SPI device and internal DMA staging buffer.
      if (spi_device_transmit(device_, &transaction) != ESP_OK) return false;
      bytes += chunk;
      count -= chunk;
    }
    return true;
  }
  void yield() { delay(1); }
private:
  spi_device_handle_t device_ = nullptr;
  alignas(4) uint8_t staging_[512]{};
};
Transport transport;

void displayWorker(void *) {
  Ssd1677<Transport> panel(transport);
  if (!transport.begin()) {
    portENTER_CRITICAL(&mux); snapshot.fault = true; portEXIT_CRITICAL(&mux);
    for (;;) ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
  }
  for (;;) {
    ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(20));
    portENTER_CRITICAL(&mux);
    const bool shouldSleep = sleepRequested;
    const bool shouldWake = wakeRequested;
    sleepRequested = wakeRequested = false;
    portEXIT_CRITICAL(&mux);
    if (shouldSleep) {
      panel.sleep();
      policy.sleep();
      portENTER_CRITICAL(&mux);
      snapshot.sleeping = true; snapshot.pairingGeneration = 0;
      portEXIT_CRITICAL(&mux);
    }
    if (shouldWake) {
      policy.wake();
      portENTER_CRITICAL(&mux);
      snapshot.sleeping = false; snapshot.fault = false;
      portEXIT_CRITICAL(&mux);
    }
    uint32_t generation = 0, pairing = 0, context = 0;
    const uint32_t now = millis();
    portENTER_CRITICAL(&mux);
    if (policy.ready(now, urgent)) {
      const auto frame = mailbox.claim();
      if (frame.pixels) {
        flight = frame.pixels;
        generation = frame.generation; pairing = frame.pairing;
        context = frame.context;
        urgent = false; snapshot.busy = true;
      }
    }
    portEXIT_CRITICAL(&mux);
    if (!generation) continue;
    // Discard a queued old comparison before touching the panel.
    if (pairing != currentPairing.load() || context != currentContext.load()) {
      portENTER_CRITICAL(&mux);
      snapshot.busy = false; ++snapshot.discarded; mailbox.finish(false);
      portEXIT_CRITICAL(&mux);
      continue;
    }
    Window dirty = dirtyWindow(flight, mailbox.shown());
    bool full = policy.fullRequired(now);
    bool ok = true;
    if (full || !dirty.empty()) {
      power_management::ScopedLock powerLock(power_management::LockDomain::Display);
      for (uint8_t attempt = 0; attempt < 2; ++attempt) {
        policy.start();
        portENTER_CRITICAL(&mux);
        snapshot.transmitted = generation;
        portEXIT_CRITICAL(&mux);
        ok = panel.present(flight, full ? Window{0, 0, width, height} : dirty, full);
        if (ok) break;
        portENTER_CRITICAL(&mux); ++snapshot.failures; portEXIT_CRITICAL(&mux);
        if (!policy.fail()) break;
        full = true; // Controller/base history is now uncertain.
      }
      if (ok) { policy.complete(millis(), full); policy.recovered(); }
    }
    portENTER_CRITICAL(&mux);
    snapshot.busy = false;
    snapshot.fault = !ok;
    if (ok) {
      mailbox.finish(true);
      snapshot.presented = generation;
      snapshot.completedAtMs = millis();
      snapshot.context = context;
      snapshot.pairingGeneration = pairing == currentPairing.load() &&
          context == currentContext.load() ? pairing : 0;
      if (full) ++snapshot.fullCount;
      else if (!dirty.empty()) ++snapshot.partialCount;
    } else {
      mailbox.finish(false);
      snapshot.pairingGeneration = 0;
    }
    portEXIT_CRITICAL(&mux);
    ui_scheduler::notify(ui_scheduler::WakeReason::Display);
  }
}
} // namespace

void begin() {
  if (desired) return;
  desired = static_cast<uint8_t *>(heap_caps_malloc(frameBytes, MALLOC_CAP_SPIRAM));
  flight = static_cast<uint8_t *>(heap_caps_malloc(frameBytes, MALLOC_CAP_SPIRAM));
  shown = static_cast<uint8_t *>(heap_caps_malloc(frameBytes, MALLOC_CAP_SPIRAM));
  if (!desired || !flight || !shown) std::abort();
  std::memset(shown, 0xFF, frameBytes);
  mailbox.bind(desired, flight, shown);
  if (xTaskCreatePinnedToCore(displayWorker, "epaper", 4096, nullptr, 1,
                              &worker, 0) != pdPASS) std::abort();
}

bool submit(const uint16_t *rgb) {
  if (!rgb || !desired) return false;
  portENTER_CRITICAL(&mux);
  uint8_t *target = mailbox.beginWrite();
  portEXIT_CRITICAL(&mux);
  if (!target) return false;
  packPortrait(rgb, target);
  uint32_t pairing = isWaitingPairingComparisonVisible() ? currentPairing.load() : 0;
#ifdef EPAPER_DISPLAY_TEST
  // Pattern 4 shows the ordinary monochrome UI (text/QR). Diagnostic patterns
  // never attest pairing, even if the underlying LVGL screen contains a code.
  pairing = 0;
  if (testPattern < 4) {
    for (uint16_t y = 0; y < height; ++y)
      for (uint16_t x = 0; x < stride; ++x) {
        target[size_t(y) * stride + x] = testPattern == 0 ? 0xFF :
            testPattern == 1 ? 0x00 : testPattern == 2 ?
            ((y / 8 + x) % 2 ? 0xAA : 0x55) :
            (y == 0 || y == height - 1 ? 0 : x == 0 ? 0x7F :
             x == stride - 1 ? 0xFE : 0xFF);
      }
  }
#endif
  portENTER_CRITICAL(&mux);
  snapshot.queued = mailbox.publish(pairing, currentContext.load());
  portEXIT_CRITICAL(&mux);
  xTaskNotifyGive(worker);
  return true;
}

Status status() {
  portENTER_CRITICAL(&mux); const Status value = snapshot; portEXIT_CRITICAL(&mux);
  return value;
}
void prioritize() {
  portENTER_CRITICAL(&mux); urgent = true; portEXIT_CRITICAL(&mux);
}
void invalidateContext() {
  ++currentContext;
  prioritize();
}
void setPairingGeneration(uint32_t generation) {
  if (currentPairing.exchange(generation) != generation) invalidateContext();
}
uint32_t pairingGeneration() { return currentPairing.load(); }
bool pairingPresented() {
  const Status s = status();
  return currentPairing.load() != 0 && !s.fault && !s.sleeping && !s.busy &&
         s.pairingGeneration == currentPairing.load() &&
         s.context == currentContext.load();
}
void sleep() {
  invalidateContext();
  portENTER_CRITICAL(&mux);
  sleepRequested = true; snapshot.pairingGeneration = 0; snapshot.sleeping = true;
  portEXIT_CRITICAL(&mux);
  if (worker) xTaskNotifyGive(worker);
}
void wake() {
  invalidateContext();
  portENTER_CRITICAL(&mux); wakeRequested = true; urgent = true; portEXIT_CRITICAL(&mux);
  if (worker) xTaskNotifyGive(worker);
}
#ifdef EPAPER_DISPLAY_TEST
void diagnosticPattern(int delta) {
  testPattern = (testPattern + 5 + delta) % 5;
  invalidateContext();
  lv_obj_invalidate(lv_screen_active());
  Serial.printf("EPAPER_TEST pattern=%u (white,black,checker,edges,UI)\n", testPattern);
}
void diagnosticFault(bool enabled) {
  injectBusyFault.store(enabled);
  if (!enabled) wake();
  lv_obj_invalidate(lv_screen_active());
  prioritize();
  Serial.printf("EPAPER_TEST busyFault=%d\n", enabled);
}
#endif
void poll() {
  static uint32_t delivered = 0;
  static uint32_t failures = 0;
  const Status s = status();
  if (s.failures != failures) {
    failures = s.failures;
    Serial.printf("EPAPER_FAULT failures=%lu latched=%d transmitted=%lu\n",
        (unsigned long)s.failures, s.fault, (unsigned long)s.transmitted);
  }
  if (s.presented == delivered) return;
  delivered = s.presented;
  Serial.printf("EPAPER_PRESENT generation=%lu context=%lu pairing=%lu full=%lu partial=%lu ms=%lu\n",
      (unsigned long)s.presented, (unsigned long)s.context,
      (unsigned long)s.pairingGeneration, (unsigned long)s.fullCount,
      (unsigned long)s.partialCount, (unsigned long)s.completedAtMs);
  ++displayFlushCount;
  lastDisplayFlushMs = s.completedAtMs;
  if (pairingPresented())
    bleNavServer.noteOwnershipDisplayGenerationCompleted(s.pairingGeneration);
}
} // namespace epaper

void setupDisplay() { epaper::begin(); }
bool hasFullScreenRgb565Buffer() { return epaper::lvglBuffer != nullptr; }
void setupLVGLforArduinoGFX() {
  lv_init();
  display = lv_display_create(SCREEN_WIDTH, SCREEN_HEIGHT);
  epaper::lvglBuffer = static_cast<uint16_t *>(heap_caps_aligned_alloc(
      16, epaper::rgbBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (!display || !epaper::lvglBuffer) std::abort();
  lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
  lv_display_set_buffers(display, epaper::lvglBuffer, nullptr,
                         epaper::rgbBytes, LV_DISPLAY_RENDER_MODE_FULL);
  lv_display_add_event_cb(display, [](lv_event_t *) { epaper_ui::prepareFrame(); },
                           LV_EVENT_REFR_START, nullptr);
  lv_display_set_flush_cb(display, [](lv_display_t *d, const lv_area_t *, uint8_t *pixels) {
    const uint32_t started = micros();
    epaper::submit(reinterpret_cast<const uint16_t *>(pixels));
    lastDisplayFlushDurationUs = micros() - started;
    maxDisplayFlushDurationUs = std::max(uint32_t(maxDisplayFlushDurationUs),
                                        uint32_t(lastDisplayFlushDurationUs));
    // The worker owns packed copies. This does not mean the glass is updated.
    lv_display_flush_ready(d);
  });
}
#endif
