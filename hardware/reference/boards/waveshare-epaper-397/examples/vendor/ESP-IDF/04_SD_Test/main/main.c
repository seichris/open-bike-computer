#include <stdio.h>
#include "epaper_bsp.h"
#include "epaper_port.h"
#include "esp_log.h"
#include "sdcard_bsp.h"
#include "ImageData.h"

static const char *TAG = "main";

void app_main(void)
{
    //sdcard init
    _sdcard_init();
    if(card_host == NULL) {
        ESP_LOGI(TAG,"SD card init failed");
        return;
    }else{
        ESP_LOGI(TAG,"SD card init success");
    }

    //traverse the BMP file and printf
    // sdcard_queuehandle = xQueueCreate(20, sizeof(char)*300);
    // scan_files("/sdcard/bmp");

    ESP_LOGI(TAG,"e-Paper Init and Clear...");
    epaper_port_init();
    EPD_Init();
    EPD_Clear();
    vTaskDelay(pdMS_TO_TICKS(2000));

    //Create a new image cache
    UBYTE *BlackImage;
    UDOUBLE Imagesize = ((EPD_WIDTH % 8 == 0)? (EPD_WIDTH / 8 ): (EPD_WIDTH / 8 + 1)) * EPD_HEIGHT;
    if((BlackImage = (UBYTE *)malloc(Imagesize)) == NULL) {
       ESP_LOGI(TAG,"1.Failed to apply for black memory...");
        return ;
    }
    ESP_LOGI(TAG,"Paint_NewImage");
    Paint_NewImage(BlackImage, EPD_WIDTH, EPD_HEIGHT, 0, WHITE);
    Paint_SetScale(2);
    //show bmp
    ESP_LOGI(TAG,"show 100*100 BMP-----------------");
    EPD_Init_Fast();
    Paint_Clear(WHITE);
    GUI_ReadBmp("/sdcard/bmp/100x100.bmp", 50, 50);
    EPD_Display_Fast(BlackImage);
    vTaskDelay(pdMS_TO_TICKS(1000));

    ESP_LOGI(TAG,"show 800*480 bmp------------------------");
    Paint_Clear(WHITE);    
    GUI_ReadBmp("/sdcard/bmp/3in97.bmp", 0, 0);
    EPD_Display_Fast(BlackImage);
    vTaskDelay(pdMS_TO_TICKS(2000));
    
    //show 4Gray bmp
    free(BlackImage);
    Imagesize = ((EPD_WIDTH % 4 == 0)? (EPD_WIDTH / 4 ): (EPD_WIDTH / 4 + 1)) * EPD_HEIGHT;
    if((BlackImage = (UBYTE *)malloc(Imagesize)) == NULL) {
       ESP_LOGI(TAG,"2.Failed to apply for black memory...");
        return ;
    }
    ESP_LOGI(TAG,"show Gray------------------------");
    EPD_Init_4GRAY();
    Paint_NewImage(BlackImage, EPD_WIDTH, EPD_HEIGHT, 0, WHITE);
    Paint_SetScale(4);
    Paint_Clear(WHITE);
    if(GUI_ReadBmp_4Gray("/sdcard/bmp/3in97_4Gray.bmp", 0, 0) == 0){
        ESP_LOGI(TAG,"4Gray BMP Load OK!");
    }else{
        ESP_LOGI(TAG,"4Gray BMP Load Failed!");
    }
    EPD_Display_4Gray(BlackImage);
    vTaskDelay(pdMS_TO_TICKS(3000));

    ESP_LOGI(TAG,"Clear...");
    EPD_Init();
    EPD_Clear();
    vTaskDelay(pdMS_TO_TICKS(2000));

    ESP_LOGI(TAG,"Goto Sleep...");
    EPD_Sleep();
    free(BlackImage);
    BlackImage = NULL;
    vTaskDelay(pdMS_TO_TICKS(2000));//important, at least 2s
    // close 5V
    ESP_LOGI(TAG,"close 5V, Module enters 0 power consumption ...");

}

