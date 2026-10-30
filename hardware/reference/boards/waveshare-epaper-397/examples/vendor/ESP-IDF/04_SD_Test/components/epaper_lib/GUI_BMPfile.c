#include <stdio.h>
#include <math.h>

#include "esp_log.h"
#include "esp_err.h"
#include "esp_heap_caps.h"

#include "GUI_BMPfile.h"
#include "GUI_Paint.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "EPD_GUI";

UBYTE GUI_ReadBmp(const char *path, UWORD Xstart, UWORD Ystart)
{
    BMPFILEHEADER bmpFileHeader;  //Define a bmp file header structure
    BMPINFOHEADER bmpInfoHeader;  //Define a bmp info header structure
    
    ESP_LOGI(TAG,"path = %s", path);

    FILE *f = fopen(path, "rb");
    if (f == NULL)
    {
        ESP_LOGE(TAG,"Cann't open the file!");
        return 0;
    }
    fseek(f, 0, SEEK_SET);
    uint32_t br = fread(&bmpFileHeader, 1 , sizeof(BMPFILEHEADER), f);
    if(br != sizeof(BMPFILEHEADER))
    {
        ESP_LOGE(TAG,"Failed to read BMP file header");
        return 0;
    }
    br = fread(&bmpInfoHeader, 1,sizeof(BMPINFOHEADER), f);
    if(br != sizeof(BMPINFOHEADER))
    {
        ESP_LOGE(TAG,"BmpInfoHeader error");
        return 0;
    }
    if((bmpInfoHeader.biWidth == 800)&&(bmpInfoHeader.biHeight == 480))
        Paint_SetRotate(0);
    else if((bmpInfoHeader.biWidth == 480)&&(bmpInfoHeader.biHeight == 800))
        Paint_SetRotate(90);

    ESP_LOGI(TAG,"pixel = %lu * %lu", (unsigned long)bmpInfoHeader.biWidth, (unsigned long)bmpInfoHeader.biHeight);

    // Determine if it is a monochrome bitmap
    int readbyte = bmpInfoHeader.biBitCount;
    if(readbyte != 1) {
        ESP_LOGI(TAG,"the bmp Image is not a monochrome bitmap!");
    }

    UWORD Image_Width_Byte = (bmpInfoHeader.biWidth % 8 == 0)? (bmpInfoHeader.biWidth / 8): (bmpInfoHeader.biWidth / 8 + 1);
    UWORD Bmp_Width_Byte = (Image_Width_Byte % 4 == 0) ? Image_Width_Byte: ((Image_Width_Byte / 4 + 1) * 4);

    // Determine black and white based on the palette
    UWORD i;
    UWORD Bcolor, Wcolor;
    UWORD bmprgbquadsize = pow(2, bmpInfoHeader.biBitCount);// 2^1 = 2
    BMPRGBQUAD bmprgbquad[bmprgbquadsize];        //palette
    // BMPRGBQUAD bmprgbquad[2];        //palette

    for(i = 0; i < bmprgbquadsize; i++){
    // for(i = 0; i < 2; i++) {
        fread(&bmprgbquad[i], sizeof(BMPRGBQUAD), 1, f);
    }
    if(bmprgbquad[0].rgbBlue == 0xff && bmprgbquad[0].rgbGreen == 0xff && bmprgbquad[0].rgbRed == 0xff) {
        Bcolor = BLACK;
        Wcolor = WHITE;
    } else {
        Bcolor = WHITE;
        Wcolor = BLACK;
    }

    // Read image data into the cache
    UWORD x, y;
    UBYTE Rdata;
    UBYTE color;
    fseek(f, bmpFileHeader.bOffset, SEEK_SET);
    for(y = 0; y < bmpInfoHeader.biHeight; y++) {//Total display column
        for(x = 0; x < Bmp_Width_Byte; x++) {//Show a line in the line
            if(fread((char *)&Rdata, 1, readbyte, f) != readbyte) {
                perror("get bmpdata:\r\n");
                break;
            }
            if(x < Image_Width_Byte) { //bmp
                for (size_t i = 0; i < 8; i++)
                {
                    color = (((Rdata << (i%8)) & 0x80) == 0x80) ?Bcolor:Wcolor;
                    if(x*8+i >= (unsigned long)bmpInfoHeader.biWidth) break;
                    Paint_SetPixel(Xstart + x*8 + i , Ystart+bmpInfoHeader.biHeight-1-y, color);
                }
            }
        }
        // When reading a large amount of data, increase the delay to facilitate the CPU in processing the content of other threads
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    fclose(f);

    return 0;
}
/*************************************************************************

*************************************************************************/
UBYTE GUI_ReadBmp_4Gray(const char *path, UWORD Xstart, UWORD Ystart)
{
    FILE *fp;                     //Define a file pointer
    BMPFILEHEADER bmpFileHeader;  //Define a bmp file header structure
    BMPINFOHEADER bmpInfoHeader;  //Define a bmp info header structure
    // Binary file open
    if((fp = fopen(path, "rb")) == NULL) {
        ESP_LOGI(TAG,"Cann't open the file!");
        exit(0);
    }
 
    // Set the file pointer from the beginning
    fseek(fp, 0, SEEK_SET);
    fread(&bmpFileHeader, sizeof(BMPFILEHEADER), 1, fp);    //sizeof(BMPFILEHEADER) must be 14
    fread(&bmpInfoHeader, sizeof(BMPINFOHEADER), 1, fp);    //sizeof(BMPFILEHEADER) must be 50
    ESP_LOGI(TAG,"pixel = %lu * %lu", (unsigned long)bmpInfoHeader.biWidth, (unsigned long)bmpInfoHeader.biHeight);

    if((bmpInfoHeader.biWidth == 800)&&(bmpInfoHeader.biHeight == 480))
        Paint_SetRotate(0);
    else if((bmpInfoHeader.biWidth == 480)&&(bmpInfoHeader.biHeight == 800))
        Paint_SetRotate(90);

    UWORD Image_Width_Byte = (bmpInfoHeader.biWidth % 4 == 0)? (bmpInfoHeader.biWidth / 4): (bmpInfoHeader.biWidth / 4 + 1);
    UWORD Bmp_Width_Byte = (bmpInfoHeader.biWidth % 2 == 0)? (bmpInfoHeader.biWidth / 2): (bmpInfoHeader.biWidth / 2 + 1);

    int readbyte = bmpInfoHeader.biBitCount;
    ESP_LOGI(TAG,"biBitCount = %d",readbyte);
    if(readbyte != 4){
        ESP_LOGI(TAG,"Bmp image is not a 4-color bitmap!\n");
        exit(0);
    }
    // Read image data into the cache
    UWORD x, y;
    UBYTE Rdata;
    UBYTE color, temp;
    fseek(fp, bmpFileHeader.bOffset, SEEK_SET);
    
    for(y = 0; y < bmpInfoHeader.biHeight; y++) {//Total display column
        for(x = 0; x < Bmp_Width_Byte; x++) {//Show a line in the line
            if(fread((char *)&Rdata, 1, 1, fp) != 1) {
                perror("get bmpdata:\r\n");
                break;
            }
            if(x < Image_Width_Byte*2) { //bmp
                for (size_t i = 0; i < 2; i++)
                {
                    temp = Rdata >> ((i%2)? 0:4);//0xf 0x8 0x7 0x0 

                    // Choose one of the two color options(All the four-grayscale images of Waveshare are based on the first type)
                    color = temp>>2;                           //11  10  01  00  
                    // if(temp==0) {
                    //     color = 0;
                    // } else if(temp==7) {
                    //     color = 1;
                    // } else if(temp>3) {
                    //     color = 3;
                    // } else {
                    //     color = 2;
                    // }

                    Paint_SetPixel(Xstart + x*2 +i, Ystart+bmpInfoHeader.biHeight-1-y, color);
                }
            }
        }
        // When reading a large amount of data, increase the delay to facilitate the CPU in processing the content of other threads
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    fclose(fp);
    return 0;
}
