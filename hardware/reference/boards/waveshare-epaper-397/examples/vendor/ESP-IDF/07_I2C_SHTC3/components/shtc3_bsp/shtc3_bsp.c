#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "shtc3_bsp.h"
#include "i2c_bsp.h"
#include "esp_log.h"
#include "esp_check.h"
#include "esp_timer.h"
#include "esp_rom_sys.h"


static const char *TAG = "SHTC3";


typedef enum{
  READ_ID            = 0xEFC8, // command: read ID register
  SOFT_RESET         = 0x805D, // soft reset
  SLEEP              = 0xB098, // sleep
  WAKEUP             = 0x3517, // wakeup
  MEAS_T_RH_POLLING  = 0x7866, // meas. read T first, clock stretching disabled
  MEAS_T_RH_CLOCKSTR = 0x7CA2, // meas. read T first, clock stretching enabled
  MEAS_RH_T_POLLING  = 0x58E0, // meas. read RH first, clock stretching disabled
  MEAS_RH_T_CLOCKSTR = 0x5C24  // meas. read RH first, clock stretching enabled
}etCommands;

static etError SHTC3_CheckCrc(uint8_t data[], uint8_t nbrOfBytes,uint8_t checksum)
{
  uint8_t bit;        // bit mask
  uint8_t crc = 0xFF; // calculated checksum
  uint8_t byteCtr;    // byte counter

  // calculates 8-Bit checksum with given polynomial
  for(byteCtr = 0; byteCtr < nbrOfBytes; byteCtr++)
  {
    crc ^= (data[byteCtr]);
    for(bit = 8; bit > 0; --bit) {
      if(crc & 0x80) {
        crc = (crc << 1) ^ CRC_POLYNOMIAL;
      } else {
        crc = (crc << 1);
      }
    }
  }

  // verify checksum
  if(crc != checksum)
  {
    return CHECKSUM_ERROR;
  }
  else
  {
    return NO_ERROR;
  }
}
//------------------------------------------------------------------------------
etError SHTC3_GetId(uint16_t *id)
{
  uint8_t senBuf[2] = {(READ_ID>>8),(READ_ID&0xff)};
  uint8_t readBuf[3] = {0,0,0};
  int err = i2c_master_write_read_device_compat(SHTC3Addr, senBuf, 2, readBuf, 3);
  etError error = (err==ESP_OK) ? NO_ERROR : ACK_ERROR;
  if(error != NO_ERROR)
  {ESP_LOGE(TAG,"GetId WRITE Failure err:%d",err);return error;}
  error = SHTC3_CheckCrc(readBuf,2,readBuf[2]);
  if(error != NO_ERROR)
  {ESP_LOGE(TAG,"GetId CRC Failure");return error;}
  *id = ((readBuf[0] << 8) | readBuf[1]);
  return error;
}
//------------------------------------------------------------------------------
etError SHTC3_Wakeup(void)
{
  uint8_t senBuf[2] = {(WAKEUP>>8),(WAKEUP&0xff)};
  int err = i2c_write_bytes(SHTC3Addr, senBuf, 2);
  etError error = (err==ESP_OK) ? NO_ERROR : ACK_ERROR;
  esp_rom_delay_us(100); //100us
  if(error != NO_ERROR)
  ESP_LOGE(TAG,"Wakeup Failure  err:%d",err);
  return error;
}

//------------------------------------------------------------------------------
etError SHTC3_SoftReset(void)
{
  uint8_t senBuf[2] = {(SOFT_RESET>>8),(SOFT_RESET&0xff)};
  int err = i2c_write_bytes(SHTC3Addr, senBuf, 2);
  etError error = (err==ESP_OK) ? NO_ERROR : ACK_ERROR;
  if(error != NO_ERROR)
  ESP_LOGE(TAG,"SoftReset Failure   err:%d",err);
  return error;
}
//-------------------------------------------------------------------------------
static float SHTC3_CalcTemperature(uint16_t rawValue)
{
  // calculate temperature [°C]
  // T = -45 + 175 * rawValue / 2^16
  return 175 * (float)rawValue / 65536.0f - 45.0f;
}
//-------------------------------------------------------------------------------
static float SHTC3_CalcHumidity(uint16_t rawValue)
{
  // calculate relative humidity [%RH]
  // RH = rawValue / 2^16 * 100
  return 100 * (float)rawValue / 65536.0f;
}
//-------------------------------------------------------------------------------
etError SHTC3_GetTempAndHumiPolling(float *temp, float *humi)
{
  int err = 0;
  etError  error;           // error code
  uint16_t rawValueTemp;    // temperature raw value from sensor
  uint16_t rawValueHumi;    // humidity raw value from sensor
  uint8_t bytes[6] = {0};;
  uint8_t senBuf[2] = {(MEAS_T_RH_POLLING>>8),(MEAS_T_RH_POLLING&0xff)};
  err = i2c_write_bytes(SHTC3Addr, senBuf, 2);
  error = (err==ESP_OK) ? NO_ERROR : ACK_ERROR;
  if(error != NO_ERROR)
  {ESP_LOGE(TAG,"GetTempAndHumi WRITE Failure");return error;}
  
  vTaskDelay(pdMS_TO_TICKS(20));

  // if no error, read temperature and humidity raw values
  err = i2c_read_bytes(SHTC3Addr, bytes, 6);
  error = (err == ESP_OK) ? NO_ERROR : ACK_ERROR;
  if(error != NO_ERROR)
  {ESP_LOGE(TAG,"GetTempAndHumi READ Failure"); return error;}
  error = SHTC3_CheckCrc(bytes, 2, bytes[2]);
  if(error != NO_ERROR)
  {ESP_LOGE(TAG,"GetTempAndHumi TempCRC Failure"); return error;}
  error = SHTC3_CheckCrc(&bytes[3], 2, bytes[5]);
  if(error != NO_ERROR)
  {ESP_LOGE(TAG,"GetTempAndHumi humidityCRC Failure"); return error;}
  // if no error, calculate temperature in °C and humidity in %RH
  rawValueTemp = (bytes[0] << 8) | bytes[1];
  rawValueHumi = (bytes[3] << 8) | bytes[4];
  *temp = SHTC3_CalcTemperature(rawValueTemp);
  *humi = SHTC3_CalcHumidity(rawValueHumi);
  return error;
}
//------------------------------------------------------------------------------
etError SHTC3_Sleep(void)
{
  uint8_t senBuf[2] = {(SLEEP>>8),(SLEEP&0xff)};
  int err = i2c_write_bytes(SHTC3Addr, senBuf, 2);
  etError error = (err==ESP_OK) ? NO_ERROR : ACK_ERROR;
  if(error != NO_ERROR)
  ESP_LOGE(TAG,"Sleep Failure");
  return error;
}
void i2c_shtc3_task(void *arg)
{
  etError  error;       // error code
  float temperature; // temperature
  float humidity;    // relative humidity
  for(;;)
  {
    error = SHTC3_GetTempAndHumiPolling(&temperature, &humidity);
    if( error != NO_ERROR )
    {
      ESP_LOGE(TAG,"error:%d",error);
    }
    ESP_LOGI(TAG,"%.2f,%.2f",temperature, humidity);
    SHTC3_Sleep();
    vTaskDelay(pdMS_TO_TICKS(2000));
    SHTC3_Wakeup();
  }
}

/**
 * @brief Obtain environmental temperature and humidity (high-level business interface)
 * @param[out] temperature Celsius
 * @param[out] humidity Percentage of relative humidity
 * @return Success, not 0 is the error code
 */
int SHTC3_GetEnvTemperatureHumidity(float *temperature, float *humidity)
{
    etError error;
    char SHTC3_size = 3;

    if (!temperature || !humidity) return -1;

    SHTC3_Wakeup();
    do{
        vTaskDelay(pdMS_TO_TICKS(100));
        error = SHTC3_GetTempAndHumiPolling(temperature, humidity);
        if(error == NO_ERROR){
            break;
        }
        
    } while(SHTC3_size--);

    SHTC3_Sleep();

    // The temperature detected by SHTC3 is generally 1 to 3 degrees Celsius higher than the normal temperature. Here, a relatively middle value is taken for deduction
    *temperature = *temperature - 1.5;
    
    // Print the corresponding temperature and humidity data
    // ESP_LOGI(TAG,"%.2f,%.2f",*temperature, *temperature);

    return (error == NO_ERROR) ? 0 : error;
}


void i2c_shtc3_init(void)
{
    uint16_t id;
    // wake up the sensor from sleep mode
    SHTC3_Wakeup();

    // demonstartion of SoftReset command
    SHTC3_SoftReset();

    // wait for sensor to reset
    esp_rom_delay_us(100); //100us

    // demonstartion of GetId command
    SHTC3_GetId(&id);
    // ESP_LOGI(TAG,"0x%04x",id);
}