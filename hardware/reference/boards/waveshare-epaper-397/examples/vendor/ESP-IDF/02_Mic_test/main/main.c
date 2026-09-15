#include <stdio.h>
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "i2c_bsp.h"
#include "button_bsp.h"
#include "audio_bsp.h"
#include "esp_heap_caps.h"

static const char *TAG = "main";

#define RECORD_DURATION_MS    3000 
#define RECORD_SAMPLE_RATE    16000  
#define RECORD_CHANNEL        2      
#define RECORD_BITS_PER_SAMPLE 16     
#define RECORD_BUF_SIZE       (RECORD_SAMPLE_RATE * RECORD_CHANNEL * (RECORD_BITS_PER_SAMPLE/8) * (RECORD_DURATION_MS/1000))

static uint8_t *g_record_buf = NULL;  
static SemaphoreHandle_t g_audio_mutex = NULL; 
static bool g_is_recording = false;   

/**
 * @brief Recording task (triggered by long press, automatically ends after 3 seconds)
 */
static void audio_record_task(void *arg)
{
    for (;;) {
        EventBits_t event = xEventGroupWaitBits(
            boot_groups,
            set_bit_button(1), 
            pdTRUE,           
            pdFALSE,            
            portMAX_DELAY       
        );

        if (event & set_bit_button(1)) {
            if (xSemaphoreTake(g_audio_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
                ESP_LOGE(TAG, "Audio mutex take failed!");
                continue;
            }

            if (g_record_buf == NULL) {
                ESP_LOGE(TAG, "Record buffer not allocated!");
                xSemaphoreGive(g_audio_mutex);
                continue;
            }

            // start record
            g_is_recording = true;
            ESP_LOGI(TAG, "Start recording... (duration: %dms)", RECORD_DURATION_MS);
            audio_playback_read(g_record_buf, RECORD_BUF_SIZE);
            g_is_recording = false;
            ESP_LOGI(TAG, "Record finished! Buffer size: %d bytes", RECORD_BUF_SIZE);
            
            xSemaphoreGive(g_audio_mutex);
        }
    }
    vTaskDelete(NULL);
}

/**
 * @brief Play the recording task (triggered by short press)
 */
static void audio_play_task(void *arg)
{
    for (;;) {
        EventBits_t event = xEventGroupWaitBits(
            boot_groups,
            set_bit_button(0), 
            pdTRUE,           
            pdFALSE,           
            portMAX_DELAY    
        );

        if (event & set_bit_button(0)) {
            if (xSemaphoreTake(g_audio_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
                ESP_LOGE(TAG, "Audio mutex take failed!");
                continue;
            }

            if (g_is_recording) {
                ESP_LOGW(TAG, "Recording is in progress, skip play!");
                xSemaphoreGive(g_audio_mutex);
                continue;
            }
            if (g_record_buf == NULL) {
                ESP_LOGE(TAG, "Record buffer not allocated!");
                xSemaphoreGive(g_audio_mutex);
                continue;
            }

            ESP_LOGI(TAG, "Start playing recorded audio...");
            audio_playback_write(g_record_buf, RECORD_BUF_SIZE);
            ESP_LOGI(TAG, "Play finished!");
            
            xSemaphoreGive(g_audio_mutex);
        }
    }
    vTaskDelete(NULL);
}

void app_main(void)
{
    ESP_LOGI(TAG, "App start initializing...");

    i2c_master_init();
    ESP_LOGI(TAG, "I2C master initialized");

    user_button_init();

    audio_bsp_init();
    audio_play_init();
    // Set the default volume
    audio_playback_set_vol(100);
    ESP_LOGI(TAG, "Audio BSP initialized");

    // Apply for a recording buffer
    g_record_buf = (uint8_t *)malloc(RECORD_BUF_SIZE);
    if (g_record_buf == NULL) {
        ESP_LOGE(TAG, "Failed to allocate record buffer (%d bytes)", RECORD_BUF_SIZE);
        return;
    }
    ESP_LOGI(TAG, "Record buffer allocated: %d bytes (SPIRAM)", RECORD_BUF_SIZE);

    // Create an audio mutex lock
    g_audio_mutex = xSemaphoreCreateMutex();
    if (g_audio_mutex == NULL) {
        ESP_LOGE(TAG, "Failed to create audio mutex");
        heap_caps_free(g_record_buf);
        return;
    }

    // task
    xTaskCreatePinnedToCore(
        audio_record_task,
        "audio_record_task",
        4 * 1024,
        NULL,
        5,
        NULL,
        1          
    );

    xTaskCreatePinnedToCore(
        audio_play_task,
        "audio_play_task",
        4 * 1024, 
        NULL,
        4,
        NULL,
        1  
    );

    ESP_LOGI(TAG, "All tasks created!");
    ESP_LOGI(TAG, "=====================================");
    ESP_LOGI(TAG, "Operation Guide:");
    ESP_LOGI(TAG, "  - Long press BOOT button: Record 3s audio");
    ESP_LOGI(TAG, "  - Short press BOOT button: Play recorded audio");
    ESP_LOGI(TAG, "=====================================");
}