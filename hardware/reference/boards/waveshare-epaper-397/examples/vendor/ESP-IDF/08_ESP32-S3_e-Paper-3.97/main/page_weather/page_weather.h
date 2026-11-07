#pragma once

#include <stddef.h>
#include "esp_err.h"


typedef struct
{
//   RtcDateTime_t rtc_data;
  char calendar[33];
  /*Today's temperature, humidity and weather*/
  char td_weather[20];  //  date
  char td_Temp[32];     //  Low-temperature - high-temperature data
  char td_fx[12];       //  wind direction
  char td_week[12];     //  week
  char td_RH[15];       //  humidness 
  char td_type[12];     //  weather
  int td_aqi;           //  air quality
  /*Tomorrow's weather*/
  char tmr_weather[20];  // date
  char tmr_Temp[32];     // Low-temperature - high-temperature data
  char tmr_fx[12];       // wind direction
  char tmr_week[12];     // week
  char tmr_RH[15];       // humidness
  char tmr_type[12];     // weather
  int tmr_aqi;           // air quality
  /*The weather the day after tomorrow*/
  char tdat_weather[20];  // date
  char tdat_Temp[32];     // Low-temperature - high-temperature data
  char tdat_fx[12];       // wind direction
  char tdat_week[12];     // week
  char tdat_RH[15];       // humidness
  char tdat_type[12];     // weather
  int tdat_aqi;           // air quality
  /*The weather the day after tomorrow*/
  char stdat_weather[20];  // date
  char stdat_Temp[32];     // Low-temperature - high-temperature data
  char stdat_fx[12];       // wind direction
  char stdat_week[12];     // week
  char stdat_RH[15];       // humidness
  char stdat_type[12];     // weather
  int stdat_aqi;           // air quality
}json_data_t;


#ifdef __cplusplus
extern "C" {
#endif


esp_err_t spiffs_init(void);
void page_weather_city_select(void);
void save_city_code_to_nvs(const char* code);
int load_city_code_from_nvs(char* out_code, size_t max_len);

void amap_ip_location_fetch(void);

void weather_city_select_mode();

#ifdef __cplusplus
}
#endif