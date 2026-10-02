#include "page_alarm.h"
#include <stdio.h>
#include <string.h>
#include "nvs.h"
#include "nvs_flash.h"
#include "esp_log.h"

#include "button_bsp.h"
#include "pcf85063_bsp.h"
#include "axp_prot.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "epaper_port.h"
#include "GUI_BMPfile.h"
#include "GUI_Paint.h"

#include "page_audio.h"

extern SemaphoreHandle_t alarm_mutex; // Protect alarms
extern SemaphoreHandle_t rtc_mutex;   // Protect RTC
extern bool wifi_enable;              // Is the wifi turned on?

Alarm alarms[MAX_ALARMS] = {0};

static const char *TAG = "alarm";

// 定义墨水屏的数据缓存区
uint8_t *Image_alarm;

// E-ink screen sleep time (S)
#define EPD_Sleep_Time   60
// Equipment shutdown time (minutes)
#define Unattended_Time  10


static void display_alarm_init(void);
void Forced_refresh_alarm(void);
void Refresh_page_alarm(void);
static void display_alarm_enabled_img(int enabled, int count, int en);
static void display_alarm_minute_img(int minute, int count, int en);
static void display_alarm_hour_img(int hour, int count, int en);

// display options
static void display_alarm_option(void);
static void display_alarm_option_img(void);
static void display_alarm_option_img_Up_Down(int count, int enabled);
static void display_alarm_time_img(Time_data rtc_time);

// Alarm clock selection
static void display_alarm_selection(int count);

typedef void (*alarm_callback_t)(uint8_t hour, uint8_t minute);
static alarm_callback_t alarm_cb = NULL;

void register_alarm_callback(alarm_callback_t cb) {
    alarm_cb = cb;
}

// Call the alarm clock at the place where it is detected once every minute
void alarm_check_and_trigger(uint8_t hour, uint8_t minute) {
    if (check_alarm(hour, minute)) {
        if (alarm_cb) {
            alarm_cb(hour, minute);
        }
    }
}


// Comparison function: Sort in chronological order
static int alarm_compare(const void* a, const void* b) {
    const Alarm* aa = (const Alarm*)a;
    const Alarm* bb = (const Alarm*)b;
    if (aa->enabled != bb->enabled) return bb->enabled - aa->enabled; // The enabled ones are at the front
    if (!aa->enabled) return 0;
    if (aa->hour != bb->hour) return aa->hour - bb->hour;
    return aa->minute - bb->minute;
}

// Add an alarm clock for automatic sorting
bool add_alarm(uint8_t hour, uint8_t minute) {
    // Search for vacancies
    int idx = -1;
    for (int i = 0; i < MAX_ALARMS; ++i) {
        if (!alarms[i].enabled) {
            idx = i;
            break;
        }
    }
    if (idx == -1) return false; // be already full

    alarms[idx].hour = hour;
    alarms[idx].minute = minute;
    alarms[idx].enabled = 1;

    // sequence 
    qsort(alarms, MAX_ALARMS, sizeof(Alarm), alarm_compare);
    save_alarms_to_nvs();
    return true;
}

// Set the switch status of the specified alarm clock
bool set_alarm_enabled(uint8_t hour, uint8_t minute, uint8_t enabled) {
    for (int i = 0; i < MAX_ALARMS; ++i) {
        if (alarms[i].hour == hour && alarms[i].minute == minute) {
            alarms[i].enabled = enabled ? 1 : 0;
            save_alarms_to_nvs();
            return true;
        }
    }
    return false;
}

// Delete the alarm clock
bool remove_alarm(uint8_t hour, uint8_t minute) {
    for (int i = 0; i < MAX_ALARMS; ++i) {
        if (alarms[i].enabled && alarms[i].hour == hour && alarms[i].minute == minute) {
            alarms[i].enabled = 0;
            qsort(alarms, MAX_ALARMS, sizeof(Alarm), alarm_compare);
            save_alarms_to_nvs();
            return true;
        }
    }
    return false;
}

// Check if there is an alarm at the current time
bool check_alarm(uint8_t hour, uint8_t minute) {
    for (int i = 0; i < MAX_ALARMS; ++i) {
        if (alarms[i].enabled && alarms[i].hour == hour && alarms[i].minute == minute) {
            return true;
        }
    }
    return false;
}

// Print all the alarm clocks
void print_alarms(void) {
    printf("当前闹钟：\n");
    for (int i = 0; i < MAX_ALARMS; ++i) {
        if (alarms[i].enabled) {
            printf("%02d:%02d\n", alarms[i].hour, alarms[i].minute);
        }
    }
}

// Save the alarm clock to NVS
void save_alarms_to_nvs(void) {
    nvs_handle_t handle;
    if (nvs_open("alarm", NVS_READWRITE, &handle) == ESP_OK) {
        nvs_set_blob(handle, "alarms", alarms, sizeof(alarms));
        nvs_commit(handle);
        nvs_close(handle);
    }
}

// Read the alarm clock from NVS
void load_alarms_from_nvs(void) {
    nvs_handle_t handle;
    size_t required_size = sizeof(alarms);
    if (nvs_open("alarm", NVS_READONLY, &handle) == ESP_OK) {
        nvs_get_blob(handle, "alarms", alarms, &required_size);
        nvs_close(handle);
    }
}

// Sleep-wake function
int Sleep_wake_alarm()
{
    int button = 0;
    int sleep_js = 0;
    Time_data rtc_time = {0};
    int last_minutes = -1;
    ESP_LOGI("home", "EPD_Sleep");
    EPD_Sleep();
    while(1)
    {
        button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        if (button == 12){
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            // Forced_refresh_audio(Image_Mono);
            break;
        } else if (button == 8 || button == 22 || button == 14 || button == 0 || button == 7){
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            Refresh_page_alarm();
            break;
        } 
        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        if(rtc_time.minutes != last_minutes) {
            last_minutes = rtc_time.minutes;
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            // display_audio_time_last(rtc_time);
            Refresh_page_alarm();
            display_alarm_time_img(rtc_time);
            Refresh_page_alarm();
            ESP_LOGI("home", "EPD_Sleep");
            EPD_Sleep();
            sleep_js++;
            if(sleep_js > Unattended_Time){
                ESP_LOGI("home", "pwr_off");
                axp_pwr_off();
            }
        }
    }
    return button;
}

// Edit the attributes of a single alarm clock (hours, minutes, on/off)
static void edit_alarm_item(int idx) {
    enum { EDIT_HOUR, EDIT_MIN, EDIT_ENABLE, EDIT_DONE };
    int attr = 0;
    int editing = 0;
    int temp_hour = alarms[idx].hour;
    int temp_min = alarms[idx].minute;
    int temp_en = alarms[idx].enabled;

    int js = 0;

    int button = 0;
    int time_count = 0;
    Time_data rtc_time = {0};
    int last_minutes = -1;

    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);
    last_minutes = rtc_time.minutes;

    // display options

    display_alarm_option_img();

    while (1) {
        button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        if(button == -1) time_count++;

        if(time_count >= EPD_Sleep_Time){
            button = Sleep_wake_alarm();
            time_count = 0;
        }

        if (button == 14) { // The next attribute
            attr = (attr + 1) % 4;
            display_alarm_option_img_Up_Down(attr,0);
            time_count = 0;
        } else if (button == 0) { // The previous attribute
            attr = (attr - 1 + 4) % 4;
            display_alarm_option_img_Up_Down(attr,0);
            time_count = 0;
        } else if (button == 7) { // affirm
            display_alarm_option_img_Up_Down(attr,1);
            time_count = 0;
            if (attr == EDIT_HOUR) {
                while(1)
                {
                    button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
                    if(button == -1) time_count++;
                    if(time_count >= EPD_Sleep_Time){
                        button = Sleep_wake_alarm();
                    }
                    if(button == 14) {
                        temp_hour = (temp_hour + 1) % 24;
                        display_alarm_hour_img(temp_hour, idx, 1);
                        time_count = 0;
                    } else if(button == 0) {
                        temp_hour = (temp_hour - 1 + 24) % 24;
                        display_alarm_hour_img(temp_hour, idx, 1);
                        time_count = 0;
                    } else if(button == 20) {
                        temp_hour = (temp_hour + 1) % 24;
                        display_alarm_hour_img(temp_hour, idx, 1);
                        time_count = 0;
                    } else if(button == 6) {
                        temp_hour = (temp_hour - 1 + 24) % 24;
                        display_alarm_hour_img(temp_hour, idx, 1);
                        time_count = 0;
                    } else if (button == 12) {
                        Forced_refresh_alarm();
                        time_count = 0;
                    } else if(button == 7 || button == 8 || button == 22) {
                        break;
                    }
                    
                    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
                    rtc_time = PCF85063_GetTime();
                    xSemaphoreGive(rtc_mutex);
                    if ((rtc_time.minutes != last_minutes)) {
                        last_minutes = rtc_time.minutes;
                        display_alarm_time_img(rtc_time);
                    }
                }
            } else if (attr == EDIT_MIN) {
                while(1)
                {
                    button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
                    if(button == -1) time_count++;
                    if(time_count >= EPD_Sleep_Time){
                        button = Sleep_wake_alarm();
                    }
                    if(button == 14) {
                        temp_min = (temp_min + 1) % 60;
                        display_alarm_minute_img(temp_min, idx, 1);
                        time_count = 0;
                    } else if(button == 0) {
                        temp_min = (temp_min - 1 + 60) % 60;
                        display_alarm_minute_img(temp_min, idx, 1);
                        time_count = 0;
                    } else if(button == 20) {
                        temp_min = (temp_min + 1) % 60;
                        display_alarm_minute_img(temp_min, idx, 1);
                        time_count = 0;
                    } else if(button == 6) {
                        temp_min = (temp_min - 1 + 60) % 60;
                        display_alarm_minute_img(temp_min, idx, 1);
                        time_count = 0;
                    } else if (button == 12) {
                        Forced_refresh_alarm();
                        time_count = 0;
                    } else if(button == 7 || button == 8 || button == 22) {
                        break;
                    }
                    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
                    rtc_time = PCF85063_GetTime();
                    xSemaphoreGive(rtc_mutex);
                    if ((rtc_time.minutes != last_minutes)) {
                        last_minutes = rtc_time.minutes;
                        display_alarm_time_img(rtc_time);
                    }
                }
            } else if (attr == EDIT_ENABLE) {
                temp_en = !temp_en;
                display_alarm_enabled_img(temp_en, idx, 1);
            } else if (attr == EDIT_DONE) {
                alarms[idx].hour = temp_hour;
                alarms[idx].minute = temp_min;
                alarms[idx].enabled = temp_en;
                display_alarm_option();
                return;
            }
            display_alarm_option_img_Up_Down(attr,0);
            time_count = 0;
        } else if (button == 12) {
            Forced_refresh_alarm();
            time_count = 0;
        } else if (button == 8 || button == 22) { 
            display_alarm_hour_img(alarms[idx].hour, idx, 0);
            display_alarm_minute_img(alarms[idx].minute, idx, 0);
            display_alarm_enabled_img(alarms[idx].enabled, idx, 0);
            display_alarm_option();
            return;
        }

        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        if ((rtc_time.minutes != last_minutes)) {
            last_minutes = rtc_time.minutes;
            display_alarm_time_img(rtc_time);
        }
    }
}

// Main alarm clock menu
// The alarm setting page does not respond to alarms
void page_alarm_menu(void)
{
    // Load the alarm clock
    load_alarms_from_nvs();
    int idx = 0;
    int button = 0;
    int time_count = 0;
    Time_data rtc_time = {0};
    int last_minutes = -1;

    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);
    last_minutes = rtc_time.minutes;

    if((Image_alarm = (UBYTE *)heap_caps_malloc(EPD_SIZE_MONO,MALLOC_CAP_SPIRAM)) == NULL) 
    {
        ESP_LOGE("alarm","Failed to apply for black memory...");
        // return ESP_FAIL;
    }

    // Refresh the initial page
    display_alarm_init();
    while (1) {
        button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        if(button == -1) time_count++;
        if(time_count >= EPD_Sleep_Time){
            button = Sleep_wake_alarm();
        }

        if (button == 14) { 
            idx = (idx + 1) % (MAX_ALARMS);
            display_alarm_selection(idx);
            time_count = 0;
        } else if (button == 0) {
            idx = (idx - 1 + MAX_ALARMS) % (MAX_ALARMS);
            display_alarm_selection(idx);
            time_count = 0;
        } else if (button == 7) {
            if(idx == 5){
                xSemaphoreTake(alarm_mutex, portMAX_DELAY);
                qsort(alarms, MAX_ALARMS, sizeof(Alarm), alarm_compare);
                save_alarms_to_nvs();
                xSemaphoreGive(alarm_mutex);
                break;
            } else {
                xSemaphoreTake(alarm_mutex, portMAX_DELAY);
                edit_alarm_item(idx);
                xSemaphoreGive(alarm_mutex);
                time_count = 0;
            }
        } else if (button == 12) {
            Forced_refresh_alarm();
            time_count = 0;
        } else if (button == 8 || button == 22) {
            xSemaphoreTake(alarm_mutex, portMAX_DELAY);
            qsort(alarms, MAX_ALARMS, sizeof(Alarm), alarm_compare);
            save_alarms_to_nvs();
            xSemaphoreGive(alarm_mutex);
            break;
        }

        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        if ((rtc_time.minutes != last_minutes)) {
            last_minutes = rtc_time.minutes;
            display_alarm_time_img(rtc_time);
        }
    }
    heap_caps_free(Image_alarm);
}

// 
void alarm_task(void *param) {
    int last_minute = -1;
    bool check_alarm_flag = 0;
    int button;
    while (1) {
        // Mutex lock, preventing internal call conflicts
        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        Time_data rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        // ESP_LOGI("clock", "The RTC reading result: %04d-%02d-%02d %02d:%02d:%02d", rtc_time.years+2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds);
        
        if (rtc_time.minutes != last_minute) {
            last_minute = rtc_time.minutes;

            xSemaphoreTake(alarm_mutex, portMAX_DELAY);
            check_alarm_flag = check_alarm(rtc_time.hours, rtc_time.minutes);
            xSemaphoreGive(alarm_mutex);

            if (check_alarm_flag) {
                // Notify the main task to pause and enter the ringing interface
                ESP_LOGI(TAG, "The time to enter the ringing interface %d:%d",rtc_time.hours, rtc_time.minutes);
                page_audio_play_memory();
                // alarm_ring_handler(rtc_time.hours, rtc_time.minutes);
                while(1)
                {
                    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
                    Time_data rtc_time = PCF85063_GetTime();
                    xSemaphoreGive(rtc_mutex);
                    if(rtc_time.minutes != last_minute)
                    {
                        // Only perform the bell ringing operation for one minute
                        ESP_LOGI(TAG, "When the time is up, the bell rings to end");
                        break;
                    }
                    button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
                    if(button != -1)
                    {
                        // When a key is pressed, the bell stops ringing
                        ESP_LOGI(TAG, "Press the button and the bell will ring to end");
                        break;
                    }
        
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}



// E-paper operation function
// initialize
static void display_alarm_init(void)
{

    Paint_NewImage(Image_alarm, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_alarm);
    Paint_Clear(WHITE);

    char Time_str[16]={0};
    int BAT_Power;
    char BAT_Power_str[16]={0};

    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    Time_data rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);

    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", rtc_time.hours, rtc_time.minutes);
    Paint_DrawString_EN(20, 11, Time_str, &Font16, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    if (wifi_enable) Paint_ReadBmp(gImage_WIFI, 326, 8, 32, 32);
    Paint_ReadBmp(gImage_BAT, 370, 17, 32, 16);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    if (wifi_enable) GUI_ReadBmp(BMP_WIFI_PATH, 326, 8);
    GUI_ReadBmp(BMP_BAT_PATH, 370, 17);
#endif
    BAT_Power = get_battery_power();
    // ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    snprintf(BAT_Power_str, sizeof(BAT_Power_str), "%d%%", BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawString_EN(411, 11, BAT_Power_str, &Font16, WHITE, BLACK);
    Paint_DrawRectangle(375, 22, 395, 30, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(375, 22, 375+BAT_Power, 30, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawLine(2, 54, EPD_HEIGHT-2, 54, BLACK, DOT_PIXEL_2X2, LINE_STYLE_SOLID);

    Paint_DrawString_CN(20, 72, "闹钟", &Font18_UTF8, WHITE, BLACK);

    char hour_str[10] = {0};
    char minute_str[10] = {0};

    Paint_DrawCircle(65, 167, 18, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
    Paint_DrawCircle(65, 167, 12, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);

    snprintf(hour_str, sizeof(hour_str), "%02d", alarms[0].hour);
    Paint_DrawString_EN(110, 149, hour_str, &Font24, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_Alarm_clock_time_point,171,156,8,26);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_Alarm_clock_time_point_PATH,171,156);
#endif
    snprintf(minute_str, sizeof(minute_str), "%02d", alarms[0].minute);
    Paint_DrawString_EN(192, 149, minute_str, &Font24, WHITE, BLACK);

    if(alarms[0].enabled) {
        Paint_DrawRectangle(349, 149, 433, 185, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawRectangle(401, 153, 429, 181, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(365, 152, "开", &Font16_UTF8, BLACK, WHITE);
    } else {
        Paint_DrawRectangle(349, 149, 433, 185, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(353, 153, 381, 181, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(397, 152, "关", &Font16_UTF8, WHITE, BLACK);
    }
    Paint_DrawRectangle(20, 122, 460, 212, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);

    // 1
    Paint_DrawCircle(65, 277, 18, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);

    snprintf(hour_str, sizeof(hour_str), "%02d", alarms[1].hour);
    Paint_DrawString_EN(110, 259, hour_str, &Font24, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_Alarm_clock_time_point,171,266,8,26);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_Alarm_clock_time_point_PATH,171,266);
#endif
    snprintf(minute_str, sizeof(minute_str), "%02d", alarms[1].minute);
    Paint_DrawString_EN(192, 259, minute_str, &Font24, WHITE, BLACK);

    if(alarms[1].enabled) {
        Paint_DrawRectangle(349, 259, 433, 295, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawRectangle(401, 263, 429, 291, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(365, 262, "开", &Font16_UTF8, BLACK, WHITE);
    } else {
        Paint_DrawRectangle(349, 259, 433, 295, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(353, 263, 381, 291, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(397, 262, "关", &Font16_UTF8, WHITE, BLACK);
    }

    Paint_DrawRectangle(20, 232, 460, 322, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);

    // 2
    Paint_DrawCircle(65, 387, 18, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);

    snprintf(hour_str, sizeof(hour_str), "%02d", alarms[2].hour);
    Paint_DrawString_EN(110, 369, hour_str, &Font24, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_Alarm_clock_time_point,171,376,8,26);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_Alarm_clock_time_point_PATH,171,376);
#endif
    snprintf(minute_str, sizeof(minute_str), "%02d", alarms[2].minute);
    Paint_DrawString_EN(192, 369, minute_str, &Font24, WHITE, BLACK);

    if(alarms[2].enabled) {
        Paint_DrawRectangle(349, 369, 433, 405, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawRectangle(401, 373, 429, 401, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(365, 372, "开", &Font16_UTF8, BLACK, WHITE);
    } else {
        Paint_DrawRectangle(349, 369, 433, 405, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(353, 373, 381, 401, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(397, 372, "关", &Font16_UTF8, WHITE, BLACK);
    }

    Paint_DrawRectangle(20, 342, 460, 432, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);

    // 3
    Paint_DrawCircle(65, 497, 18, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);

    snprintf(hour_str, sizeof(hour_str), "%02d", alarms[3].hour);
    Paint_DrawString_EN(110, 479, hour_str, &Font24, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_Alarm_clock_time_point,171,486,8,26);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_Alarm_clock_time_point_PATH,171,486);
#endif
    snprintf(minute_str, sizeof(minute_str), "%02d", alarms[3].minute);
    Paint_DrawString_EN(192, 479, minute_str, &Font24, WHITE, BLACK);

    if(alarms[3].enabled) {
        Paint_DrawRectangle(349, 479, 433, 515, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawRectangle(401, 483, 429, 511, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(365, 482, "开", &Font16_UTF8, BLACK, WHITE);
    } else {
        Paint_DrawRectangle(349, 479, 433, 515, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(353, 483, 381, 511, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(397, 482, "关", &Font16_UTF8, WHITE, BLACK);
    }

    Paint_DrawRectangle(20, 452, 460, 542, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);

    // 4
    Paint_DrawCircle(65, 607, 18, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);

    snprintf(hour_str, sizeof(hour_str), "%02d", alarms[4].hour);
    Paint_DrawString_EN(110, 589, hour_str, &Font24, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_Alarm_clock_time_point,171,596,8,26);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_Alarm_clock_time_point_PATH,171,596);
#endif
    snprintf(minute_str, sizeof(minute_str), "%02d", alarms[4].minute);
    Paint_DrawString_EN(192, 589, minute_str, &Font24, WHITE, BLACK);

    if(alarms[4].enabled) {
        Paint_DrawRectangle(349, 589, 433, 625, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawRectangle(401, 593, 429, 621, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(365, 592, "开", &Font16_UTF8, BLACK, WHITE);
    } else {
        Paint_DrawRectangle(349, 589, 433, 625, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(353, 593, 381, 621, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(397, 592, "关", &Font16_UTF8, WHITE, BLACK);
    }

    Paint_DrawRectangle(20, 562, 460, 652, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(184, 700, " 退出 ", &Font24_UTF8, WHITE, BLACK);

    EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}

// Display time and battery level
static void display_alarm_time_img(Time_data rtc_time)
{
    char Time_str[16]={0};
    int BAT_Power;
    char BAT_Power_str[16]={0};

    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", rtc_time.hours, rtc_time.minutes);
    Paint_DrawString_EN(20, 11, Time_str, &Font16, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    if (wifi_enable) Paint_ReadBmp(gImage_WIFI, 326, 8, 32, 32);
    Paint_ReadBmp(gImage_BAT, 370, 17, 32, 16);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    if (wifi_enable) GUI_ReadBmp(BMP_WIFI_PATH, 326, 8);
    GUI_ReadBmp(BMP_BAT_PATH, 370, 17);
#endif
    BAT_Power = get_battery_power();
    // ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    snprintf(BAT_Power_str, sizeof(BAT_Power_str), "%d%%", BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawString_EN(411, 11, BAT_Power_str, &Font16, WHITE, BLACK);
    Paint_DrawRectangle(375, 22, 395, 30, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(375, 22, 375+BAT_Power, 30, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);

    EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}

// Alarm clock selection
static void display_alarm_selection(int count)
{
    if(count == 0){
        Paint_DrawCircle(65, 167, 12, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 277, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 387, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 497, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 607, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(184, 700, " 退出 ", &Font24_UTF8, WHITE, BLACK);
    } else if(count == 1){
        Paint_DrawCircle(65, 167, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 277, 12, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 387, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 497, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 607, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(184, 700, " 退出 ", &Font24_UTF8, WHITE, BLACK);
    } else if(count == 2){
        Paint_DrawCircle(65, 167, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 277, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 387, 12, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 497, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 607, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(184, 700, " 退出 ", &Font24_UTF8, WHITE, BLACK);
    } else if(count == 3){
        Paint_DrawCircle(65, 167, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 277, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 387, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 497, 12, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 607, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(184, 700, " 退出 ", &Font24_UTF8, WHITE, BLACK);
    } else if(count == 4){
        Paint_DrawCircle(65, 167, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 277, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 387, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 497, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 607, 12, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(184, 700, " 退出 ", &Font24_UTF8, WHITE, BLACK);
    } else if(count == 5){
        Paint_DrawCircle(65, 167, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 277, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 387, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 497, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawCircle(65, 607, 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(184, 700, " 退出 ", &Font24_UTF8, BLACK, WHITE);
    }

    EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}

// display options
static void display_alarm_option(void)
{
    Paint_DrawRectangle(10, 670, 480, 780, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(208, 700, " 退出 ", &Font24_UTF8, WHITE, BLACK);
    EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}

static void display_alarm_option_img(void)
{
    Paint_DrawRectangle(10, 670, 480, 780, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);

    Paint_DrawRectangle(75, 675, 140, 714, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);

    Paint_DrawString_CN(79, 680, " 时 ", &Font16_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(300, 680, " 分 ", &Font16_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(79, 740, " 开/关 ", &Font16_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(300, 740, " 保存退出 ", &Font16_UTF8, WHITE, BLACK);

    EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}

static void display_alarm_option_img_Up_Down(int count, int enabled)
{
    if(count == 0){
        Paint_DrawRectangle(296, 675, 361, 714, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(75, 735, 180, 774, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(296, 735, 433, 774, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);

        Paint_DrawRectangle(75, 675, 140, 714, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        if(enabled) Paint_DrawString_CN(79, 680, " 时 ", &Font16_UTF8, BLACK, WHITE);
        else Paint_DrawString_CN(79, 680, " 时 ", &Font16_UTF8, WHITE, BLACK);
    } else if(count == 1) {
        Paint_DrawRectangle(75, 675, 140, 714, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(75, 735, 180, 774, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(296, 735, 433, 774, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);

        Paint_DrawRectangle(296, 675, 361, 714, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        if(enabled) Paint_DrawString_CN(300, 680, " 分 ", &Font16_UTF8, BLACK, WHITE);
        else Paint_DrawString_CN(300, 680, " 分 ", &Font16_UTF8, WHITE, BLACK);
    
    } else if(count == 2) {
        Paint_DrawRectangle(75, 675, 140, 714, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(296, 675, 361, 714, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(296, 735, 433, 774, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);

        Paint_DrawRectangle(75, 735, 180, 774, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawString_CN(79, 740, " 开/关 ", &Font16_UTF8, WHITE, BLACK);
    } else if(count == 3) {
        Paint_DrawRectangle(75, 675, 140, 714, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(296, 675, 361, 714, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawRectangle(75, 735, 180, 774, WHITE, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);

        Paint_DrawRectangle(296, 735, 433, 774, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        Paint_DrawString_CN(300, 740, " 保存退出 ", &Font16_UTF8, WHITE, BLACK);
    }

    EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}

static void display_alarm_hour_img(int hour, int count, int en)
{
    char hour_str[10] = {0};
    snprintf(hour_str, sizeof(hour_str), "%02d", hour);
    switch (count)
    {
        case 0:
            Paint_DrawString_EN(110, 149, hour_str, &Font24, WHITE, BLACK);
            break;
        case 1:
            Paint_DrawString_EN(110, 259, hour_str, &Font24, WHITE, BLACK);
            break;
        case 2:
            Paint_DrawString_EN(110, 369, hour_str, &Font24, WHITE, BLACK);
            break;
        case 3:
            Paint_DrawString_EN(110, 479, hour_str, &Font24, WHITE, BLACK);
            break;
        case 4:
            Paint_DrawString_EN(110, 589, hour_str, &Font24, WHITE, BLACK);
            break;
        default:
            break;
    }
    if(en) EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}

static void display_alarm_minute_img(int minute, int count, int en)
{
    char minute_str[10] = {0};
    snprintf(minute_str, sizeof(minute_str), "%02d", minute);
    switch (count)
    {
        case 0:
            Paint_DrawString_EN(192, 149, minute_str, &Font24, WHITE, BLACK);
            break;
        case 1:
            Paint_DrawString_EN(192, 259, minute_str, &Font24, WHITE, BLACK);
            break;
        case 2:
            Paint_DrawString_EN(192, 369, minute_str, &Font24, WHITE, BLACK);
            break;
        case 3:
            Paint_DrawString_EN(192, 479, minute_str, &Font24, WHITE, BLACK);
            break;
        case 4:
            Paint_DrawString_EN(192, 589, minute_str, &Font24, WHITE, BLACK);
            break;
        default:
            break;
    }
    if(en) EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}

static void display_alarm_enabled_img(int enabled, int count, int en)
{
    if(count == 0){
        if(enabled) {
            Paint_DrawRectangle(349, 149, 433, 185, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(401, 153, 429, 181, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(365, 152, "开", &Font16_UTF8, BLACK, WHITE);
        } else {
            Paint_DrawRectangle(349, 149, 433, 185, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(349, 149, 433, 185, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
            Paint_DrawRectangle(353, 153, 381, 181, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(397, 152, "关", &Font16_UTF8, WHITE, BLACK);
        }
    } else if(count == 1){
        if(enabled) {
            Paint_DrawRectangle(349, 259, 433, 295, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(401, 263, 429, 291, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(365, 262, "开", &Font16_UTF8, BLACK, WHITE);
        } else {
            Paint_DrawRectangle(349, 259, 433, 295, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(349, 259, 433, 295, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
            Paint_DrawRectangle(353, 263, 381, 291, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(397, 262, "关", &Font16_UTF8, WHITE, BLACK);
        }

    } else if(count == 2){
        if(enabled) {
            Paint_DrawRectangle(349, 369, 433, 405, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(401, 373, 429, 401, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(365, 372, "开", &Font16_UTF8, BLACK, WHITE);
        } else {
            Paint_DrawRectangle(349, 369, 433, 405, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(349, 369, 433, 405, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
            Paint_DrawRectangle(353, 373, 381, 401, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(397, 372, "关", &Font16_UTF8, WHITE, BLACK);
        }
    } else if(count == 3){
        if(enabled) {
            Paint_DrawRectangle(349, 479, 433, 515, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(401, 483, 429, 511, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(365, 482, "开", &Font16_UTF8, BLACK, WHITE);
        } else {
            Paint_DrawRectangle(349, 479, 433, 515, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(349, 479, 433, 515, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
            Paint_DrawRectangle(353, 483, 381, 511, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(397, 482, "关", &Font16_UTF8, WHITE, BLACK);
        }
    } else if(count == 4){
        if(enabled) {
            Paint_DrawRectangle(349, 589, 433, 625, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(401, 593, 429, 621, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(365, 592, "开", &Font16_UTF8, BLACK, WHITE);
        } else {
            Paint_DrawRectangle(349, 589, 433, 625, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(349, 589, 433, 625, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
            Paint_DrawRectangle(353, 593, 381, 621, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(397, 592, "关", &Font16_UTF8, WHITE, BLACK);
        }
    }
    if(en) EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}

// refresh
void Forced_refresh_alarm(void)
{
    EPD_Display_Base(Image_alarm);
}
void Refresh_page_alarm(void)
{
    EPD_Display_Partial(Image_alarm,0,0,EPD_WIDTH,EPD_HEIGHT);
}









