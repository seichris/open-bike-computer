#include "audio_codec_sw_vol.h"
#include "esp_codec_dev.h"
#include "../../lib/speaker/speaker_gain.h"

#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    FAIL_NONE,
    FAIL_DATA_FORMAT,
    FAIL_DATA_ENABLE,
    FAIL_CODEC_FORMAT,
    FAIL_CODEC_ENABLE,
    FAIL_DATA_DISABLE,
    FAIL_CODEC_DISABLE,
} failure_point_t;

static failure_point_t failure_point;
static int codec_disable_count;
static int data_disable_count;
static bool codec_enabled;
static bool data_enabled;
static float last_volume_db;

static bool codec_is_open(const audio_codec_if_t *codec)
{
    (void) codec;
    return true;
}

static int codec_enable(const audio_codec_if_t *codec, bool enable)
{
    (void) codec;
    if (!enable) {
        codec_disable_count++;
        if (!codec_enabled || failure_point == FAIL_CODEC_DISABLE) {
            return ESP_CODEC_DEV_DRV_ERR;
        }
        codec_enabled = false;
        return ESP_CODEC_DEV_OK;
    }
    if (failure_point == FAIL_CODEC_ENABLE) {
        return ESP_CODEC_DEV_DRV_ERR;
    }
    codec_enabled = true;
    return ESP_CODEC_DEV_OK;
}

static int codec_set_format(const audio_codec_if_t *codec, esp_codec_dev_sample_info_t *format)
{
    (void) codec;
    (void) format;
    return failure_point == FAIL_CODEC_FORMAT ? ESP_CODEC_DEV_DRV_ERR : ESP_CODEC_DEV_OK;
}

static int codec_set_volume(const audio_codec_if_t *codec, float db)
{
    (void) codec;
    last_volume_db = db;
    return ESP_CODEC_DEV_OK;
}

static int codec_set_mute(const audio_codec_if_t *codec, bool mute)
{
    (void) codec;
    (void) mute;
    return ESP_CODEC_DEV_OK;
}

static bool data_is_open(const audio_codec_data_if_t *data_if)
{
    (void) data_if;
    return true;
}

static int data_set_format(const audio_codec_data_if_t *data_if,
                           esp_codec_dev_type_t type,
                           esp_codec_dev_sample_info_t *format)
{
    (void) data_if;
    (void) type;
    (void) format;
    return failure_point == FAIL_DATA_FORMAT ? ESP_CODEC_DEV_DRV_ERR : ESP_CODEC_DEV_OK;
}

static int data_enable(const audio_codec_data_if_t *data_if,
                       esp_codec_dev_type_t type, bool enable)
{
    (void) data_if;
    (void) type;
    if (!enable) {
        data_disable_count++;
        if (!data_enabled || failure_point == FAIL_DATA_DISABLE) {
            return ESP_CODEC_DEV_DRV_ERR;
        }
        data_enabled = false;
        return ESP_CODEC_DEV_OK;
    }
    if (failure_point == FAIL_DATA_ENABLE) {
        return ESP_CODEC_DEV_DRV_ERR;
    }
    data_enabled = true;
    return ESP_CODEC_DEV_OK;
}

static int data_write(const audio_codec_data_if_t *data_if, uint8_t *data, int size)
{
    (void) data_if;
    (void) data;
    return size;
}

const audio_codec_vol_if_t *audio_codec_new_sw_vol(void)
{
    return NULL;
}

int audio_codec_delete_vol_if(const audio_codec_vol_if_t *vol_if)
{
    (void) vol_if;
    return ESP_CODEC_DEV_OK;
}

static const audio_codec_if_t codec_if = {
    .is_open = codec_is_open,
    .enable = codec_enable,
    .set_fs = codec_set_format,
    .mute = codec_set_mute,
    .set_vol = codec_set_volume,
};

static const audio_codec_data_if_t data_if = {
    .is_open = data_is_open,
    .enable = data_enable,
    .set_fmt = data_set_format,
    .write = data_write,
};

static void verify_failed_open_can_retry(failure_point_t point)
{
    failure_point = point;
    codec_disable_count = 0;
    data_disable_count = 0;
    codec_enabled = false;
    data_enabled = false;

    esp_codec_dev_cfg_t config = {
        .dev_type = ESP_CODEC_DEV_TYPE_OUT,
        .codec_if = &codec_if,
        .data_if = &data_if,
    };
    esp_codec_dev_sample_info_t format = {
        .bits_per_sample = 16,
        .channel = 1,
        .sample_rate = 16000,
    };
    esp_codec_dev_handle_t device = esp_codec_dev_new(&config);
    assert(device != NULL);

    assert(esp_codec_dev_open(device, &format) != ESP_CODEC_DEV_OK);
    assert(codec_disable_count == 1);
    assert(data_disable_count == 1);

    uint8_t sample = 0;
    assert(esp_codec_dev_write(device, &sample, 1) == ESP_CODEC_DEV_WRONG_STATE);

    failure_point = FAIL_NONE;
    codec_disable_count = 0;
    data_disable_count = 0;
    codec_enabled = false;
    data_enabled = false;
    assert(esp_codec_dev_open(device, &format) == ESP_CODEC_DEV_OK);
    assert(esp_codec_dev_write(device, &sample, 1) == 1);
    assert(esp_codec_dev_close(device) == ESP_CODEC_DEV_OK);
    esp_codec_dev_delete(device);
}

static void verify_custom_volume_curve(void)
{
    esp_codec_dev_cfg_t config = {
        .dev_type = ESP_CODEC_DEV_TYPE_OUT,
        .codec_if = &codec_if,
        .data_if = &data_if,
    };
    esp_codec_dev_handle_t device = esp_codec_dev_new(&config);
    assert(device != NULL);

    const float hardware_gain_db = 20.0f * log10f(3.3f / 5.0f);
    const float volume_db_at_70_percent =
        SPEAKER_VOLUME_DB_AT_70_PERCENT_WAVESHARE_206;
    const float max_dac_gain_db = SPEAKER_MAX_DAC_GAIN_DB_WAVESHARE_206;
    const float max_route_db =
        speaker_max_route_gain_db(hardware_gain_db, max_dac_gain_db);
    esp_codec_dev_vol_map_t volume_map[SPEAKER_VOLUME_CURVE_POINT_COUNT];
    speaker_build_volume_map(volume_map, hardware_gain_db,
                             volume_db_at_70_percent, max_dac_gain_db);
    esp_codec_dev_vol_curve_t curve = {
        .vol_map = volume_map,
        .count = 3,
    };
    assert(esp_codec_dev_set_vol_curve(device, &curve) == ESP_CODEC_DEV_OK);

    assert(esp_codec_dev_set_out_vol(device, 30) == ESP_CODEC_DEV_OK);
    assert(fabsf(last_volume_db - (-35.0f)) < 0.001f);
    assert(esp_codec_dev_set_out_vol(device, 70) == ESP_CODEC_DEV_OK);
    assert(fabsf(last_volume_db - (-15.0f)) < 0.001f);
    assert(esp_codec_dev_set_out_vol(device, 85) == ESP_CODEC_DEV_OK);
    assert(fabsf(last_volume_db - ((-15.0f + max_route_db) / 2.0f)) <
           0.001f);
    assert(esp_codec_dev_set_out_vol(device, 100) == ESP_CODEC_DEV_OK);
    assert(fabsf(last_volume_db - max_route_db) < 0.001f);

    esp_codec_dev_delete(device);
}

static void verify_waveshare_175_volume_profile(void)
{
    const float hardware_gain_db = 0.0f;
    const float volume_db_at_70_percent =
        SPEAKER_VOLUME_DB_AT_70_PERCENT_WAVESHARE_175;
    const float max_dac_gain_db = SPEAKER_MAX_DAC_GAIN_DB_WAVESHARE_175;
    esp_codec_dev_vol_map_t volume_map[SPEAKER_VOLUME_CURVE_POINT_COUNT];
    speaker_build_volume_map(volume_map, hardware_gain_db,
                             volume_db_at_70_percent, max_dac_gain_db);

    assert(fabsf(volume_map[1].db_value - 0.0f) < 0.001f);
    assert(fabsf(volume_map[2].db_value - 6.0f) < 0.001f);
    assert(fabsf(speaker_dac_gain_db(70, hardware_gain_db,
                                     volume_db_at_70_percent,
                                     max_dac_gain_db) - 0.0f) < 0.001f);
    assert(fabsf(speaker_dac_gain_db(90, hardware_gain_db,
                                     volume_db_at_70_percent,
                                     max_dac_gain_db) - 4.0f) < 0.001f);
    assert(fabsf(speaker_dac_gain_db(100, hardware_gain_db,
                                     volume_db_at_70_percent,
                                     max_dac_gain_db) - 6.0f) < 0.001f);
}

static void verify_failed_close_can_retry(failure_point_t point)
{
    failure_point = FAIL_NONE;
    codec_disable_count = 0;
    data_disable_count = 0;
    codec_enabled = false;
    data_enabled = false;
    esp_codec_dev_cfg_t config = {
        .dev_type = ESP_CODEC_DEV_TYPE_OUT,
        .codec_if = &codec_if,
        .data_if = &data_if,
    };
    esp_codec_dev_sample_info_t format = {
        .bits_per_sample = 16,
        .channel = 1,
        .sample_rate = 16000,
    };
    esp_codec_dev_handle_t device = esp_codec_dev_new(&config);
    assert(device != NULL);
    assert(esp_codec_dev_open(device, &format) == ESP_CODEC_DEV_OK);

    failure_point = point;
    assert(esp_codec_dev_close(device) != ESP_CODEC_DEV_OK);
    uint8_t sample = 0;
    assert(esp_codec_dev_write(device, &sample, 1) == 1);

    failure_point = FAIL_NONE;
    assert(esp_codec_dev_close(device) == ESP_CODEC_DEV_OK);
    if (point == FAIL_CODEC_DISABLE) {
        assert(codec_disable_count == 2);
        assert(data_disable_count == 1);
    } else {
        assert(codec_disable_count == 1);
        assert(data_disable_count == 2);
    }
    assert(esp_codec_dev_write(device, &sample, 1) == ESP_CODEC_DEV_WRONG_STATE);
    esp_codec_dev_delete(device);
}

static void verify_high_gain_limiter(void)
{
    speaker_limiter_t limiter = {0};
    speaker_configure_limiter(&limiter, 20.0f);
    assert(limiter.enabled);
    assert(limiter.limit == 3276);
    assert(speaker_limit_sample(1000, &limiter) == 1000);
    assert(speaker_limit_sample(-1000, &limiter) == -1000);

    const int16_t limited_positive = speaker_limit_sample(INT16_MAX, &limiter);
    const int16_t limited_negative = speaker_limit_sample(INT16_MIN, &limiter);
    assert(limited_positive > 0 && limited_positive <= 3276);
    assert(limited_negative < 0 && limited_negative >= -3276);
    assert((float) limited_positive * 10.0f <= INT16_MAX);
    assert((float) -limited_negative * 10.0f <= INT16_MAX);

    speaker_configure_limiter(&limiter, 0.0f);
    assert(!limiter.enabled);
    assert(speaker_limit_sample(INT16_MAX, &limiter) == INT16_MAX);
}

int main(void)
{
    const failure_point_t points[] = {
        FAIL_DATA_FORMAT,
        FAIL_DATA_ENABLE,
        FAIL_CODEC_FORMAT,
        FAIL_CODEC_ENABLE,
    };
    for (size_t i = 0; i < sizeof(points) / sizeof(points[0]); i++) {
        verify_failed_open_can_retry(points[i]);
    }
    verify_failed_close_can_retry(FAIL_CODEC_DISABLE);
    verify_failed_close_can_retry(FAIL_DATA_DISABLE);
    verify_custom_volume_curve();
    verify_waveshare_175_volume_profile();
    verify_high_gain_limiter();
    return 0;
}
