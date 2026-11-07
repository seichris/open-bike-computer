/**
  ******************************************************************************
  * @file    fonts.h
  * @author  MCD Application Team
  * @version V1.0.0
  * @date    18-February-2014
  * @brief   Header for fonts.c file
  ******************************************************************************
  * @attention
  *
  * <h2><center>&copy; COPYRIGHT(c) 2014 STMicroelectronics</center></h2>
  *
  * Redistribution and use in source and binary forms, with or without modification,
  * are permitted provided that the following conditions are met:
  *   1. Redistributions of source code must retain the above copyright notice,
  *      this list of conditions and the following disclaimer.
  *   2. Redistributions in binary form must reproduce the above copyright notice,
  *      this list of conditions and the following disclaimer in the documentation
  *      and/or other materials provided with the distribution.
  *   3. Neither the name of STMicroelectronics nor the names of its contributors
  *      may be used to endorse or promote products derived from this software
  *      without specific prior written permission.
  *
  * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
  * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
  * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
  * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
  * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
  * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
  * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
  *
  ******************************************************************************
  */

/* Define to prevent recursive inclusion -------------------------------------*/
#ifndef __FONTS_H
#define __FONTS_H


/* Max size of bitmap will based on a font24 (17x24) */
#define MAX_HEIGHT_FONT         41
#define MAX_WIDTH_FONT          32
#define OFFSET_BITMAP           54

#ifdef __cplusplus
 extern "C" {
#endif

/* Includes ------------------------------------------------------------------*/
#include <stdint.h>
// #include <avr/pgmspace.h>
//ASCII
typedef struct _tFont
{    
  const uint8_t *table;
  uint16_t Width;
  uint16_t Height;
  
} sFONT;

//GB2312
typedef struct                                          // 汉字字模数据结构
{
  unsigned char index[4];                               // 汉字内码索引
  const unsigned char matrix[MAX_HEIGHT_FONT*MAX_WIDTH_FONT/8 + 1];  // 点阵码数据
}CH_CN;

typedef struct
{    
  const CH_CN *table;
  uint16_t size;
  uint16_t ASCII_Width;
  uint16_t Width;
  uint16_t Height;
  
}cFONT;

extern sFONT Font24;
extern sFONT Font20;
extern sFONT Font16;
extern sFONT Font12;
extern sFONT Font8;

extern cFONT Font12CN;
extern cFONT Font24CN;
// extern const unsigned char Font16_Table[];

#ifdef __cplusplus
}
#endif

const unsigned char TEMP_str_18[] = {
    /*--  文字:  ℃  --*/
    /*--  微软雅黑18;  此字体下对应的点阵为：宽x高=24x31   --*/
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
    0xFF,0xFF,0xC3,0xFE,0x07,0x81,0xF0,0x01,0x08,0xE0,0x01,0x18,0xC0,0xF9,0x18,0x83,
    0xFF,0x00,0x87,0xFF,0x81,0x0F,0xFF,0xE7,0x0F,0xFF,0xFF,0x0F,0xFF,0xFF,0x0F,0xFF,
    0xFF,0x0F,0xFF,0xFF,0x0F,0xFF,0xFF,0x0F,0xFF,0xFF,0x0F,0xFF,0xFF,0x87,0xFF,0xFF,
    0x83,0xFF,0xFF,0xC0,0xF1,0xFF,0xE0,0x01,0xFF,0xF0,0x01,0xFF,0xFE,0x0F,0xFF,0xFF,
    0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
};
  
#endif /* __FONTS_H */
 

/************************ (C) COPYRIGHT STMicroelectronics *****END OF FILE****/
