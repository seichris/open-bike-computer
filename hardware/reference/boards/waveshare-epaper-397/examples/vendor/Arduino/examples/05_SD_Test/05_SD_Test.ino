#include "EPD_3IN97.h"
#include "GUI_Paint.h"
#include "fonts.h"
#include "ImageData.h"
#include "Arduino.h"
#include "SD_MMC.h"
#include "GUI_BMPfile.h"
#include "FS.h"

#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "driver/sdmmc_host.h"

#define SD_CLK  16
#define SD_CMD  17
#define SD_D0   15
#define SD_D1   7
#define SD_D2   8
#define SD_D3   18

#define MOUNT_POINT "/sdcard"

void setup() {
    //sdcard init
    Serial.begin(115200);
    delay(1000); 
    SD_MMC.setPins(SD_CLK, SD_CMD, SD_D0, SD_D1, SD_D2, SD_D3);
    if (!SD_MMC.begin("/sdcard", true)) { 
        printf("SD card failed to mount\r\n");
        return;
    }
    printf("SD card success to mount\r\n");

    printf("EPD_3IN97_test Demo\r\n");
    DEV_Module_Init();

    //e-Paper init
    printf("e-Paper Init and Clear...\r\n");
    EPD_3IN97_Init();
    EPD_3IN97_Clear(); // White
    DEV_Delay_ms(2000);

    UBYTE *Image;
    UDOUBLE Imagesize = ((EPD_3IN97_WIDTH % 8 == 0)? (EPD_3IN97_WIDTH / 8 ): (EPD_3IN97_WIDTH / 8 + 1)) * EPD_3IN97_HEIGHT;
    if((Image = (UBYTE *)malloc(Imagesize)) == NULL) {
        printf("1.Failed to apply for black memory...\r\n");

    }
    Paint_NewImage(Image, EPD_3IN97_WIDTH, EPD_3IN97_HEIGHT, 0, WHITE);
    Paint_SetScale(2);

    printf("show BMP-------------------------\r\n");
    EPD_3IN97_Init_Fast();

    Paint_Clear(WHITE);
    GUI_ReadBmp("/sdcard/bmp/100x100.bmp", 50, 50);
    EPD_3IN97_Display_Fast(Image);
    printf("100*100 BMP Load OK!\r\n");
    DEV_Delay_ms(1000);

    Paint_Clear(WHITE);
    GUI_ReadBmp("/sdcard/bmp/3in97.bmp",0 ,0);
    EPD_3IN97_Display_Fast(Image);
    printf("800*480 BMP Load OK!\r\n");
    DEV_Delay_ms(3000);


    free(Image);
    printf("show Gray------------------------\r\n");
    Imagesize = ((EPD_3IN97_WIDTH % 4 == 0)? (EPD_3IN97_WIDTH / 4 ): (EPD_3IN97_WIDTH / 4 + 1)) * EPD_3IN97_HEIGHT;
    if((Image = (UBYTE *)malloc(Imagesize)) == NULL) {
        printf("2.Failed to apply for black memory...\r\n");

    }
    EPD_3IN97_Init_4GRAY();
    Paint_NewImage(Image, EPD_3IN97_WIDTH, EPD_3IN97_HEIGHT, 0, WHITE);
    Paint_SetScale(4);
    Paint_Clear(WHITE);
    if(GUI_ReadBmp_4Gray("/sdcard/bmp/3in97_4Gray.bmp", 0, 0) == 0){
        printf("4Gray BMP Load OK!\r\n");
    }else{
        printf("4Gray BMP Load Failed!\r\n");
    }
    EPD_3IN97_Display_4Gray(Image);
    DEV_Delay_ms(3000);

    printf("Clear...\r\n");
    EPD_3IN97_Init();
    EPD_3IN97_Clear();
    DEV_Delay_ms(2000);

    printf("Goto Sleep...\r\n");
    EPD_3IN97_Sleep();
    free(Image);
    Image = NULL;
    DEV_Delay_ms(2000);//important, at least 2s
    // close 5V
    printf("close 5V, Module enters 0 power consumption ...\r\n");
    DEV_Module_Exit();

}


void loop() {

}