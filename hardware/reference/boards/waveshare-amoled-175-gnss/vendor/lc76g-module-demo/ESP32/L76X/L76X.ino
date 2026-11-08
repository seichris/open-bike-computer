#include <HardwareSerial.h>
#include "DEV_Config.h"
#include "L76X.h"
GNRMC GPS1;
Coordinates B_GPS;
char buff_G[800]={0};
void setup()
{
 Serial.begin(9600);

DEV_Set_Baudrate(115200);
DEV_Delay_ms(500);
}

void loop() // run over and over
{
  /*DEV_Uart_ReceiveString(buff_G,800);
  printf(buff_G);*/
  GPS1 = L76X_Gat_GNRMC();
  Serial.print("\r\n");
  Serial.print("Time:");
  Serial.print(GPS1.Time_H);
  Serial.print(":");
  Serial.print(GPS1.Time_M); 
  Serial.print(":");
  Serial.print(GPS1.Time_S);
  Serial.print("\r\n");
  Serial.print("Lat:");
  Serial.print(GPS1.Lat,7);
  Serial.print("\nLon:");
  Serial.print(GPS1.Lon,7); 
  Serial.print("\r\n");  
  B_GPS=L76X_Baidu_Coordinates();
  Serial.print("\r\n");
  Serial.print("B_Lat:");
  Serial.print(B_GPS.Lat,7);
  Serial.print("\nB_Lon:");
  Serial.print(B_GPS.Lon,7); 
  Serial.print("\r\n"); 
}

