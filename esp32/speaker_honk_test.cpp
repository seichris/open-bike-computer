#include <Arduino.h>

#include "boot_diagnostics.hpp"
#include "i2c_bus.hpp"
#include "speaker.hpp"
#include "waveshare_board.hpp"

#include <driver/gpio.h>
#include <esp_heap_caps.h>

namespace {

using waveshare_board::speaker::Sound;

constexpr uint8_t TEST_VOLUME_PERCENT = 60;
constexpr uint32_t PLAYBACK_INTERVAL_MS = 5000;
constexpr uint32_t PLAYBACK_START_TIMEOUT_MS = 5000;
constexpr uint32_t PLAYBACK_FINISH_TIMEOUT_MS = 15000;
constexpr Sound TEST_SOUNDS[] = {
    Sound::BellDing,
    Sound::PlasticBicycleHorn,
    Sound::RotatingBicycleBell,
    Sound::SqueezeHorn,
};

size_t nextSoundIndex = 0;
size_t startupSoundsCompleted = 0;
uint32_t completedPlaybackCount = 0;
uint32_t lastPlaybackMs = 0;
uint32_t playbackRequestedMs = 0;
uint8_t currentSoundId = 0;
bool testInitialized = false;
bool testReady = false;
bool awaitingPlayback = false;
bool observedPlaybackActive = false;
uint32_t currentPlaybackRequestId = 0;

} // namespace

void setup() {
  const size_t configuredSerialTxBufferSize =
      Serial.setTxBufferSize(boot_diagnostics::kStructuredSerialTxBufferSize);
  Serial.begin(115200);
  Serial.setTxTimeoutMs(1);
  delay(1500);
  if (configuredSerialTxBufferSize !=
      boot_diagnostics::kStructuredSerialTxBufferSize) {
    Serial.printf("BOOT_DIAGNOSTICS_ERROR schema=1 operation=serial_buffer "
                  "configured=%u required=%u\n",
                  static_cast<unsigned>(configuredSerialTxBufferSize),
                  static_cast<unsigned>(
                      boot_diagnostics::kStructuredSerialTxBufferSize));
  }

  boot_diagnostics::begin();
  if (boot_diagnostics::safeModeActive()) {
    return;
  }
  boot_diagnostics::completeStage(boot_diagnostics::Stage::Startup);
  Serial.println("Waveshare AMOLED production speaker smoke test");

  boot_diagnostics::enterStage(boot_diagnostics::Stage::I2cBus);
  waveshare_board::i2c::configureBus();
  boot_diagnostics::completeStage(boot_diagnostics::Stage::I2cBus);
  boot_diagnostics::enterStage(boot_diagnostics::Stage::PmicInspection);
  waveshare_board::initializePowerManagement();
  boot_diagnostics::completeStage(boot_diagnostics::Stage::PmicInspection);
  boot_diagnostics::enterStage(boot_diagnostics::Stage::Speaker);
  if (!waveshare_board::speaker::begin()) {
    Serial.println("Speaker test: initialization failed");
    return;
  }

  Serial.printf("Speaker test: cycling sound IDs 1, 2, 3, 5 at %u%% volume\n",
                TEST_VOLUME_PERCENT);
  Serial.println(
      "Speaker test: first complete cycle must finish before boot readiness");
  lastPlaybackMs = millis() - PLAYBACK_INTERVAL_MS;
  testInitialized = true;
}

void loop() {
  if (!testInitialized) {
    delay(1000);
    return;
  }

  const uint32_t now = millis();

  if (awaitingPlayback) {
    if (waveshare_board::speaker::isPlaying()) {
      observedPlaybackActive = true;
    }

    const waveshare_board::speaker::TrackedPlaybackResult playbackResult =
        waveshare_board::speaker::classifyPlaybackCompletion(
            currentPlaybackRequestId,
            waveshare_board::speaker::latestPlaybackCompletion());
    if (playbackResult ==
        waveshare_board::speaker::TrackedPlaybackResult::Succeeded) {
      awaitingPlayback = false;
      completedPlaybackCount++;
      const int paLevel = gpio_get_level(GPIO_NUM_46);
      const size_t heapFree = heap_caps_get_free_size(MALLOC_CAP_DEFAULT);
      const size_t heapMinimum =
          heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT);
      Serial.printf(
          "SPEAKER_CYCLE schema=1 count=%lu sound=%u result=success "
          "paLevel=%d heapFree=%u heapMinimum=%u\n",
          static_cast<unsigned long>(completedPlaybackCount), currentSoundId,
          paLevel, static_cast<unsigned>(heapFree),
          static_cast<unsigned>(heapMinimum));
      if (paLevel != 0) {
        Serial.printf("BOOT_DIAGNOSTICS_ERROR schema=1 "
                      "operation=speaker_cycle phase=pa_low count=%lu "
                      "level=%d\n",
                      static_cast<unsigned long>(completedPlaybackCount),
                      paLevel);
        testInitialized = false;
      } else if (!testReady) {
        startupSoundsCompleted++;
        Serial.printf("Speaker test: startup playback %u/%u completed\n",
                      static_cast<unsigned>(startupSoundsCompleted),
                      static_cast<unsigned>(sizeof(TEST_SOUNDS) /
                                            sizeof(TEST_SOUNDS[0])));
        if (startupSoundsCompleted ==
            sizeof(TEST_SOUNDS) / sizeof(TEST_SOUNDS[0])) {
          boot_diagnostics::completeStage(boot_diagnostics::Stage::Speaker);
          boot_diagnostics::enterStage(boot_diagnostics::Stage::Finalization);
          boot_diagnostics::completeStage(
              boot_diagnostics::Stage::Finalization);
          boot_diagnostics::markReady();
          testReady = true;
          lastPlaybackMs = now;
          Serial.println("Speaker test: guarded startup cycle complete");
        }
      }
      if (testInitialized && completedPlaybackCount == 100U) {
        Serial.println("Speaker test: 100 tracked playback cycles complete");
      }
    } else if (playbackResult ==
                   waveshare_board::speaker::TrackedPlaybackResult::Failed ||
               playbackResult == waveshare_board::speaker::
                                     TrackedPlaybackResult::Superseded) {
      Serial.printf("BOOT_DIAGNOSTICS_ERROR schema=1 "
                    "operation=speaker_cycle phase=result count=%lu "
                    "sound=%u request=%lu result=%s\n",
                    static_cast<unsigned long>(completedPlaybackCount + 1U),
                    currentSoundId,
                    static_cast<unsigned long>(currentPlaybackRequestId),
                    playbackResult == waveshare_board::speaker::
                                          TrackedPlaybackResult::Failed
                        ? "failed"
                        : "superseded");
      awaitingPlayback = false;
      testInitialized = false;
    } else if (!observedPlaybackActive &&
               now - playbackRequestedMs >=
                   PLAYBACK_START_TIMEOUT_MS) {
      Serial.printf("BOOT_DIAGNOSTICS_ERROR schema=1 "
                    "operation=speaker_cycle phase=start count=%lu "
                    "sound=%u timeoutMs=%lu\n",
                    static_cast<unsigned long>(completedPlaybackCount + 1U),
                    currentSoundId,
                    static_cast<unsigned long>(
                        PLAYBACK_START_TIMEOUT_MS));
      awaitingPlayback = false;
      testInitialized = false;
    }

    if (awaitingPlayback && observedPlaybackActive &&
        now - playbackRequestedMs >= PLAYBACK_FINISH_TIMEOUT_MS) {
      Serial.printf("BOOT_DIAGNOSTICS_ERROR schema=1 "
                    "operation=speaker_cycle phase=finish count=%lu "
                    "sound=%u timeoutMs=%lu\n",
                    static_cast<unsigned long>(completedPlaybackCount + 1U),
                    currentSoundId,
                    static_cast<unsigned long>(
                        PLAYBACK_FINISH_TIMEOUT_MS));
      awaitingPlayback = false;
      testInitialized = false;
    }
    delay(20);
    return;
  }

  if (now - lastPlaybackMs < PLAYBACK_INTERVAL_MS) {
    delay(20);
    return;
  }

  const Sound sound = TEST_SOUNDS[nextSoundIndex];
  const uint8_t soundId = static_cast<uint8_t>(sound);
  uint32_t requestId = 0;
  const bool queued = waveshare_board::speaker::requestPlayTracked(
      sound, TEST_VOLUME_PERCENT, requestId);
  if (queued) {
    Serial.printf("Speaker test: queued sound ID %u\n", soundId);
    awaitingPlayback = true;
    observedPlaybackActive = false;
    playbackRequestedMs = now;
    currentSoundId = soundId;
    currentPlaybackRequestId = requestId;
  } else {
    Serial.printf("Speaker test: failed to queue sound ID %u\n", soundId);
    Serial.printf("BOOT_DIAGNOSTICS_ERROR schema=1 "
                  "operation=speaker_cycle phase=queue count=%lu sound=%u\n",
                  static_cast<unsigned long>(completedPlaybackCount + 1U),
                  soundId);
    testInitialized = false;
  }

  nextSoundIndex = (nextSoundIndex + 1) %
                   (sizeof(TEST_SOUNDS) / sizeof(TEST_SOUNDS[0]));
  lastPlaybackMs = now;
}
