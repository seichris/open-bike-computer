#include "../../lib/esp_codec_dev/src/audio_codec_data_if.h"
#include "../../lib/esp_codec_dev/src/audio_codec_if.h"

#include <assert.h>
#include <stdlib.h>

typedef struct {
    audio_codec_if_t base;
    int close_attempts;
} retryable_codec_if_t;

typedef struct {
    audio_codec_data_if_t base;
    int close_attempts;
} retryable_data_if_t;

static int close_codec(const audio_codec_if_t *handle)
{
    retryable_codec_if_t *owned = (retryable_codec_if_t *) handle;
    ++owned->close_attempts;
    return owned->close_attempts == 1 ? ESP_CODEC_DEV_DRV_ERR
                                      : ESP_CODEC_DEV_OK;
}

static int close_data(const audio_codec_data_if_t *handle)
{
    retryable_data_if_t *owned = (retryable_data_if_t *) handle;
    ++owned->close_attempts;
    return owned->close_attempts == 1 ? ESP_CODEC_DEV_DRV_ERR
                                      : ESP_CODEC_DEV_OK;
}

int main(void)
{
    retryable_codec_if_t *codec = calloc(1, sizeof(*codec));
    assert(codec != NULL);
    codec->base.close = close_codec;
    assert(audio_codec_delete_codec_if(&codec->base) == ESP_CODEC_DEV_DRV_ERR);
    assert(codec->close_attempts == 1);
    assert(audio_codec_delete_codec_if(&codec->base) == ESP_CODEC_DEV_OK);

    retryable_data_if_t *data = calloc(1, sizeof(*data));
    assert(data != NULL);
    data->base.close = close_data;
    assert(audio_codec_delete_data_if(&data->base) == ESP_CODEC_DEV_DRV_ERR);
    assert(data->close_attempts == 1);
    assert(audio_codec_delete_data_if(&data->base) == ESP_CODEC_DEV_OK);
    return 0;
}
