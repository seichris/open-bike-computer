#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "EPD_3in97.h"
#include "GUI_Paint.h"
#include "fonts.h"
#include "ImageData.h"
#include "user_config.h"
#include "i2c_equipment.h"
#include "i2c_bsp.h"

i2c_equipment *rtc_dev = NULL;

UBYTE *BlackImage;

//show Time
void i2c_rtc_loop_task(void *arg)
{
  char buff[80];
  for(;;)
  {
    RtcDateTime_t datetime = rtc_dev->get_rtcTime();
    printf("%d/%d/%d %d:%d:%d \n",datetime.year,datetime.month,datetime.day,datetime.hour,datetime.minute,datetime.second);  

    Paint_NewImage(BlackImage, Font20.Height *3, Font20.Width * 8, 270, WHITE);
    Paint_SelectImage(BlackImage);
    Paint_Clear(WHITE);

	  sprintf(buff, "%d-%d-%d", datetime.year,datetime.month,datetime.day);
    Paint_DrawString_EN(0, 5, buff, &Font20, WHITE, BLACK);
    sprintf(buff, "%d:%d:%d", datetime.hour,datetime.minute,datetime.second);
    Paint_DrawString_EN(0, 35, buff, &Font20, WHITE, BLACK);

    EPD_3IN97_Display_Partial(BlackImage, 50, 250, 50 + Font20.Height*3 , 250 + Font20.Width * 8);

    vTaskDelay(pdMS_TO_TICKS(500));
  }
}

void setup()
{
  Serial.begin(115200);
  i2c_master_Init();
  rtc_dev = new i2c_equipment();
  rtc_dev->set_rtcTime(2026,1,1,8,30,30);

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
  Paint_DrawString_EN(50, 50, "Date:", &Font24, WHITE, BLACK);
  Paint_DrawString_EN(50, 80, "Time:", &Font24, WHITE, BLACK);
  EPD_3IN97_Display_Base(BlackImage);
  DEV_Delay_ms(2000);

  xTaskCreatePinnedToCore(i2c_rtc_loop_task, "i2c_rtc_loop_task", 3 * 1024, NULL , 2, NULL,0); 
}

void loop() 
{
  
}
