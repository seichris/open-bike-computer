#ifndef _DEV_CONFIG_H_
#define _DEV_CONFIG_H_

#include <HardwareSerial.h>
#include <stdint.h>
#include <stdio.h>
#include <SPI.h>

#define UBYTE   uint8_t
#define UWORD   uint16_t
#define UDOUBLE uint32_t

/**
 * GPIO config
**/
#define DEV_FORCE 4
#define DEV_STANDBY 5

/**
 * GPIO read and write
**/
#define DEV_Digital_Write(_pin, _value) digitalWrite(_pin, _value == 0? LOW:HIGH)
#define DEV_Digital_Read(_pin) digitalRead(_pin)

/**
 * delay x ms
**/
#define DEV_Delay_ms(__xms)    delay(__xms)


/*-----------------------------------------------------------------------------*/
UBYTE DEV_Uart_ReceiveByte(void);
void DEV_Uart_SendByte(char data);
void DEV_Uart_SendString(char *data);
void DEV_Uart_ReceiveString(char *data, UWORD Num);

void DEV_Set_Baudrate(UDOUBLE Baudrate);

void DEV_Set_GPIOMode(UWORD Pin, UWORD mode);
#endif

