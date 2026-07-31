#include <Arduino.h>

#include "i2c_bus.hpp"
#include "speaker.hpp"
#include "waveshare_board.hpp"

namespace {

using waveshare_board::speaker::Sound;

constexpr uint8_t TEST_VOLUME_PERCENT = 60;
constexpr uint32_t PLAYBACK_INTERVAL_MS = 5000;
constexpr Sound TEST_SOUNDS[] = {
    Sound::BellDing,
    Sound::PlasticBicycleHorn,
    Sound::RotatingBicycleBell,
    Sound::SqueezeHorn,
};

size_t nextSoundIndex = 0;
uint32_t lastPlaybackMs = 0;

} // namespace

void setup() {
  Serial.begin(115200);
  Serial.setTxTimeoutMs(1);
  delay(1500);
  Serial.println("Waveshare AMOLED production speaker smoke test");

  waveshare_board::i2c::configureBus();
#ifdef WAVESHARE_AMOLED_175
  waveshare_board::initializePowerManagement();
#endif
  if (!waveshare_board::speaker::begin()) {
    Serial.println("Speaker test: initialization failed");
    return;
  }

  Serial.printf("Speaker test: cycling sound IDs 1, 2, 3, 5 at %u%% volume\n",
                TEST_VOLUME_PERCENT);
  lastPlaybackMs = millis() - PLAYBACK_INTERVAL_MS;
}

void loop() {
  const uint32_t now = millis();
  if (now - lastPlaybackMs < PLAYBACK_INTERVAL_MS) {
    delay(20);
    return;
  }

  const Sound sound = TEST_SOUNDS[nextSoundIndex];
  const uint8_t soundId = static_cast<uint8_t>(sound);
  if (waveshare_board::speaker::requestPlay(sound, TEST_VOLUME_PERCENT)) {
    Serial.printf("Speaker test: queued sound ID %u\n", soundId);
  } else {
    Serial.printf("Speaker test: failed to queue sound ID %u\n", soundId);
  }

  nextSoundIndex = (nextSoundIndex + 1) %
                   (sizeof(TEST_SOUNDS) / sizeof(TEST_SOUNDS[0]));
  lastPlaybackMs = now;
}
