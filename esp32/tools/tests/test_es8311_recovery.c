#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../../lib/esp_codec_dev/src/device/es8311/es8311.c"
#include "../../lib/speaker/speaker_gain.h"

static uint8_t registers[256];
static int failed_read_register = -1;
static int failed_write_register = -1;

static bool control_is_open(const audio_codec_ctrl_if_t *control)
{
    (void) control;
    return true;
}

static int control_read(const audio_codec_ctrl_if_t *control, int reg,
                        int reg_length, void *data, int data_length)
{
    (void) control;
    assert(reg_length == 1);
    assert(data_length == 1);
    if (reg == failed_read_register) {
        return ESP_CODEC_DEV_DRV_ERR;
    }
    *(uint8_t *) data = registers[reg & 0xFF];
    return ESP_CODEC_DEV_OK;
}

static int control_write(const audio_codec_ctrl_if_t *control, int reg,
                         int reg_length, void *data, int data_length)
{
    (void) control;
    assert(reg_length == 1);
    assert(data_length == 1);
    if (reg == failed_write_register) {
        return ESP_CODEC_DEV_DRV_ERR;
    }
    registers[reg & 0xFF] = *(uint8_t *) data;
    return ESP_CODEC_DEV_OK;
}

static const audio_codec_ctrl_if_t control_if = {
    .is_open = control_is_open,
    .read_reg = control_read,
    .write_reg = control_write,
};

static const audio_codec_if_t *new_codec(void)
{
    es8311_codec_cfg_t config = {
        .ctrl_if = &control_if,
        .codec_mode = ESP_CODEC_DEV_WORK_MODE_DAC,
        .pa_pin = -1,
        .use_mclk = true,
        .mclk_div = 256,
    };
    return es8311_codec_new(&config);
}

int main(void)
{
    memset(registers, 0, sizeof(registers));

    failed_read_register = ES8311_SYSTEM_REG0D;
    assert(new_codec() == NULL);

    failed_read_register = -1;
    failed_write_register = ES8311_SYSTEM_REG10;
    assert(new_codec() == NULL);

    failed_write_register = -1;
    const audio_codec_if_t *codec = new_codec();
    assert(codec != NULL);

    esp_codec_dev_sample_info_t format = {
        .bits_per_sample = 16,
        .channel = 1,
        .sample_rate = 16000,
        .mclk_multiple = 256,
    };

    failed_read_register = ES8311_CLK_MANAGER_REG02;
    assert(codec->set_fs(codec, &format) != ESP_CODEC_DEV_OK);

    failed_read_register = -1;
    failed_write_register = ES8311_CLK_MANAGER_REG05;
    assert(codec->set_fs(codec, &format) != ESP_CODEC_DEV_OK);

    failed_write_register = -1;
    assert(codec->set_fs(codec, &format) == ESP_CODEC_DEV_OK);
    assert(paired_8311.dac == NULL);

    failed_read_register = ES8311_SDPIN_REG09;
    assert(codec->enable(codec, true) != ESP_CODEC_DEV_OK);
    assert(paired_8311.dac == NULL);
    assert(!((audio_codec_es8311_t *) codec)->enabled);

    failed_read_register = -1;
    failed_write_register = ES8311_RESET_REG00;
    assert(codec->enable(codec, true) != ESP_CODEC_DEV_OK);
    assert(paired_8311.dac == NULL);
    assert(!((audio_codec_es8311_t *) codec)->enabled);

    failed_write_register = ES8311_SYSTEM_REG0E;
    assert(codec->enable(codec, true) != ESP_CODEC_DEV_OK);
    assert(paired_8311.dac == NULL);
    assert(!((audio_codec_es8311_t *) codec)->enabled);

    failed_write_register = ES8311_DAC_REG31;
    assert(codec->enable(codec, true) != ESP_CODEC_DEV_OK);
    assert(paired_8311.dac == NULL);
    assert(!((audio_codec_es8311_t *) codec)->enabled);

    failed_write_register = -1;
    assert(codec->enable(codec, true) == ESP_CODEC_DEV_OK);
    assert(paired_8311.dac == (audio_codec_es8311_t *) codec);

    esp_codec_dev_hw_gain_t hardware_gain = {
        .pa_voltage = 5.0f,
        .codec_dac_voltage = 3.3f,
    };
    const float target_route_db = speaker_max_route_gain_db(
        esp_codec_dev_col_calc_hw_gain(&hardware_gain),
        SPEAKER_MAX_DAC_GAIN_DB_WAVESHARE_206);
    assert(codec->set_vol(codec, target_route_db) == ESP_CODEC_DEV_OK);
    assert(registers[ES8311_DAC_REG32] == 0xE7);

    failed_write_register = ES8311_SYSTEM_REG0E;
    assert(codec->enable(codec, false) != ESP_CODEC_DEV_OK);
    assert(((audio_codec_es8311_t *) codec)->enabled);

    failed_write_register = -1;
    assert(codec->enable(codec, false) == ESP_CODEC_DEV_OK);
    assert(paired_8311.dac == NULL);

    assert(codec->close(codec) == ESP_CODEC_DEV_OK);
    free((void *) codec);
    return 0;
}
