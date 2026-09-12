#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "epaper_bsp.h"
#include "epaper_port.h"
#include "esp_log.h"
#include "i2c_bsp.h"
#include "shtc3_bsp.h"

// Define the data cache area of the e-ink screen
uint8_t *Image_Mono;
// Log tag
static const char *TAG = "main";

float temperature = 0.0f;
float humidity = 0.0f;
char disp_buf[64] = {0};

char celsius_gb2312[] = {0xA1, 0xE6, '\0'};//℃

void i2c_SHTC3_loop_task(void *arg)
{
  while(1)
    {
        int ret = SHTC3_GetEnvTemperatureHumidity(&temperature, &humidity);
        if(ret != 0)
        {
            ESP_LOGE(TAG,"Read SHTC3 Temp/Humi failed, err=%d", ret);
            vTaskDelay(pdMS_TO_TICKS(2000));
            continue;
        }
        ESP_LOGI(TAG,"Read success -> Temp:%.2f°C, Humi:%.2f%%RH", temperature, humidity);

        Paint_NewImage(Image_Mono, Font16.Height *3, Font16.Width * 8, 270, WHITE);
        Paint_SelectImage(Image_Mono);
        Paint_Clear(WHITE);
        // show shtc data
        sprintf(disp_buf, "%.1f %%RH",  humidity);
        Paint_ClearWindows(0, 5, Font16.Width * 8, Font16.Height, WHITE);
        Paint_DrawString_EN(0, 5, disp_buf, &Font16, WHITE, BLACK);
        sprintf(disp_buf, "%.1f", temperature);
        Paint_ClearWindows(0, 35, Font16.Width * 8, 30+Font16.Height, WHITE);
        Paint_DrawString_EN(0, 35, disp_buf, &Font16, WHITE, BLACK);
        Paint_DrawString_CN(Font16.Width * 5, 33,celsius_gb2312, &Font16_GBK, WHITE, BLACK);

        EPD_Display_Partial(Image_Mono, 50, 130, 50 + Font16.Height *3, 130 + Font16.Width * 8);

        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}


void app_main(void)
{
    //e-Paper Init
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
    Paint_DrawString_EN(50, 50, "Temp:       ", &Font16, WHITE, BLACK);
    Paint_DrawString_EN(50, 80, "Humi:       ", &Font16, WHITE, BLACK);
    EPD_Display_Base(Image_Mono);
    //i2c_shtc Init
    i2c_master_init();
    i2c_shtc3_init();

    xTaskCreatePinnedToCore(i2c_SHTC3_loop_task, "i2c_SHTC3_loop_task", 3 * 1024, NULL , 2, NULL,0); 

}