#include <stdio.h>
#include <string.h>
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "GUI_BMPfile.h"
#include "GUI_Paint.h"

#include "epaper_bsp.h"
#include "epaper_port.h"
#include "GUI_BMPfile.h"
#include "GUI_Paint.h"
#include "Debug.h"
#include "ImageData.h"

static const char *TAG = "EPD_BSP";

int EPD_display_BMP()
{
    esp_err_t err = ESP_FAIL;
    EPD_Init();
    UBYTE *BlackImage;
    UDOUBLE Imagesize = ((EPD_WIDTH % 8 == 0)? (EPD_WIDTH / 8 ): (EPD_WIDTH / 8 + 1)) * EPD_HEIGHT;
    if((BlackImage = (UBYTE *)heap_caps_malloc(Imagesize,MALLOC_CAP_SPIRAM)) == NULL) 
    {
        ESP_LOGE(TAG,"Failed to apply for black memory...");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG,"Paint_NewImage");
    Paint_NewImage(BlackImage, EPD_WIDTH, EPD_HEIGHT, 0, WHITE);
    Paint_SetScale(2);

    Paint_SelectImage(BlackImage);
    Paint_Clear(WHITE);

    // 2.Drawing on the image
    Paint_DrawPoint(5, 10, BLACK, DOT_PIXEL_1X1, DOT_STYLE_DFT);
    Paint_DrawPoint(5, 25, BLACK, DOT_PIXEL_2X2, DOT_STYLE_DFT);
    Paint_DrawPoint(5, 40, BLACK, DOT_PIXEL_3X3, DOT_STYLE_DFT);
    Paint_DrawPoint(5, 55, BLACK, DOT_PIXEL_4X4, DOT_STYLE_DFT);

    Paint_DrawLine(20, 10, 70, 60, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    Paint_DrawLine(70, 10, 20, 60, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    Paint_DrawLine(170, 15, 170, 55, BLACK, DOT_PIXEL_1X1, LINE_STYLE_DOTTED);
    Paint_DrawLine(150, 35, 190, 35, BLACK, DOT_PIXEL_1X1, LINE_STYLE_DOTTED);

    Paint_DrawRectangle(20, 10, 70, 60, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
    Paint_DrawRectangle(85, 10, 130, 60, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);

    Paint_DrawCircle(170, 35, 20, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
    Paint_DrawCircle(170, 85, 20, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_EN(5, 100, "1234589", &Font18, BLACK, WHITE);
    Paint_DrawNum(5, 150, 123456789, &Font24, BLACK, WHITE);

    Paint_DrawString_CN(5, 200,"你好abc", &Font16_UTF8, BLACK, WHITE);
    Paint_DrawString_CN(5, 250, "微雪电子", &Font24_UTF8, WHITE, BLACK);

    Paint_DrawString_EN(5, 300, "aab1234567890", &Font24, BLACK, WHITE);
    Paint_DrawNum(5, 350, 123456789, &Font28, BLACK, WHITE);

    EPD_Display(BlackImage);

    EPD_Sleep();
    heap_caps_free(BlackImage);
    BlackImage = NULL;
    //updatePathIndex();
    return err;
}

int EPD_display(const UBYTE *Image)
{
    ESP_LOGI(TAG,"Initializing e-paper display");
    EPD_Init();
    vTaskDelay(pdMS_TO_TICKS(500));
    ESP_LOGI(TAG,"Clear");
    EPD_Display(Image);
    vTaskDelay(pdMS_TO_TICKS(1000));
    ESP_LOGI(TAG,"Sleep");
    EPD_Sleep();
    return 0;
}

int EPD_display_Clear()
{
    ESP_LOGI(TAG,"Initializing e-paper display");
    EPD_Init();
    vTaskDelay(pdMS_TO_TICKS(500));
    ESP_LOGI(TAG,"Clear");
    EPD_Display(gImage_image);
    // EPD_Clear();
    vTaskDelay(pdMS_TO_TICKS(1000));
    ESP_LOGI(TAG,"Sleep");
    EPD_Sleep();
    return 0;
}





