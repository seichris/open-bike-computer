#include <stdio.h>
#include "epaper_bsp.h"
#include "epaper_port.h"
#include "esp_log.h"
#include "driver/i2c_master.h"
#include "esp_log.h"
#include "qmi8658.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "i2c_bsp.h"
#include "fonts.h"

// Define the data cache area of the e-ink screen
uint8_t *Image_Mono;
// Log tag
static const char *TAG = "main";

extern i2c_master_bus_handle_t i2c_bus_handle;

static void draw_qmi8658_data_to_epaper(qmi8658_data_t *data)
{
    char buff[80];
    Paint_NewImage(Image_Mono, Font18.Height *6, Font18.Width * 8, 270, WHITE);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
    //Accel
    sprintf(buff, "%.4f", data->accelX);
    Paint_DrawString_EN(0, 5, buff, &Font18, WHITE, BLACK);
    sprintf(buff, "%.4f", data->accelY);
    Paint_DrawString_EN(0, 35, buff, &Font18, WHITE, BLACK);
    sprintf(buff, "%.4f", data->accelZ);
    Paint_DrawString_EN(0, 65, buff, &Font18, WHITE, BLACK);
    
    //Gyro
    sprintf(buff, "%.4f", data->gyroX);
    Paint_DrawString_EN(0, 95, buff, &Font18, WHITE, BLACK);
    sprintf(buff, "%.4f", data->gyroY);
    Paint_DrawString_EN(0, 125, buff, &Font18, WHITE, BLACK);
    sprintf(buff, "%.4f", data->gyroZ);
    Paint_DrawString_EN(0, 155, buff, &Font18, WHITE, BLACK);

    EPD_Display_Partial(Image_Mono, 50, 180, 50 + Font18.Height *6 , 180 +Font18.Width * 8 );

}


static void qmi8658_test_task(void *arg) {
    i2c_master_bus_handle_t bus_handle = (i2c_master_bus_handle_t)arg;
    qmi8658_dev_t dev;
    qmi8658_data_t data;
    
    ESP_LOGI(TAG, "Initializing QMI8658...");
    esp_err_t ret = qmi8658_init(&dev, bus_handle, QMI8658_ADDRESS_LOW);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize QMI8658 (error: %d)", ret);
        vTaskDelete(NULL);
    }

    qmi8658_set_accel_range(&dev, QMI8658_ACCEL_RANGE_8G);
    qmi8658_set_accel_odr(&dev, QMI8658_ACCEL_ODR_1000HZ);
    qmi8658_set_gyro_range(&dev, QMI8658_GYRO_RANGE_512DPS);
    qmi8658_set_gyro_odr(&dev, QMI8658_GYRO_ODR_1000HZ);
    
    qmi8658_set_accel_unit_mps2(&dev, true);
    qmi8658_set_gyro_unit_rads(&dev, true);
    
    qmi8658_set_display_precision(&dev, 4);

    while (1) {
        bool ready;
        ret = qmi8658_is_data_ready(&dev, &ready);
        if (ret == ESP_OK && ready) {
            ret = qmi8658_read_sensor_data(&dev, &data);
            if (ret == ESP_OK) {
                ESP_LOGI(TAG, "Accel: X=%.4f m/s², Y=%.4f m/s², Z=%.4f m/s²",
                         data.accelX, data.accelY, data.accelZ);
                ESP_LOGI(TAG, "Gyro:  X=%.4f rad/s, Y=%.4f rad/s, Z=%.4f rad/s",
                         data.gyroX, data.gyroY, data.gyroZ);
                ESP_LOGI(TAG, "Temp:  %.2f °C, Timestamp: %lu",
                         data.temperature, data.timestamp);
                ESP_LOGI(TAG, "----------------------------------------");

                draw_qmi8658_data_to_epaper(&data);
            } else {
                ESP_LOGE(TAG, "Failed to read sensor data (error: %d)", ret);
            }
        } else {
            ESP_LOGE(TAG, "Data not ready or error reading status (error: %d)", ret);
        }

        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

void app_main(void)
{
    ESP_LOGI(TAG,"1.e-Paper Init and Clear...");
    epaper_port_init();
    EPD_Init();
    EPD_Clear();
    vTaskDelay(pdMS_TO_TICKS(2000));

    if((Image_Mono = (UBYTE *)malloc(EPD_SIZE_MONO)) == NULL) 
    {
        ESP_LOGE(TAG,"Failed to apply for black memory...");
    }
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);

    Paint_DrawString_EN(50, 50, "ACCEL.x:", &Font18, WHITE, BLACK);
    Paint_DrawString_EN(50, 80, "ACCEL.y:", &Font18, WHITE, BLACK);
    Paint_DrawString_EN(50, 110, "ACCEL.z:", &Font18, WHITE, BLACK);
    Paint_DrawString_EN(50, 140, " GYRO.x:", &Font18, WHITE, BLACK);
    Paint_DrawString_EN(50, 170, " GYRO.y:", &Font18, WHITE, BLACK);
    Paint_DrawString_EN(50, 200, " GYRO.z:", &Font18, WHITE, BLACK);//e-Paper show
    EPD_Display_Base(Image_Mono);
    vTaskDelay(pdMS_TO_TICKS(2000));

    ESP_LOGI(TAG, "Initializing I2C...");
    i2c_master_init();

    xTaskCreate(qmi8658_test_task, "qmi8658_test_task", 4096, i2c_bus_handle, 5, NULL);
}
