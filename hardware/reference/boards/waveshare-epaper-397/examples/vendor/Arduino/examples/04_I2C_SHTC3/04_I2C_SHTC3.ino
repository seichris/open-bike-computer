#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "EPD_3in97.h"
#include "GUI_Paint.h"
#include "fonts.h"
#include "ImageData.h"
#include "user_config.h"
#include "i2c_equipment.h"
#include "i2c_bsp.h"

i2c_equipment_shtc3 *shtc3_dev = NULL;

UBYTE *BlackImage;

void i2c_SHTC3_loop_task(void *arg)
{
  char buff[80];
  for(;;)
  {
    shtc3_data_t shtc3_data = shtc3_dev->readTempHumi();
    printf("RH:%.2f%%,Temp:%.2f°C \n",shtc3_data.RH,shtc3_data.Temp);  

    Paint_NewImage(BlackImage, Font20.Height *3, Font20.Width * 8, 270, WHITE);
    Paint_SelectImage(BlackImage);
    Paint_Clear(WHITE);

	  sprintf(buff, "%.2f%%",shtc3_data.RH);
    Paint_DrawString_EN(0, 5, buff, &Font20, WHITE, BLACK);
    sprintf(buff, "%.2f", shtc3_data.Temp);
    Paint_DrawString_EN(0, 35, buff, &Font20, WHITE, BLACK);
    Paint_DrawString_CN(Font20.Width * 5, 30, "℃", &Font12CN, WHITE, BLACK);

    EPD_3IN97_Display_Partial(BlackImage, 50, 250, 50 + Font20.Height*3, 250 + Font20.Width * 8);

    vTaskDelay(pdMS_TO_TICKS(1000));
  }
}

void setup()
{
  Serial.begin(115200);
  i2c_master_Init();
  shtc3_dev = new i2c_equipment_shtc3();

//Init e-Paper
  printf("EPD_3IN97_test Demo\r\n");
  DEV_Module_Init();

  printf("e-Paper Init and Clear...\r\n");
  EPD_3IN97_Init();
  EPD_3IN97_Clear(); // White
  DEV_Delay_ms(2000);

  UWORD Imagesize = ((EPD_3IN97_WIDTH % 8 == 0)? (EPD_3IN97_WIDTH / 8 ): (EPD_3IN97_WIDTH / 8 + 1)) * EPD_3IN97_HEIGHT;
  if((BlackImage = (UBYTE *)malloc(Imagesize)) == NULL) {
      printf("Failed to apply for black memory...\r\n");
      while(1);
  }
  printf("Paint_NewImage\r\n");
  Paint_NewImage(BlackImage, EPD_3IN97_WIDTH, EPD_3IN97_HEIGHT, 270, WHITE);

  Paint_SelectImage(BlackImage);
  Paint_Clear(WHITE);
  Paint_DrawString_EN(50, 50, "  RH:", &Font24, WHITE, BLACK);
  Paint_DrawString_EN(50, 80, "Temp:", &Font24, WHITE, BLACK);
  EPD_3IN97_Display_Base(BlackImage);
  DEV_Delay_ms(2000);

	xTaskCreatePinnedToCore(i2c_SHTC3_loop_task, "i2c_SHTC3_loop_task", 3 * 1024, NULL , 2, NULL,0); 
}

void loop() 
{
  
}
