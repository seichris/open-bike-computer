#ifndef PCF85063_BSP_H
#define PCF85063_BSP_H


#define		CONTROL_1_REG         0x00  
#define 	CONTROL_2_REG         0x01 
#define 	OFFSET_REG            0x02 
#define 	RAM_BYTE_REG          0x03 
#define		SECONDS_REG           0x04 
#define 	MINUTES_REG           0x05 
#define 	HOURS_REG             0x06 
#define 	DAYS_REG              0x07 
#define		WEEKDAYS_REG          0x08 
#define		MONTHS_REG            0x09 
#define 	YEARS_REG             0x0A 
#define 	SECOND_ALARM_REG      0x0B 
#define 	MINUTES_ALARM_REG     0x0C 
#define 	HOUR_ARARM_REG        0x0D  
#define 	DAY_ALARM_REG         0x0E
#define 	WEEKDAY_ALARM_REG     0x0F
#define 	TIMER_VALUE_REG       0x10
#define 	TIMER_MODE_REG        0x11

#define     RTC_INT_PIN           (gpio_num_t)45
#define     RTC_INT               gpio_get_level(RTC_INT_PIN)

#define     PWR_OUT_PIN           (gpio_num_t)1
#define     PWR_OUT               gpio_get_level(PWR_OUT_PIN)


typedef struct{
  uint16_t years;
  uint16_t months;
  uint16_t days;
  uint16_t hours;
  uint16_t minutes;
  uint16_t seconds;
  uint16_t week;
}Time_data;



#ifdef __cplusplus
extern "C" {
#endif

int DecToBcd(int val);
int BcdToDec(int val);
void PCF85063_init();
void PCF85063_SetTime_YMD(int Years,int Months,int Days);
void PCF85063_SetTime_HMS(int hour,int minute,int second);
Time_data PCF85063_GetTime();
void PCF85063_alarm_Time_Enabled(Time_data time);
void PCF85063_alarm_Time_Disable();
int PCF85063_get_alarm_flag();
void PCF85063_clear_alarm_flag();
void PCF85063_test();
void rtcRunAlarm(Time_data time, Time_data alarmTime);
void PCF85063_SetTime(Time_data time);

void save_mode_enable_to_nvs(char mode);
char load_mode_enable_from_nvs();

#ifdef __cplusplus
}
#endif
#endif
