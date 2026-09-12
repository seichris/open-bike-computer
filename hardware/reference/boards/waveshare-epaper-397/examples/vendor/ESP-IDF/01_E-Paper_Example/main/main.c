#include <stdio.h>
#include "epaper_bsp.h"
#include "epaper_port.h"
#include "esp_log.h"

// Define the data cache area of the e-ink screen
uint8_t *Image_Mono;
// Log tag
static const char *TAG = "main";

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

#if 1
    ESP_LOGI(TAG,"2.show BMP");
    EPD_Init_Fast();
    EPD_Display(gImage_image);
    vTaskDelay(pdMS_TO_TICKS(2000));
#endif

#if 1
    ESP_LOGI(TAG,"3.Paint_NewImage");
    EPD_Init();
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 0, WHITE);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
    // Drawing on the image
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

    Paint_DrawNum(5, 180, 123456789, &Font24, BLACK, WHITE);
    Paint_DrawString_CN(5, 100,"你好abc", &Font16_UTF8, BLACK, WHITE);
    Paint_DrawString_CN(5, 130, "微雪电子", &Font24_UTF8, WHITE, BLACK);

    EPD_Display_Base(Image_Mono);
    vTaskDelay(pdMS_TO_TICKS(2000));
#endif

#if 1   //Partial refresh, example shows time   
	Paint_NewImage(Image_Mono, Font16.Width * 7, Font16.Height, 0, WHITE);
    ESP_LOGI(TAG,"4.Partial refresh");
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
	
    PAINT_TIME sPaint_time;
    sPaint_time.Hour = 12;
    sPaint_time.Min = 34;
    sPaint_time.Sec = 56;
    UBYTE num = 10;
    for (;;) {
        sPaint_time.Sec = sPaint_time.Sec + 1;
        if (sPaint_time.Sec == 60) {
            sPaint_time.Min = sPaint_time.Min + 1;
            sPaint_time.Sec = 0;
            if (sPaint_time.Min == 60) {
                sPaint_time.Hour =  sPaint_time.Hour + 1;
                sPaint_time.Min = 0;
                if (sPaint_time.Hour == 24) {
                    sPaint_time.Hour = 0;
                    sPaint_time.Min = 0;
                    sPaint_time.Sec = 0;
                }
            }
        }
        Paint_ClearWindows(0, 0, Font16.Width * 7, Font16.Height, WHITE);
        Paint_DrawTime(0, 0, &sPaint_time, &Font16, WHITE, BLACK);

        num = num - 1;
        if(num == 0) {
            break;
        }
		EPD_Display_Partial(Image_Mono, 150, 300, 150 + Font16.Width * 7, 300 + Font16.Height);
        vTaskDelay(pdMS_TO_TICKS(500));
    }

#endif

#if 1 // show image for array
    EPD_Init_4GRAY();
    printf("4 grayscale display\r\n");
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT , 0, WHITE);
    Paint_SetScale(4);
    Paint_Clear(WHITE);
    
    Paint_DrawPoint(5, 110, GRAY4, DOT_PIXEL_1X1, DOT_STYLE_DFT); 
    Paint_DrawPoint(5, 120, GRAY4, DOT_PIXEL_2X2, DOT_STYLE_DFT); 
    Paint_DrawPoint(5, 130, GRAY4, DOT_PIXEL_3X3, DOT_STYLE_DFT);
    Paint_DrawLine(15, 100, 65, 150, GRAY4, DOT_PIXEL_1X1, LINE_STYLE_SOLID); 
    Paint_DrawLine(65, 100, 15, 150, GRAY4, DOT_PIXEL_1X1, LINE_STYLE_SOLID); 
    Paint_DrawRectangle(15, 100, 65, 150, GRAY4, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
    Paint_DrawRectangle(75, 100, 125, 150, GRAY4, DOT_PIXEL_1X1, DRAW_FILL_FULL); 
    Paint_DrawCircle(40, 125, 20, GRAY4, DOT_PIXEL_1X1, DRAW_FILL_EMPTY); 
    Paint_DrawCircle(100, 125, 20, GRAY2, DOT_PIXEL_1X1, DRAW_FILL_FULL); 
    Paint_DrawLine(80, 125, 120, 125, GRAY4, DOT_PIXEL_1X1, LINE_STYLE_DOTTED); 
    Paint_DrawLine(100, 105, 100, 145, GRAY4, DOT_PIXEL_1X1, LINE_STYLE_DOTTED); 

    Paint_DrawString_EN(5, 0, "waveshare", &Font16, GRAY4, GRAY1);
    Paint_DrawString_EN(5, 30, "hello world", &Font12, GRAY3, GRAY1);
    Paint_DrawNum(5, 55, 123456789, &Font12, GRAY4, GRAY2);
    Paint_DrawNum(5, 75, 987654321, &Font12, GRAY1, GRAY4);
    Paint_DrawString_CN(150, 0,"你好abc", &Font12_UTF8, GRAY4, GRAY1);
    Paint_DrawString_CN(150, 20,"你好abc", &Font12_UTF8, GRAY3, GRAY2);
    Paint_DrawString_CN(150, 40,"你好abc", &Font12_UTF8, GRAY2, GRAY3);
    Paint_DrawString_CN(150, 60,"你好abc", &Font12_UTF8, GRAY1, GRAY4);
    Paint_DrawString_CN(5, 160, "微雪电子", &Font16_UTF8, GRAY1, GRAY4);
    
    EPD_Display_4Gray(Image_Mono);
    vTaskDelay(pdMS_TO_TICKS(3000));
#endif
    ESP_LOGI(TAG,"Clear...");
    EPD_Init();
    EPD_Clear();

    ESP_LOGI(TAG,"Goto Sleep");
    EPD_Sleep();
    vTaskDelay(pdMS_TO_TICKS(2000));

}