#pragma once

#include <math.h>
#include <stdint.h>

#include <esp_codec_dev_vol.h>

#define SPEAKER_MAX_DAC_GAIN_DB 20.0f
#define SPEAKER_VOLUME_CURVE_MIN_DB -50.0f
#define SPEAKER_VOLUME_DB_AT_70_PERCENT -15.0f
#define SPEAKER_VOLUME_CURVE_POINT_COUNT 3

typedef struct {
  int enabled;
  int32_t limit;
  float knee;
  float headroom;
} speaker_limiter_t;

static inline float speaker_max_route_gain_db(float hardware_gain_db) {
  return SPEAKER_MAX_DAC_GAIN_DB + hardware_gain_db;
}

static inline void speaker_build_volume_map(esp_codec_dev_vol_map_t *volume_map,
                                            float hardware_gain_db) {
  volume_map[0].vol = 0;
  volume_map[0].db_value = SPEAKER_VOLUME_CURVE_MIN_DB;
  volume_map[1].vol = 70;
  volume_map[1].db_value = SPEAKER_VOLUME_DB_AT_70_PERCENT;
  volume_map[2].vol = 100;
  volume_map[2].db_value = speaker_max_route_gain_db(hardware_gain_db);
}

static inline float speaker_route_gain_db(uint8_t volume_percent,
                                          float hardware_gain_db) {
  if (volume_percent == 0) {
    return -96.0f;
  }
  if (volume_percent <= 70) {
    return SPEAKER_VOLUME_CURVE_MIN_DB + 0.5f * volume_percent;
  }
  const float upper_range =
      speaker_max_route_gain_db(hardware_gain_db) -
      SPEAKER_VOLUME_DB_AT_70_PERCENT;
  return SPEAKER_VOLUME_DB_AT_70_PERCENT +
         upper_range * (volume_percent - 70) / 30.0f;
}

static inline float speaker_dac_gain_db(uint8_t volume_percent,
                                        float hardware_gain_db) {
  return speaker_route_gain_db(volume_percent, hardware_gain_db) -
         hardware_gain_db;
}

static inline void speaker_configure_limiter(speaker_limiter_t *limiter,
                                             float dac_gain_db) {
  limiter->enabled = dac_gain_db > 0.0f;
  if (!limiter->enabled) {
    limiter->limit = INT16_MAX;
    limiter->knee = INT16_MAX;
    limiter->headroom = 0.0f;
    return;
  }

  const float linear_gain = powf(10.0f, dac_gain_db / 20.0f);
  limiter->limit = (int32_t)(32767.0f / linear_gain);
  limiter->knee = limiter->limit * 0.8f;
  limiter->headroom = limiter->limit - limiter->knee;
}

static inline int16_t speaker_limit_sample(int16_t sample,
                                           const speaker_limiter_t *limiter) {
  if (!limiter->enabled || sample == 0) {
    return sample;
  }

  const float magnitude = fabsf((float)sample);
  if (magnitude <= limiter->knee) {
    return sample;
  }

  const float over_knee = magnitude - limiter->knee;
  const float compressed =
      limiter->knee + limiter->headroom * over_knee /
                          (over_knee + limiter->headroom);
  int32_t limited = (int32_t)(compressed + 0.5f);
  if (limited > limiter->limit) {
    limited = limiter->limit;
  }
  return (int16_t)(sample < 0 ? -limited : limited);
}
