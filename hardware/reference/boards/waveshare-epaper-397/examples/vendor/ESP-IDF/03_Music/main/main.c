#include <stdio.h>
#include "esp_log.h"
#include "sdcard_bsp.h"
#include "esp_codec_dev.h"
#include "es8311_bsp.h"
#include "audio_player.h" 
#include "i2c_bsp.h"

static const char *TAG = "main";

// Silent control function
static esp_err_t audio_mute_function(AUDIO_PLAYER_MUTE_SETTING setting) {
    ESP_LOGI(TAG, "mute setting %d", setting);
    if (setting == AUDIO_PLAYER_MUTE) {
        esp_codec_dev_set_out_mute(play_dev_handle, true);
    } else {
        esp_codec_dev_set_out_mute(play_dev_handle, false);
    }
    return ESP_OK;
}

static esp_err_t bsp_i2s_write(void *audio_buffer, size_t len, size_t *bytes_written, uint32_t timeout_ms)
{
    return i2s_channel_write(tx_handle, (char *)audio_buffer, len, bytes_written, timeout_ms);
}

static esp_err_t bsp_i2s_reconfig_clk(uint32_t rate, uint32_t bits_cfg, i2s_slot_mode_t ch)
{
    esp_err_t ret = ESP_OK;
    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(rate),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG((i2s_data_bit_width_t)bits_cfg, (i2s_slot_mode_t)ch),
        .gpio_cfg = {
            .mclk = I2S_MCLK_PIN,
            .bclk = I2S_BCK_PIN,
            .ws = I2S_WS_PIN,
            .dout = I2S_DATA_POUT,
            .din = I2S_DATA_PIN,
            .invert_flags = {
                .mclk_inv = false,
                .bclk_inv = false,
                .ws_inv = false,
            },
        },
    };

    ret |= i2s_channel_disable(tx_handle);
    ret |= i2s_channel_reconfig_std_clock(tx_handle, &std_cfg.clk_cfg);
    ret |= i2s_channel_reconfig_std_slot(tx_handle, &std_cfg.slot_cfg);
    ret |= i2s_channel_enable(tx_handle);

    // ESP_LOGI(TAG, "I2S TX configuration completed - Sampling rate: %lu Hz, channels: %d", (unsigned long)rate, (int)ch);

    return ret;
}

void page_audio_int(void)
{
    if (i2s_driver_init() != ESP_OK) {
        ESP_LOGE(TAG, "i2s driver init failed");
        abort();
    } else {
        ESP_LOGI(TAG, "i2s driver init success");
    }

    if (es8311_codec_init() != ESP_OK) {
        ESP_LOGE(TAG, "es8311 codec init failed");
        abort();
    } else {
        ESP_LOGI(TAG, "es8311 codec init success");
    }

    vTaskDelay(pdMS_TO_TICKS(50));

    audio_player_config_t config;
    config.mute_fn = audio_mute_function;
    config.write_fn = bsp_i2s_write;
    config.clk_set_fn = bsp_i2s_reconfig_clk;
    config.priority = 5;
    config.coreID = 1;
    
    esp_err_t ret = audio_player_new(config);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "audio player init failed: %s", esp_err_to_name(ret));
    } else {
        ESP_LOGI(TAG, "audio player init success");
    }

    esp_codec_dev_set_out_mute(play_dev_handle, true);
    esp_codec_dev_set_out_vol(play_dev_handle, 0);
    
    ESP_LOGI(TAG, "Audio subsystem ready (muted, volume=0)");
}

void app_main(void)
{

    _sdcard_init();
    i2c_master_init();
    page_audio_int();

    if(card_host == NULL) {
        ESP_LOGI(TAG,"SD card init failed");
        return;
    }else{
        ESP_LOGI(TAG,"SD card init success");
    }
    //// traverse the music directory of the SD card
    // sdcard_queuehandle = xQueueCreate(20, sizeof(char)*300);
    // scan_files("/sdcard/music");

    FILE *audio_fp = fopen("/sdcard/music/gs-16b-1c-44100hz.mp3", "rb");
    if(audio_fp == NULL)
    {
        ESP_LOGE(TAG, "Open audio file failed! path: /sdcard/music/gs-16b-1c-44100hz.mp3");
    }
    else
    {
        ESP_LOGI(TAG, "Open audio file success!");
        //INT mute
        esp_codec_dev_set_out_mute(play_dev_handle, false);
        esp_codec_dev_set_out_vol(play_dev_handle, 70);

        esp_err_t ret = audio_player_play(audio_fp);
        if(ret == ESP_OK)
        {
            ESP_LOGI(TAG, "Audio play start success");
        }
        else
        {
            ESP_LOGE(TAG, "Audio play start failed, err code: %d", ret);
            fclose(audio_fp);
            return ;
        }
        
    }
    vTaskDelay(portMAX_DELAY);

}

