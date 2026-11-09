/*****************************************************************************
* | File        :   DEV_Config.c
* | Author      :   Waveshare team
* | Function    :   Hardware underlying interface
* | Info        :
*                Used to shield the underlying layers of each master 
*                and enhance portability
*----------------
* | This version:   V1.0
* | Date        :   2018-11-22
* | Info        :

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documnetation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to  whom the Software is
# furished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS OR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
******************************************************************************/
#include "DEV_Config.h"


/******************************************************************************
function: 
  Uart receiving and sending
******************************************************************************/
UBYTE DEV_Uart_ReceiveByte()
{
  while(1){
    if(Serial2.available()){
      return  Serial2.read();
    }
  }
}

void DEV_Uart_SendByte(char data)
{
  Serial2.write(data);
}

void DEV_Uart_SendString(char *data)
{
  UWORD i;
  for(i=0; data[i] != '\0'; i++){
    Serial2.write(data[i]);
  }
}

void DEV_Uart_ReceiveString(char *data, UWORD Num)
{  
  UWORD i;
  while(1){
    if(Serial2.available()){
        data[i] =  Serial2.read();
        i++;
        //Serial.print(data[i]);
        if(i >= Num){
            break;
          }
      }
   }

  data[Num-1] = '\0';
}

void DEV_Set_GPIOMode(UWORD Pin, UWORD mode)
{

  if(mode == 1){
    pinMode(Pin, INPUT);
  }
  else if(mode == 0){
    pinMode(Pin, OUTPUT);
  }
}


void DEV_Set_Baudrate(UDOUBLE Baudrate)
{
  Serial2.begin(Baudrate);
}

