#include "es8311_bsp.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"
#include "i2c_bsp.h"
#include "driver/i2s_std.h"
#include "esp_system.h"
#include "esp_check.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "ES8311";
extern i2c_master_dev_handle_t es8311_dev_handle;

esp_codec_dev_handle_t play_dev_handle = NULL;
esp_codec_dev_handle_t record_dev_handle = NULL;

i2s_chan_handle_t tx_handle = NULL;
i2s_chan_handle_t rx_handle = NULL;

esp_err_t es8311_codec_init(void)
{
    audio_codec_i2c_cfg_t i2c_cfg = {
        .port = I2C_NUM,
        .addr = ES8311_CODEC_DEFAULT_ADDR,
        .bus_handle = (void *)i2c_bus_handle,
    };
    
    ESP_LOGI(TAG, "es i2c_cfg bus_handle=%p addr=0x%02x", i2c_cfg.bus_handle, i2c_cfg.addr);
    
    // Create an I2C control interface
    const audio_codec_ctrl_if_t *i2c_ctrl_if = audio_codec_new_i2c_ctrl(&i2c_cfg);
    ESP_RETURN_ON_FALSE(i2c_ctrl_if, ESP_FAIL, TAG, "create i2c ctrl interface failed");
    
    // Create GPIO interfaces (for PA control, etc.)
    const audio_codec_gpio_if_t *gpio_if = audio_codec_new_gpio();
    ESP_RETURN_ON_FALSE(gpio_if, ESP_FAIL, TAG, "create gpio interface failed");
    
    // ES8311 codec configuration
    es8311_codec_cfg_t es8311_cfg = {
        .ctrl_if = i2c_ctrl_if,
        .gpio_if = gpio_if,
        .codec_mode = ESP_CODEC_DEV_WORK_MODE_BOTH,  // Supports playback and recording
        .pa_pin = I2S_PA_PIN,    
        .pa_reverted = false,
        .master_mode = false,   // The ESP32 serves as the I2S host
        .use_mclk = true,
        .digital_mic = false,
        .invert_mclk = false,
        .invert_sclk = false,
        .hw_gain = {
            .pa_voltage = 5.0,
            .codec_dac_voltage = 3.3,
        },
        .no_dac_ref = false,
        .mclk_div = 0,  // 0 indicates the use of the default value 256
    };
    
    // Create the ES8311 codec interface
    const audio_codec_if_t *es8311_dev = es8311_codec_new(&es8311_cfg);
    ESP_RETURN_ON_FALSE(es8311_dev, ESP_FAIL, TAG, "es8311 codec new failed");
    
    // Configure the I2S data interface
    audio_codec_i2s_cfg_t i2s_cfg = {
        .port = I2S_NUM,
        .rx_handle = rx_handle,
        .tx_handle = tx_handle,
    };
    
    // Create an I2S data interface
    const audio_codec_data_if_t *i2s_data_if = audio_codec_new_i2s_data(&i2s_cfg);
    ESP_RETURN_ON_FALSE(i2s_data_if, ESP_FAIL, TAG, "create i2s data interface failed");
    
    // Create a playback device
    esp_codec_dev_cfg_t play_dev_cfg = {
        .codec_if = es8311_dev,
        .data_if = i2s_data_if,
        .dev_type = ESP_CODEC_DEV_TYPE_OUT,
    };
    play_dev_handle = esp_codec_dev_new(&play_dev_cfg);
    ESP_RETURN_ON_FALSE(play_dev_handle, ESP_FAIL, TAG, "play device new failed");
    
    // Create a recording device
    esp_codec_dev_cfg_t record_dev_cfg = {
        .codec_if = es8311_dev,
        .data_if = i2s_data_if,
        .dev_type = ESP_CODEC_DEV_TYPE_IN,
    };
    record_dev_handle = esp_codec_dev_new(&record_dev_cfg);
    ESP_RETURN_ON_FALSE(record_dev_handle, ESP_FAIL, TAG, "record device new failed");
    
    // Configure the default sampling rate information (stereo, audio_player will automatically adjust according to the file)
    esp_codec_dev_sample_info_t fs = {
        .sample_rate = EXAMPLE_SAMPLE_RATE,
        .channel = 2,  // Default stereo, supports single/dual channel files
        .bits_per_sample = 16,
    };
    
    // Turn on the playback device (input the sampling rate configuration)
    ESP_RETURN_ON_ERROR(esp_codec_dev_open(play_dev_handle, &fs), TAG, "open play device failed");
    
    // The recording equipment is configured as mono (depending on your hardware)
    esp_codec_dev_sample_info_t fs_record = {
        .sample_rate = EXAMPLE_SAMPLE_RATE,
        .channel = 1,  // The recording was done in mono
        .bits_per_sample = 16,
    };
    
    // Turn on the recording device (input sampling rate configuration)
    ESP_RETURN_ON_ERROR(esp_codec_dev_open(record_dev_handle, &fs_record), TAG, "open record device failed");
    
    // Set the volume (0-100)
    ESP_RETURN_ON_ERROR(esp_codec_dev_set_out_vol(play_dev_handle, 0), TAG, "set initial volume failed");
    ESP_RETURN_ON_ERROR(esp_codec_dev_set_out_mute(play_dev_handle, true), TAG, "set initial mute failed");
    
    // Set the microphone gain
    ESP_RETURN_ON_ERROR(esp_codec_dev_set_in_gain(record_dev_handle, EXAMPLE_MIC_GAIN * 3.0f), TAG, "set mic gain failed");
    
    ESP_LOGI(TAG, "ES8311 codec initialized successfully");
    return ESP_OK;
}

esp_err_t i2s_driver_init(void)
{
    i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM, I2S_ROLE_MASTER);
    chan_cfg.auto_clear = true; // Auto clear the legacy data in the DMA buffer
    ESP_ERROR_CHECK(i2s_new_channel(&chan_cfg, &tx_handle, &rx_handle));

    vTaskDelay(pdMS_TO_TICKS(10));

    i2s_std_config_t std_cfg = {
        .clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG(EXAMPLE_SAMPLE_RATE),
        .slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO),
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
    std_cfg.clk_cfg.mclk_multiple = EXAMPLE_MCLK_MULTIPLE;

    ESP_ERROR_CHECK(i2s_channel_init_std_mode(tx_handle, &std_cfg));
    ESP_ERROR_CHECK(i2s_channel_init_std_mode(rx_handle, &std_cfg));
    ESP_ERROR_CHECK(i2s_channel_enable(tx_handle));
    ESP_ERROR_CHECK(i2s_channel_enable(rx_handle));
    return ESP_OK;
}

// Pre-shutdown processing
void es8311_audio_shutdown_cleanup(void)
{
    ESP_LOGI(TAG, "Audio shutdown cleanup start");
    
    if (play_dev_handle) {
        // Mute first
        esp_codec_dev_set_out_mute(play_dev_handle, true);
        vTaskDelay(pdMS_TO_TICKS(100));
        
        // Reduce the volume to 0
        esp_codec_dev_set_out_vol(play_dev_handle, 0);
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    
    // Stop the I2S channel (ignore the error, it may have been stopped)
    if (tx_handle) {
        i2s_channel_disable(tx_handle);
        vTaskDelay(pdMS_TO_TICKS(50));
    }
    if (rx_handle) {
        i2s_channel_disable(rx_handle);
        vTaskDelay(pdMS_TO_TICKS(50));
    }
    
    // Turn off the codec device (ignore errors)
    if (play_dev_handle) {
        esp_codec_dev_close(play_dev_handle);
        vTaskDelay(pdMS_TO_TICKS(50));
    }
    if (record_dev_handle) {
        esp_codec_dev_close(record_dev_handle);
        vTaskDelay(pdMS_TO_TICKS(50));
    }
    
    // Explicitly turn off the PA power amplifier
    vTaskDelay(pdMS_TO_TICKS(100));
    gpio_set_level(I2S_PA_PIN, 0);
    vTaskDelay(pdMS_TO_TICKS(100));
    
    ESP_LOGI(TAG, "Audio shutdown cleanup complete");
}
















