#include "audio_codec_sw_vol.h"
#include "esp_codec_dev.h"

#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef enum {
    FAIL_NONE,
    FAIL_DATA_FORMAT,
    FAIL_DATA_ENABLE,
    FAIL_CODEC_FORMAT,
    FAIL_CODEC_ENABLE,
} failure_point_t;

static failure_point_t failure_point;
static int codec_disable_count;
static int data_disable_count;

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
        return ESP_CODEC_DEV_OK;
    }
    return failure_point == FAIL_CODEC_ENABLE ? ESP_CODEC_DEV_DRV_ERR : ESP_CODEC_DEV_OK;
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
    (void) db;
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
        return ESP_CODEC_DEV_OK;
    }
    return failure_point == FAIL_DATA_ENABLE ? ESP_CODEC_DEV_DRV_ERR : ESP_CODEC_DEV_OK;
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
    assert(esp_codec_dev_open(device, &format) == ESP_CODEC_DEV_OK);
    assert(esp_codec_dev_write(device, &sample, 1) == 1);
    assert(esp_codec_dev_close(device) == ESP_CODEC_DEV_OK);
    esp_codec_dev_delete(device);
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
    return 0;
}
