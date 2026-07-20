#include "speaker.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include "speaker_gain.h"
#include "../waveshare_board/axp2101.hpp"
#include "../waveshare_board/i2c_bus.hpp"

#include <Preferences.h>
#include <audio_codec_ctrl_if.h>
#include <audio_codec_data_if.h>
#include <audio_codec_gpio_if.h>
#include <audio_codec_if.h>
#include <driver/gpio.h>
#include <driver/i2s_std.h>
#include <es8311_codec.h>
#include <esp_codec_dev.h>
#include <esp_codec_dev_defaults.h>
#include <esp_codec_dev_types.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include <math.h>
#include <string.h>

namespace waveshare_board::speaker {

namespace {

constexpr uint32_t SAMPLE_RATE = 16000;
constexpr uint8_t CHANNELS = 2;
constexpr uint8_t ES8311_I2C_ADDRESS = 0x18;

#if defined(WAVESHARE_AMOLED_175)
constexpr float PA_SUPPLY_VOLTAGE = 3.3f;
constexpr float VOLUME_DB_AT_70_PERCENT =
    SPEAKER_VOLUME_DB_AT_70_PERCENT_WAVESHARE_175;
constexpr float MAX_DAC_GAIN_DB = SPEAKER_MAX_DAC_GAIN_DB_WAVESHARE_175;
constexpr gpio_num_t I2S_MCLK = GPIO_NUM_42;
constexpr gpio_num_t I2S_BCLK = GPIO_NUM_9;
constexpr gpio_num_t I2S_WS = GPIO_NUM_45;
constexpr gpio_num_t I2S_DOUT = GPIO_NUM_8;
constexpr gpio_num_t I2S_DIN = GPIO_NUM_10;
#else
constexpr float PA_SUPPLY_VOLTAGE = 5.0f;
constexpr float VOLUME_DB_AT_70_PERCENT =
    SPEAKER_VOLUME_DB_AT_70_PERCENT_WAVESHARE_206;
constexpr float MAX_DAC_GAIN_DB = SPEAKER_MAX_DAC_GAIN_DB_WAVESHARE_206;
constexpr gpio_num_t I2S_MCLK = GPIO_NUM_16;
constexpr gpio_num_t I2S_BCLK = GPIO_NUM_41;
constexpr gpio_num_t I2S_WS = GPIO_NUM_45;
constexpr gpio_num_t I2S_DOUT = GPIO_NUM_40;
constexpr gpio_num_t I2S_DIN = GPIO_NUM_42;
#endif
constexpr gpio_num_t PA_ENABLE = GPIO_NUM_46;

extern const uint8_t realBikeHornStart[]
    asm("_binary_lib_speaker_assets_real_bike_horn_pcm_start");
extern const uint8_t realBikeHornEnd[]
    asm("_binary_lib_speaker_assets_real_bike_horn_pcm_end");
extern const uint8_t rotatingBikeBellStart[]
    asm("_binary_lib_speaker_assets_rotating_bike_bell_pcm_start");
extern const uint8_t rotatingBikeBellEnd[]
    asm("_binary_lib_speaker_assets_rotating_bike_bell_pcm_end");
extern const uint8_t squeezeHornStart[]
    asm("_binary_lib_speaker_assets_squeeze_horn_a_pcm_start");
extern const uint8_t squeezeHornEnd[]
    asm("_binary_lib_speaker_assets_squeeze_horn_a_pcm_end");

struct WireControlInterface {
  audio_codec_ctrl_if_t base{};
};

WireControlInterface wireControl;
i2s_chan_handle_t txChannel = nullptr;
const audio_codec_if_t *codecInterface = nullptr;
const audio_codec_data_if_t *dataInterface = nullptr;
const audio_codec_gpio_if_t *gpioInterface = nullptr;
esp_codec_dev_handle_t speakerDevice = nullptr;
QueueHandle_t soundQueue = nullptr;
SemaphoreHandle_t powerButtonConfigMutex = nullptr;
bool initialized = false;
bool powerButtonHonkAvailable = false;
bool powerButtonMonitoringConfigured = false;
float codecHardwareGainDb = 0.0f;
float currentDacGainDb = 0.0f;
speaker_limiter_t playbackLimiter{};
PowerButtonHonkConfig powerButtonHonkConfig{
    false, Sound::PlasticBicycleHorn, DEFAULT_VOLUME_PERCENT};
uint32_t lastPowerButtonConfigureAttemptMs = 0;

constexpr uint32_t POWER_BUTTON_CONFIGURE_RETRY_MS = 5000;
constexpr uint32_t POWER_BUTTON_CONFIG_LOCK_TIMEOUT_MS = 250;
constexpr char POWER_BUTTON_PREFERENCES_NAMESPACE[] = "deviceSounds";
constexpr char POWER_BUTTON_CONFIG_KEY[] = "pwrConfig";
constexpr char POWER_BUTTON_ENABLED_KEY[] = "pwrHonk";
constexpr char POWER_BUTTON_SOUND_KEY[] = "pwrSound";
constexpr char POWER_BUTTON_VOLUME_KEY[] = "pwrVolume";

struct QueuedPlaybackRequest {
  uint8_t sound;
  uint8_t volumePercent;
};

class PowerButtonConfigLock {
public:
  explicit PowerButtonConfigLock(TickType_t timeoutTicks)
      : locked(powerButtonConfigMutex != nullptr &&
               xSemaphoreTake(powerButtonConfigMutex, timeoutTicks) == pdTRUE) {
  }

  ~PowerButtonConfigLock() {
    if (locked) {
      xSemaphoreGive(powerButtonConfigMutex);
    }
  }

  bool ok() const { return locked; }

private:
  bool locked;
};

void loadPowerButtonHonkConfig() {
  Preferences preferences;
  if (!preferences.begin(POWER_BUTTON_PREFERENCES_NAMESPACE, true)) {
    Serial.println("Speaker: unable to read PWR honk preferences");
    return;
  }

  uint8_t storedConfig[POWER_BUTTON_HONK_PAYLOAD_SIZE]{};
  if (preferences.getBytesLength(POWER_BUTTON_CONFIG_KEY) ==
          sizeof(storedConfig) &&
      preferences.getBytes(POWER_BUTTON_CONFIG_KEY, storedConfig,
                           sizeof(storedConfig)) == sizeof(storedConfig)) {
    PowerButtonHonkConfig decodedConfig{};
    if (decodePowerButtonHonkPayload(storedConfig, sizeof(storedConfig),
                                     decodedConfig)) {
      powerButtonHonkConfig = decodedConfig;
      preferences.end();
      return;
    }
  }

  const Sound storedSound = static_cast<Sound>(
      preferences.getUChar(POWER_BUTTON_SOUND_KEY,
                           static_cast<uint8_t>(powerButtonHonkConfig.sound)));
  const uint8_t storedVolume = preferences.getUChar(
      POWER_BUTTON_VOLUME_KEY, powerButtonHonkConfig.volumePercent);
  powerButtonHonkConfig.enabled =
      preferences.getBool(POWER_BUTTON_ENABLED_KEY, false);
  if (isKnownSound(storedSound)) {
    powerButtonHonkConfig.sound = storedSound;
  }
  if (storedVolume <= 100) {
    powerButtonHonkConfig.volumePercent = storedVolume;
  }
  preferences.end();
}

bool persistPowerButtonHonkConfig() {
  uint8_t storedConfig[POWER_BUTTON_HONK_PAYLOAD_SIZE]{};
  if (!encodePowerButtonHonkPayload(powerButtonHonkConfig, storedConfig,
                                    sizeof(storedConfig))) {
    return false;
  }

  Preferences preferences;
  if (!preferences.begin(POWER_BUTTON_PREFERENCES_NAMESPACE, false)) {
    return false;
  }
  const bool stored = preferences.putBytes(
                          POWER_BUTTON_CONFIG_KEY, storedConfig,
                          sizeof(storedConfig)) == sizeof(storedConfig);
  if (stored) {
    preferences.remove(POWER_BUTTON_ENABLED_KEY);
    preferences.remove(POWER_BUTTON_SOUND_KEY);
    preferences.remove(POWER_BUTTON_VOLUME_KEY);
  }
  preferences.end();
  return stored;
}

bool configurePowerButtonMonitoringLocked() {
  if (!powerButtonHonkAvailable) {
    return false;
  }
  powerButtonMonitoringConfigured =
      axp2101::setPowerButtonEventMonitoring(true);
  lastPowerButtonConfigureAttemptMs = millis();
  return powerButtonMonitoringConfigured;
}

int wireControlOpen(const audio_codec_ctrl_if_t *, void *, int) {
  return ESP_CODEC_DEV_OK;
}

bool wireControlIsOpen(const audio_codec_ctrl_if_t *) { return true; }

int wireControlRead(const audio_codec_ctrl_if_t *, int reg, int regLength,
                    void *data, int dataLength) {
  if (regLength != 1 || data == nullptr || dataLength <= 0 ||
      dataLength > UINT8_MAX) {
    return ESP_CODEC_DEV_INVALID_ARG;
  }

  return i2c::readRegisterBlock8(
             ES8311_I2C_ADDRESS, static_cast<uint8_t>(reg),
             static_cast<uint8_t *>(data), static_cast<uint8_t>(dataLength),
             "ES8311 speaker", 3)
             ? ESP_CODEC_DEV_OK
             : ESP_CODEC_DEV_DRV_ERR;
}

int wireControlWrite(const audio_codec_ctrl_if_t *, int reg, int regLength,
                     void *data, int dataLength) {
  if (regLength != 1 || data == nullptr || dataLength <= 0 ||
      dataLength > UINT8_MAX) {
    return ESP_CODEC_DEV_INVALID_ARG;
  }

  return i2c::writeRegisterBlock8(
             ES8311_I2C_ADDRESS, static_cast<uint8_t>(reg),
             static_cast<const uint8_t *>(data),
             static_cast<uint8_t>(dataLength), "ES8311 speaker", 3)
             ? ESP_CODEC_DEV_OK
             : ESP_CODEC_DEV_DRV_ERR;
}

int wireControlClose(const audio_codec_ctrl_if_t *) {
  return ESP_CODEC_DEV_OK;
}

void configureWireControl() {
  wireControl.base.open = wireControlOpen;
  wireControl.base.is_open = wireControlIsOpen;
  wireControl.base.read_reg = wireControlRead;
  wireControl.base.write_reg = wireControlWrite;
  wireControl.base.close = wireControlClose;
}

bool releaseCodecResources() {
  initialized = false;
  codecHardwareGainDb = 0.0f;
  currentDacGainDb = 0.0f;
  playbackLimiter = {};
  gpio_set_level(PA_ENABLE, 0);

  if (speakerDevice != nullptr) {
    if (esp_codec_dev_close(speakerDevice) != ESP_CODEC_DEV_OK) {
      Serial.println("Speaker: codec shutdown failed; cleanup will retry");
      return false;
    }
    esp_codec_dev_delete(speakerDevice);
    speakerDevice = nullptr;
  }
  if (codecInterface != nullptr) {
    audio_codec_delete_codec_if(codecInterface);
    codecInterface = nullptr;
  }
  if (dataInterface != nullptr) {
    audio_codec_delete_data_if(dataInterface);
    dataInterface = nullptr;
  }
  if (gpioInterface != nullptr) {
    audio_codec_delete_gpio_if(gpioInterface);
    gpioInterface = nullptr;
  }

  if (txChannel != nullptr) {
    i2s_channel_disable(txChannel);
    if (i2s_del_channel(txChannel) != ESP_OK) {
      Serial.println("Speaker: I2S channel cleanup failed; cleanup will retry");
      return false;
    }
    txChannel = nullptr;
  }

  return true;
}

bool failInitialization(const char *message) {
  Serial.println(message);
  releaseCodecResources();
  return false;
}

bool initializeCodec() {
  if (initialized) {
    return true;
  }
  if (speakerDevice != nullptr || codecInterface != nullptr ||
      dataInterface != nullptr || gpioInterface != nullptr ||
      txChannel != nullptr) {
    if (!releaseCodecResources()) {
      return false;
    }
  }

  if (!i2c::probe(ES8311_I2C_ADDRESS, "ES8311 speaker", 3)) {
    Serial.println("Speaker: ES8311 codec not found");
    return false;
  }

  gpio_set_direction(PA_ENABLE, GPIO_MODE_OUTPUT);
  gpio_set_level(PA_ENABLE, 0);

  i2s_chan_config_t channelConfig =
      I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
  channelConfig.auto_clear = true;
  if (i2s_new_channel(&channelConfig, &txChannel, nullptr) != ESP_OK) {
    return failInitialization("Speaker: failed to allocate I2S channels");
  }

  i2s_std_config_t standardConfig{};
  standardConfig.clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(22050);
  standardConfig.slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(
      I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);
  standardConfig.gpio_cfg.mclk = I2S_MCLK;
  standardConfig.gpio_cfg.bclk = I2S_BCLK;
  standardConfig.gpio_cfg.ws = I2S_WS;
  standardConfig.gpio_cfg.dout = I2S_DOUT;
  standardConfig.gpio_cfg.din = I2S_DIN;

  if (i2s_channel_init_std_mode(txChannel, &standardConfig) != ESP_OK ||
      i2s_channel_enable(txChannel) != ESP_OK) {
    return failInitialization("Speaker: failed to configure I2S");
  }

  audio_codec_i2s_cfg_t i2sConfig{};
  i2sConfig.port = I2S_NUM_0;
  i2sConfig.rx_handle = nullptr;
  i2sConfig.tx_handle = txChannel;
  dataInterface = audio_codec_new_i2s_data(&i2sConfig);
  gpioInterface = audio_codec_new_gpio();
  if (dataInterface == nullptr || gpioInterface == nullptr) {
    return failInitialization("Speaker: failed to create codec interfaces");
  }

  configureWireControl();
  esp_codec_dev_hw_gain_t hardwareGain{};
  hardwareGain.pa_voltage = PA_SUPPLY_VOLTAGE;
  hardwareGain.codec_dac_voltage = 3.3f;
  codecHardwareGainDb = esp_codec_dev_col_calc_hw_gain(&hardwareGain);

  es8311_codec_cfg_t codecConfig{};
  codecConfig.ctrl_if = &wireControl.base;
  codecConfig.gpio_if = gpioInterface;
  codecConfig.codec_mode = ESP_CODEC_DEV_WORK_MODE_DAC;
  codecConfig.pa_pin = PA_ENABLE;
  codecConfig.pa_reverted = false;
  codecConfig.master_mode = false;
  codecConfig.use_mclk = true;
  codecConfig.digital_mic = false;
  codecConfig.invert_mclk = false;
  codecConfig.invert_sclk = false;
  codecConfig.hw_gain = hardwareGain;

  codecInterface = es8311_codec_new(&codecConfig);
  if (codecInterface == nullptr) {
    return failInitialization("Speaker: failed to initialize ES8311");
  }

  esp_codec_dev_cfg_t deviceConfig{};
  deviceConfig.dev_type = ESP_CODEC_DEV_TYPE_OUT;
  deviceConfig.codec_if = codecInterface;
  deviceConfig.data_if = dataInterface;
  speakerDevice = esp_codec_dev_new(&deviceConfig);
  if (speakerDevice == nullptr) {
    return failInitialization("Speaker: failed to create codec device");
  }

  esp_codec_dev_vol_map_t volumeMap[SPEAKER_VOLUME_CURVE_POINT_COUNT]{};
  speaker_build_volume_map(volumeMap, codecHardwareGainDb,
                           VOLUME_DB_AT_70_PERCENT, MAX_DAC_GAIN_DB);
  esp_codec_dev_vol_curve_t volumeCurve{};
  volumeCurve.vol_map = volumeMap;
  volumeCurve.count = sizeof(volumeMap) / sizeof(volumeMap[0]);
  if (esp_codec_dev_set_vol_curve(speakerDevice, &volumeCurve) !=
      ESP_CODEC_DEV_OK) {
    return failInitialization("Speaker: failed to configure volume curve");
  }

  esp_codec_dev_sample_info_t sampleInfo{};
  sampleInfo.bits_per_sample = 16;
  sampleInfo.channel = CHANNELS;
  sampleInfo.sample_rate = SAMPLE_RATE;
  sampleInfo.mclk_multiple = 256;

  if (esp_codec_dev_set_out_vol(speakerDevice, DEFAULT_VOLUME_PERCENT) !=
          ESP_CODEC_DEV_OK ||
      esp_codec_dev_open(speakerDevice, &sampleInfo) != ESP_CODEC_DEV_OK) {
    return failInitialization("Speaker: failed to open codec device");
  }

  initialized = true;
  currentDacGainDb = speaker_dac_gain_db(
      DEFAULT_VOLUME_PERCENT, codecHardwareGainDb,
      VOLUME_DB_AT_70_PERCENT, MAX_DAC_GAIN_DB);
  speaker_configure_limiter(&playbackLimiter, currentDacGainDb);
  Serial.printf(
      "Speaker: ES8311 ready at %u%% default volume (100%% = %.0f dB DAC)\n",
      DEFAULT_VOLUME_PERCENT, MAX_DAC_GAIN_DB);
  return true;
}

bool writeAudio(const void *data, size_t length) {
  if (speakerDevice == nullptr || data == nullptr || length == 0) {
    return false;
  }
  if (!playbackLimiter.enabled) {
    return esp_codec_dev_write(speakerDevice, const_cast<void *>(data),
                               length) == ESP_CODEC_DEV_OK;
  }
  if (length % sizeof(int16_t) != 0) {
    return false;
  }

  const uint8_t *input = static_cast<const uint8_t *>(data);
  size_t remainingSamples = length / sizeof(int16_t);
  int16_t limitedSamples[256];
  while (remainingSamples > 0) {
    const size_t sampleCount =
        remainingSamples > 256 ? 256 : remainingSamples;
    for (size_t index = 0; index < sampleCount; index++) {
      int16_t sample = 0;
      memcpy(&sample, input + index * sizeof(sample), sizeof(sample));
      limitedSamples[index] = speaker_limit_sample(sample, &playbackLimiter);
    }
    if (esp_codec_dev_write(speakerDevice, limitedSamples,
                            sampleCount * sizeof(int16_t)) !=
        ESP_CODEC_DEV_OK) {
      return false;
    }
    input += sampleCount * sizeof(int16_t);
    remainingSamples -= sampleCount;
  }
  return true;
}

bool writeSilence(uint32_t milliseconds) {
  int16_t frame[128 * CHANNELS]{};
  uint32_t remainingFrames = SAMPLE_RATE * milliseconds / 1000;
  while (remainingFrames > 0) {
    uint32_t frames = remainingFrames > 128 ? 128 : remainingFrames;
    if (!writeAudio(frame, frames * CHANNELS * sizeof(int16_t))) {
      return false;
    }
    remainingFrames -= frames;
  }
  return true;
}

bool playPcm(const uint8_t *start, const uint8_t *end) {
  if (start == nullptr || end <= start) {
    return false;
  }

  const uint8_t *cursor = start;
  size_t remaining = static_cast<size_t>(end - start);
  while (remaining > 0) {
    size_t chunk = remaining > 2048 ? 2048 : remaining;
    if (!writeAudio(cursor, chunk)) {
      return false;
    }
    cursor += chunk;
    remaining -= chunk;
  }
  return writeSilence(180);
}

bool playBellDing() {
  int16_t frame[128 * CHANNELS];
  constexpr uint32_t totalFrames = SAMPLE_RATE * 700 / 1000;
  float phase1 = 0.0f;
  float phase2 = 0.0f;
  float phase3 = 0.0f;
  uint32_t position = 0;

  while (position < totalFrames) {
    uint32_t frames = totalFrames - position > 128 ? 128 : totalFrames - position;
    for (uint32_t index = 0; index < frames; index++) {
      float progress = static_cast<float>(position + index) /
                       static_cast<float>(totalFrames);
      float envelope = expf(-5.0f * progress);
      phase1 += 1175.0f / SAMPLE_RATE;
      phase2 += 1762.0f / SAMPLE_RATE;
      phase3 += 2350.0f / SAMPLE_RATE;
      if (phase1 >= 1.0f) phase1 -= 1.0f;
      if (phase2 >= 1.0f) phase2 -= 1.0f;
      if (phase3 >= 1.0f) phase3 -= 1.0f;
      float mixed = sinf(phase1 * 6.28318530718f) * 0.60f +
                    sinf(phase2 * 6.28318530718f) * 0.28f +
                    sinf(phase3 * 6.28318530718f) * 0.12f;
      int16_t sample = static_cast<int16_t>(mixed * envelope * 12000.0f);
      frame[index * 2] = sample;
      frame[index * 2 + 1] = sample;
    }
    if (!writeAudio(frame, frames * CHANNELS * sizeof(int16_t))) {
      return false;
    }
    position += frames;
  }
  return writeSilence(180);
}

bool playNow(Sound sound) {
  switch (sound) {
  case Sound::BellDing:
    return playBellDing();
  case Sound::PlasticBicycleHorn:
    return playPcm(realBikeHornStart, realBikeHornEnd);
  case Sound::RotatingBicycleBell:
    return playPcm(rotatingBikeBellStart, rotatingBikeBellEnd);
  case Sound::SqueezeHorn:
    return playPcm(squeezeHornStart, squeezeHornEnd);
  }
  return false;
}

void speakerTask(void *) {
  QueuedPlaybackRequest request{};
  while (true) {
    if (xQueueReceive(soundQueue, &request, portMAX_DELAY) != pdTRUE) {
      continue;
    }

    Sound sound = static_cast<Sound>(request.sound);
    if (!initializeCodec()) {
      Serial.println("Speaker: playback skipped because initialization failed");
      continue;
    }

    if (esp_codec_dev_set_out_vol(speakerDevice, request.volumePercent) !=
        ESP_CODEC_DEV_OK) {
      Serial.printf("Speaker: failed to set volume to %u%%\n",
                    request.volumePercent);
    } else {
      currentDacGainDb = speaker_dac_gain_db(
          request.volumePercent, codecHardwareGainDb,
          VOLUME_DB_AT_70_PERCENT, MAX_DAC_GAIN_DB);
      speaker_configure_limiter(&playbackLimiter, currentDacGainDb);
      Serial.printf("Speaker: playing sound %u at %u%% volume\n", request.sound,
                    request.volumePercent);
      if (!playNow(sound)) {
        Serial.printf("Speaker: sound %u playback failed\n", request.sound);
      }
    }

    if (uxQueueMessagesWaiting(soundQueue) == 0) {
      releaseCodecResources();
    }
  }
}

} // namespace

bool isSupported(Sound sound) {
  return isAvailable() && isKnownSound(sound);
}

bool begin() {
  if (soundQueue != nullptr) {
    return true;
  }

  soundQueue = xQueueCreate(4, sizeof(QueuedPlaybackRequest));
  if (soundQueue == nullptr) {
    Serial.println("Speaker: failed to create playback queue");
    return false;
  }

  powerButtonConfigMutex = xSemaphoreCreateMutex();
  if (powerButtonConfigMutex == nullptr) {
    Serial.println("Speaker: failed to create PWR configuration mutex");
  }

  if (xTaskCreate(speakerTask, "speaker", 6144, nullptr, 2, nullptr) !=
      pdPASS) {
    if (powerButtonConfigMutex != nullptr) {
      vSemaphoreDelete(powerButtonConfigMutex);
      powerButtonConfigMutex = nullptr;
    }
    vQueueDelete(soundQueue);
    soundQueue = nullptr;
    Serial.println("Speaker: failed to create playback task");
    return false;
  }

  Serial.println("Speaker: playback task ready");

  loadPowerButtonHonkConfig();
  powerButtonHonkAvailable =
      axp2101::isAvailable() && powerButtonConfigMutex != nullptr;
  if (powerButtonHonkAvailable) {
    PowerButtonConfigLock lock(
        pdMS_TO_TICKS(POWER_BUTTON_CONFIG_LOCK_TIMEOUT_MS));
    if (!lock.ok() || !configurePowerButtonMonitoringLocked()) {
      Serial.println("Speaker: PWR honk monitoring setup will retry");
    }
    Serial.printf("Speaker: PWR honk %s sound %u at %u%%\n",
                  powerButtonHonkConfig.enabled ? "enabled" : "disabled",
                  static_cast<unsigned>(powerButtonHonkConfig.sound),
                  powerButtonHonkConfig.volumePercent);
  } else {
    Serial.println("Speaker: PWR honk unavailable because AXP2101 is missing");
  }
  return true;
}

bool isAvailable() { return soundQueue != nullptr; }

bool requestPlay(Sound sound, uint8_t volumePercent) {
  if (!isSupported(sound) || volumePercent > 100 || soundQueue == nullptr) {
    return false;
  }

  QueuedPlaybackRequest request{static_cast<uint8_t>(sound), volumePercent};
  return xQueueSend(soundQueue, &request, 0) == pdTRUE;
}

bool isPowerButtonHonkAvailable() {
  return isAvailable() && powerButtonHonkAvailable;
}

bool getPowerButtonHonkConfig(PowerButtonHonkConfig &config) {
  if (!isPowerButtonHonkAvailable()) {
    return false;
  }

  PowerButtonConfigLock lock(
      pdMS_TO_TICKS(POWER_BUTTON_CONFIG_LOCK_TIMEOUT_MS));
  if (!lock.ok()) {
    return false;
  }
  config = powerButtonHonkConfig;
  return true;
}

bool configurePowerButtonHonk(const PowerButtonHonkConfig &config) {
  if (!isPowerButtonHonkAvailable() || !isKnownSound(config.sound) ||
      config.volumePercent > 100) {
    return false;
  }

  PowerButtonConfigLock lock(
      pdMS_TO_TICKS(POWER_BUTTON_CONFIG_LOCK_TIMEOUT_MS));
  if (!lock.ok()) {
    return false;
  }

  if (samePowerButtonHonkConfig(config, powerButtonHonkConfig) &&
      powerButtonMonitoringConfigured) {
    return true;
  }

  const PowerButtonHonkConfig previousConfig = powerButtonHonkConfig;
  powerButtonHonkConfig = config;
  if (!configurePowerButtonMonitoringLocked()) {
    powerButtonHonkConfig = previousConfig;
    if (!configurePowerButtonMonitoringLocked()) {
      Serial.println("Speaker: failed to restore previous PWR honk state");
    }
    return false;
  }
  if (!persistPowerButtonHonkConfig()) {
    Serial.println("Speaker: failed to persist PWR honk configuration");
    powerButtonHonkConfig = previousConfig;
    if (!configurePowerButtonMonitoringLocked()) {
      Serial.println("Speaker: failed to restore previous PWR honk state");
    }
    return false;
  }

  Serial.printf("Speaker: PWR honk %s sound %u at %u%%\n",
                config.enabled ? "enabled" : "disabled",
                static_cast<unsigned>(config.sound), config.volumePercent);
  return true;
}

void handlePowerButtonHonkPress() {
  if (!isPowerButtonHonkAvailable()) {
    return;
  }

  PowerButtonConfigLock lock(0);
  if (!lock.ok()) {
    return;
  }

  if (!powerButtonMonitoringConfigured) {
    const uint32_t now = millis();
    if (now - lastPowerButtonConfigureAttemptMs >=
        POWER_BUTTON_CONFIGURE_RETRY_MS) {
      configurePowerButtonMonitoringLocked();
    }
    return;
  }
  if (!powerButtonHonkConfig.enabled) {
    return;
  }
  if (!requestPlay(powerButtonHonkConfig.sound,
                   powerButtonHonkConfig.volumePercent)) {
    Serial.println("Speaker: PWR honk press could not queue playback");
    return;
  }
  Serial.println("Speaker: PWR short press queued honk");
}

} // namespace waveshare_board::speaker

#else

namespace waveshare_board::speaker {

bool begin() { return false; }
bool isAvailable() { return false; }
bool requestPlay(Sound, uint8_t) { return false; }
bool isSupported(Sound) { return false; }
bool isPowerButtonHonkAvailable() { return false; }
bool getPowerButtonHonkConfig(PowerButtonHonkConfig &) { return false; }
bool configurePowerButtonHonk(const PowerButtonHonkConfig &) { return false; }
void handlePowerButtonHonkPress() {}

} // namespace waveshare_board::speaker

#endif
