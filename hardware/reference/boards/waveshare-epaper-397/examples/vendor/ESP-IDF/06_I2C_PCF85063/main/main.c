#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "epaper_bsp.h"
#include "epaper_port.h"
#include "pcf85063_bsp.h"
#include "i2c_bsp.h"
#include "esp_log.h"

uint8_t *Image_Mono;
static const char *TAG = "MAIN";

const char* weekdays_cn[] = {   "Sunday",    
                                "Monday",    
                                "Tuesday",   
                                "Wednesday", 
                                "Thursday",  
                                "Friday",    
                                "Saturday"  
                            };

//Refresh time
static void display_time_on_epaper(Time_data time)
{
    char time_str[32];
    char date_str[32];
    char week_str[16];
    
    sprintf(time_str, "%02d:%02d:%02d", time.hours, time.minutes, time.seconds);
    
    sprintf(date_str, "20%02d-%02d-%02d", time.years, time.months, time.days);
    
    if (time.week < 7) {
        sprintf(week_str, "%s", weekdays_cn[time.week]);
    } else {
        sprintf(week_str, "?");
    }
    Paint_NewImage(Image_Mono, 110, 360, 270, WHITE);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);

    Paint_DrawString_EN(80, 0, time_str, &Font24, WHITE, BLACK);
    Paint_DrawString_EN(30, 50, date_str, &Font16, WHITE, BLACK);
    Paint_DrawString_EN(200, 50, week_str, &Font16, WHITE, BLACK);

    EPD_Display_Partial(Image_Mono, 80, 0, 190, 360);
    
    vTaskDelay(pdMS_TO_TICKS(500));
}
//base map display
static void display_full_info_panel(Time_data time)
{
    
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
    
    Paint_DrawString_EN(50, 30, "RTC", &Font16, WHITE, BLACK);
    Paint_DrawLine(30, 60, 350, 60, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    
    Paint_DrawRectangle(50, 200, 350, 250, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
    Paint_DrawString_EN(60, 210, "RTC: PCF85063", &Font12, WHITE, BLACK);
    Paint_DrawString_EN(60, 230, "E-Paper: 3.97inch", &Font12, WHITE, BLACK);
    
}
// rtc task
static void rtc_test_task(void *arg)
{
    
    Time_data current_time = PCF85063_GetTime();
    
    display_full_info_panel(current_time);
    EPD_Display_Base(Image_Mono);
    vTaskDelay(pdMS_TO_TICKS(2000));
    
    while (1) {
        current_time = PCF85063_GetTime();
        
        ESP_LOGI(TAG, "20%02d-%02d-%02d %02d:%02d:%02d  %s",
                 current_time.years, current_time.months, current_time.days,
                 current_time.hours, current_time.minutes, current_time.seconds,
                 weekdays_cn[current_time.week]);
        
        display_time_on_epaper(current_time);
    
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "init e-Paper and clear");
    epaper_port_init();
    EPD_Init();
    EPD_Clear();
    vTaskDelay(pdMS_TO_TICKS(2000));
    
    if ((Image_Mono = (UBYTE *)malloc(EPD_SIZE_MONO)) == NULL) {
        ESP_LOGE(TAG, "Failed to apply for black memory...");
        return;
    }

    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
    
    //RTC Init
    i2c_master_init();
    vTaskDelay(pdMS_TO_TICKS(1000));
    
    PCF85063_init();
    vTaskDelay(pdMS_TO_TICKS(1000));
    
    Time_data current_time = PCF85063_GetTime();
    ESP_LOGI(TAG, "20%02d-%02d-%02d %02d:%02d:%02d",
             current_time.years, current_time.months, current_time.days,
             current_time.hours, current_time.minutes, current_time.seconds);
    
    if (current_time.years == 0 && current_time.months == 0) {
        
        // Set the default time
        Time_data default_time = {
            .years = 26,
            .months = 1,
            .days = 1,
            .hours = 12,
            .minutes = 0,
            .seconds = 0,
            .week = 1  // monday
        };
        
        PCF85063_SetTime(default_time);
        current_time = default_time;
        ESP_LOGI(TAG, "the default time has been set: 2026-01-01 12:00:00");
    };
    
    xTaskCreate(rtc_test_task, "rtc_display", 4096, NULL, 5, NULL);
    
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(10000));
    }
}