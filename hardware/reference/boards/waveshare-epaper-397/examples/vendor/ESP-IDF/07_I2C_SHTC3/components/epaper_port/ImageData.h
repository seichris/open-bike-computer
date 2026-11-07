/*****************************************************************************
* | File      	:   ImageData.h
* | Author      :   Waveshare team
* | Function    :	
*----------------
* |	This version:   V1.0
* | Date        :   2018-10-23
* | Info        :
*
#
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

#ifndef _IMAGEDATA_H_
#define _IMAGEDATA_H_

extern const unsigned char gImage_image[];


#if defined(CONFIG_IMG_SOURCE_EMBEDDED)

// 32*32
extern const unsigned char gImage_audio[];
extern const unsigned char gImage_folder[];
extern const unsigned char gImage_picture[];
extern const unsigned char gImage_rests[];
extern const unsigned char gImage_text[];
extern const unsigned char gImage_WIFI[];
// 32*16
extern const unsigned char gImage_BAT[];

// 96*96
extern const unsigned char gImage_file[];
extern const unsigned char gImage_clock[];
extern const unsigned char gImage_calendar[];
extern const unsigned char gImage_alarm[];
extern const unsigned char gImage_weather[];
extern const unsigned char gImage_network[];
extern const unsigned char gImage_audio_file[];
extern const unsigned char gImage_read[];

// 8*26
extern const unsigned char gImage_Alarm_clock_time_point[];

// 48*48
extern const unsigned char gImage_temperature[];
extern const unsigned char gImage_humidity[];
// 42*132
extern const unsigned char gImage_point_in_time[];
// 32*32
extern const unsigned char gImage_BAT_1[];

// 36*36
extern const unsigned char gImage_fx[];
extern const unsigned char gImage_quality[];
extern const unsigned char gImage_shidu[];
extern const unsigned char gImage_sunrise[];
extern const unsigned char gImage_sunset[];
extern const unsigned char gImage_wendu[];
// 32*32
extern const unsigned char gImage_GPS[];


#elif defined(CONFIG_IMG_SOURCE_TFCARD)
// Icon position
#define BMP_FILE_PATH                       "/sdcard/GUI/file.bmp"
#define BMP_CLOCK_PATH                      "/sdcard/GUI/clock.bmp"
#define BMP_CALENDAR_PATH                   "/sdcard/GUI/calendar.bmp"
#define BMP_ALARM_PATH                      "/sdcard/GUI/alarm.bmp"
#define BMP_WEATHER_PATH                    "/sdcard/GUI/weather.bmp"
#define BMP_NETWORK_PATH                    "/sdcard/GUI/network.bmp"
#define BMP_AUDIO_FILE_PATH                 "/sdcard/GUI/audio_file.bmp"
#define BMP_READ_PATH                       "/sdcard/GUI/read.bmp"
#define BMP_BAT_PATH                        "/sdcard/GUI/BAT.bmp"
#define BMP_WIFI_PATH                       "/sdcard/GUI/WIFI.bmp"
#define BMP_Alarm_clock_time_point_PATH     "/sdcard/GUI/Alarm_clock_time_point.bmp"

#define BMP_TEXT_PATH                       "/sdcard/GUI/text.bmp"
#define BMP_AUDIO_PATH                      "/sdcard/GUI/audio.bmp"
#define BMP_RESTS_PATH                      "/sdcard/GUI/rests.bmp"

#define BMP_TEMPERATURE_PATH                "/sdcard/GUI/temperature.bmp"
#define BMP_HUMIDITY_PATH                   "/sdcard/GUI/humidity.bmp"
#define BMP_POINT_IN_TIME_PATH              "/sdcard/GUI/point_in_time.bmp"
#define BMP_BAT_1_PATH                      "/sdcard/GUI/BAT_1.bmp"

#define BMP_FX_PATH                         "/sdcard/Weather_img/fx.bmp"
#define BMP_QUALITY_PATH                    "/sdcard/Weather_img/quality.bmp"
#define BMP_SHIDU_PATH                      "/sdcard/Weather_img/shidu.bmp"
#define BMP_WENDU_PATH                      "/sdcard/Weather_img/wendu.bmp"
#define BMP_SUNRISE_PATH                    "/sdcard/Weather_img/sunrise.bmp"
#define BMP_SUNSET_PATH                     "/sdcard/Weather_img/sunset.bmp"
#define BMP_GPS_PATH                        "/sdcard/Weather_img/GPS.bmp"

#endif



#endif
/* FILE END */


