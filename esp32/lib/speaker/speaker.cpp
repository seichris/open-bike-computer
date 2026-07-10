#include "speaker.hpp"

#if defined(WAVESHARE_AMOLED_206)

#include "../waveshare_board/i2c_bus.hpp"

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
#include <freertos/task.h>
#include <math.h>

namespace waveshare_board::speaker {

namespace {

constexpr uint32_t SAMPLE_RATE = 16000;
constexpr uint8_t CHANNELS = 2;
constexpr uint8_t ES8311_I2C_ADDRESS = 0x18;

constexpr gpio_num_t I2S_MCLK = GPIO_NUM_16;
constexpr gpio_num_t I2S_BCLK = GPIO_NUM_41;
constexpr gpio_num_t I2S_WS = GPIO_NUM_45;
constexpr gpio_num_t I2S_DOUT = GPIO_NUM_40;
constexpr gpio_num_t I2S_DIN = GPIO_NUM_42;
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
i2s_chan_handle_t rxChannel = nullptr;
const audio_codec_if_t *codecInterface = nullptr;
const audio_codec_data_if_t *dataInterface = nullptr;
const audio_codec_gpio_if_t *gpioInterface = nullptr;
esp_codec_dev_handle_t speakerDevice = nullptr;
QueueHandle_t soundQueue = nullptr;
bool initialized = false;

struct QueuedPlaybackRequest {
  uint8_t sound;
  uint8_t volumePercent;
};

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

void releaseCodecResources() {
  initialized = false;

  if (speakerDevice != nullptr) {
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
    i2s_del_channel(txChannel);
    txChannel = nullptr;
  }
  if (rxChannel != nullptr) {
    i2s_channel_disable(rxChannel);
    i2s_del_channel(rxChannel);
    rxChannel = nullptr;
  }

  gpio_set_level(PA_ENABLE, 0);
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

  if (!i2c::probe(ES8311_I2C_ADDRESS, "ES8311 speaker", 3)) {
    Serial.println("Speaker: ES8311 codec not found");
    return false;
  }

  gpio_set_direction(PA_ENABLE, GPIO_MODE_OUTPUT);
  gpio_set_level(PA_ENABLE, 0);

  i2s_chan_config_t channelConfig =
      I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
  channelConfig.auto_clear = true;
  if (i2s_new_channel(&channelConfig, &txChannel, &rxChannel) != ESP_OK) {
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
      i2s_channel_enable(txChannel) != ESP_OK ||
      i2s_channel_init_std_mode(rxChannel, &standardConfig) != ESP_OK ||
      i2s_channel_enable(rxChannel) != ESP_OK) {
    return failInitialization("Speaker: failed to configure I2S");
  }

  audio_codec_i2s_cfg_t i2sConfig{};
  i2sConfig.port = I2S_NUM_0;
  i2sConfig.rx_handle = rxChannel;
  i2sConfig.tx_handle = txChannel;
  dataInterface = audio_codec_new_i2s_data(&i2sConfig);
  gpioInterface = audio_codec_new_gpio();
  if (dataInterface == nullptr || gpioInterface == nullptr) {
    return failInitialization("Speaker: failed to create codec interfaces");
  }

  configureWireControl();
  esp_codec_dev_hw_gain_t hardwareGain{};
  hardwareGain.pa_voltage = 5.0f;
  hardwareGain.codec_dac_voltage = 3.3f;

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
  Serial.printf("Speaker: ES8311 ready at %u%% default volume\n",
                DEFAULT_VOLUME_PERCENT);
  return true;
}

bool writeAudio(const void *data, size_t length) {
  return speakerDevice != nullptr && data != nullptr && length > 0 &&
         esp_codec_dev_write(speakerDevice, const_cast<void *>(data), length) ==
             ESP_CODEC_DEV_OK;
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
  return isKnownSound(sound);
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

  if (xTaskCreate(speakerTask, "speaker", 6144, nullptr, 2, nullptr) !=
      pdPASS) {
    vQueueDelete(soundQueue);
    soundQueue = nullptr;
    Serial.println("Speaker: failed to create playback task");
    return false;
  }

  Serial.println("Speaker: playback task ready");
  return true;
}

bool requestPlay(Sound sound, uint8_t volumePercent) {
  if (!isSupported(sound) || volumePercent > 100 || soundQueue == nullptr) {
    return false;
  }

  QueuedPlaybackRequest request{static_cast<uint8_t>(sound), volumePercent};
  return xQueueSend(soundQueue, &request, 0) == pdTRUE;
}

} // namespace waveshare_board::speaker

#else

namespace waveshare_board::speaker {

bool begin() { return false; }
bool requestPlay(Sound, uint8_t) { return false; }
bool isSupported(Sound) { return false; }

} // namespace waveshare_board::speaker

#endif
