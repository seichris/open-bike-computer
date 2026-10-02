#include "page_clock.h"
#include "esp_log.h"
#include "pcf85063_bsp.h"
#include "page_network.h"
#include "button_bsp.h"
#include "shtc3_bsp.h"
#include "axp_prot.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include <time.h>
#include <sys/time.h>
#include "esp_sntp.h"

#include "esp_http_client.h"
#include "cJSON.h"
#include "esp_netif.h" 
#include "esp_err.h"   

#include "epaper_port.h"
#include "GUI_BMPfile.h"
#include "GUI_Paint.h"

#include "sdcard_bsp.h"
#include "page_alarm.h"
#include "page_audio.h"

#include "nvs_flash.h"
#include "nvs.h"
#include <inttypes.h>

// Time zone configuration structure
typedef struct {
    const char* name;     // Time zone name
    const char* tz_str;   // POSIX time zone string
    int offset_hours;     // UTC offset hours (for display only)
    const char* CH_name;
} timezone_config_t;

// 25 time zone configurations (UTC-12 to UTC+12)
static const timezone_config_t timezone_list[] = {
    {"UTC-12", "UTC+12", -12, "西十二区"},
    {"UTC-11", "UTC+11", -11, "西十一区"},
    {"UTC-10", "UTC+10", -10, "西十区"},
    {"UTC-9",  "UTC+9",  -9,  "西九区"},
    {"UTC-8",  "UTC+8",  -8,  "西八区"},
    {"UTC-7",  "UTC+7",  -7,  "西七区"},
    {"UTC-6",  "UTC+6",  -6,  "西六区"},
    {"UTC-5",  "UTC+5",  -5,  "西五区"},
    {"UTC-4",  "UTC+4",  -4,  "西四区"},
    {"UTC-3",  "UTC+3",  -3,  "西三区"},
    {"UTC-2",  "UTC+2",  -2,  "西二区"},
    {"UTC-1",  "UTC+1",  -1,  "西一区"},
    {"UTC+0",  "UTC0",    0,  "零时区"},
    {"UTC+1",  "UTC-1",   1,  "东一区"},
    {"UTC+2",  "UTC-2",   2,  "东二区"},
    {"UTC+3",  "UTC-3",   3,  "东三区"},
    {"UTC+4",  "UTC-4",   4,  "东四区"},
    {"UTC+5",  "UTC-5",   5,  "东五区"},
    {"UTC+6",  "UTC-6",   6,  "东六区"},
    {"UTC+7",  "UTC-7",   7,  "东七区"},
    {"UTC+8",  "CST-8",   8,  "东八区"},  // Beijing Time (default)
    {"UTC+9",  "JST-9",   9,  "东九区"},
    {"UTC+10", "UTC-10", 10,  "东十区"},
    {"UTC+11", "UTC-11", 11,  "东十一区"},
    {"UTC+12", "UTC-12", 12,  "东十二区"},
};

#define TIMEZONE_COUNT (sizeof(timezone_list) / sizeof(timezone_config_t))
#define DEFAULT_TIMEZONE_INDEX 20  // Default Eastern 8th Time Zone (UTC+8)

// NVS key name
#define NVS_NAMESPACE "clock_config"
#define NVS_KEY_TIMEZONE "timezone_idx"
#define NVS_NAMESPACE "clock_th"
#define NVS_KEY "th_data" 

// E-ink screen sleep time (S)
#define EPD_Sleep_Time   60
// Equipment shutdown time (minutes)
#define Unattended_Time  10


extern SemaphoreHandle_t rtc_mutex; 
extern bool wifi_enable; 
extern Alarm alarms[MAX_ALARMS];

// Define the data cache area of the e-ink screen
extern uint8_t *Image_Mono;
uint8_t *Image_Mono_last;
Clock_TH Clock_TH_Old = {0};


// Almanac API
#define LUNAR_API_URL_BASE "https://api.mu-jie.cc/lunar?date=%s"

static inline void sntp_deinit(void) {}
static void show_lunar_for_today(const Time_data* t);
static int fetch_lunar_info(const char* date_str, LunarInfo* info);
static void fetch_and_save_lunar_month_to_sd(const char* year, const char* month, LunarInfo* month_info);
static int load_lunar_month_from_sd(const char* year, const char* month, LunarInfo* month_info);

static void display_clock_init(void);
static void display_clock_img(Time_data rtc_time, int Refresh_mode);

static void display_calendar_img(Time_data rtc_time, LunarInfo* month_info);
static void display_clock_mode_img(Time_data rtc_time);

int get_time_from_ntp(struct tm *t)
{
    esp_sntp_stop(); // Stop first to prevent repeated initialization
    esp_sntp_setoperatingmode(SNTP_OPMODE_POLL);
    esp_sntp_setservername(0, "ntp1.aliyun.com");
    esp_sntp_init();

    // Wait for synchronization
    time_t now = 0;
    struct tm timeinfo = {0};
    int retry = 0;
    const int retry_count = 10;
    while (retry++ < retry_count) {
        time(&now);
        localtime_r(&now, &timeinfo);
        if (timeinfo.tm_year > (2020 - 1900)) {
            *t = timeinfo;
            esp_sntp_stop();
            return 0;
        }
        vTaskDelay(pdMS_TO_TICKS(500));
    }
    esp_sntp_stop();
    return -1;
}


static void tm_to_timedata(const struct tm *src, Time_data *dst)
{
    dst->years   = src->tm_year + 1900 - 2000;
    dst->months  = src->tm_mon + 1;
    dst->days    = src->tm_mday;
    dst->hours   = src->tm_hour;
    dst->minutes = src->tm_min;
    dst->seconds = src->tm_sec;
    dst->week    = src->tm_wday;
}

static void timedata_to_tm(const Time_data *src, struct tm *dst)
{
    dst->tm_year = src->years + 2000 - 1900;
    dst->tm_mon  = src->months - 1;
    dst->tm_mday = src->days;
    dst->tm_hour = src->hours;
    dst->tm_min  = src->minutes;
    dst->tm_sec  = src->seconds;
    dst->tm_wday = src->week;
}


static void show_time(const Time_data *t)
{
    struct tm tm_val = {0};
    timedata_to_tm(t, &tm_val);
    const char* week_str[] = {"日", "一", "二", "三", "四", "五", "六"};
    ESP_LOGI("clock", "current time: %04d-%02d-%02d %02d:%02d:%02d week %s",
        t->years + 2000, t->months, t->days, t->hours, t->minutes, t->seconds,
        week_str[tm_val.tm_wday]);
}

// Read the time zone index from NVS
static int load_timezone_index_from_nvs(void)
{
    nvs_handle_t nvs_handle;
    int32_t timezone_idx = DEFAULT_TIMEZONE_INDEX;
    
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs_handle);
    if (err == ESP_OK) {
        nvs_get_i32(nvs_handle, NVS_KEY_TIMEZONE, &timezone_idx);
        nvs_close(nvs_handle);
    }
    
    if (timezone_idx < 0 || timezone_idx >= TIMEZONE_COUNT) {
        timezone_idx = DEFAULT_TIMEZONE_INDEX;
    }
    
    ESP_LOGI("timezone", "Read the time zone index from NVS: %" PRId32 " (%s)", timezone_idx, timezone_list[timezone_idx].name);
    return timezone_idx;
}

static esp_err_t save_timezone_index_to_nvs(int timezone_idx)
{
    nvs_handle_t nvs_handle;
    esp_err_t err;
    
    if (timezone_idx < 0 || timezone_idx >= TIMEZONE_COUNT) {
        ESP_LOGE("timezone", "The time zone index is invalid: %d", timezone_idx);
        return ESP_ERR_INVALID_ARG;
    }
    
    err = nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs_handle);
    if (err != ESP_OK) {
        ESP_LOGE("timezone", "Failed to open NVS: %s", esp_err_to_name(err));
        return err;
    }
    
    err = nvs_set_i32(nvs_handle, NVS_KEY_TIMEZONE, timezone_idx);
    if (err == ESP_OK) {
        err = nvs_commit(nvs_handle);
        ESP_LOGI("timezone", "Save the time zone index to NVS: %d (%s)", timezone_idx, timezone_list[timezone_idx].name);
    }
    
    nvs_close(nvs_handle);
    return err;
}


void load_clock_from_nvs(void) {
    nvs_handle_t handle;
    size_t required_size = sizeof(Clock_TH_Old);
    if (nvs_open("clock_th", NVS_READONLY, &handle) == ESP_OK) {
        nvs_get_blob(handle, "th_data", &Clock_TH_Old, &required_size);
        nvs_close(handle);
    }
}
void save_clock_to_nvs_if_changed(void) {
    nvs_handle_t handle;
    if (nvs_open("clock_th", NVS_READWRITE, &handle) == ESP_OK) {
        nvs_set_blob(handle, "th_data", &Clock_TH_Old, sizeof(Clock_TH_Old));
        nvs_commit(handle);
        nvs_close(handle);
    }
}

// Apply time zone Settings
static void apply_timezone(int timezone_idx)
{
    if (timezone_idx < 0 || timezone_idx >= TIMEZONE_COUNT) {
        timezone_idx = DEFAULT_TIMEZONE_INDEX;
    }
    
    const timezone_config_t* tz = &timezone_list[timezone_idx];
    setenv("TZ", tz->tz_str, 1);
    tzset();
    
    ESP_LOGI("timezone", "Applied time zones: %s (%s)", tz->name, tz->tz_str);
}

// Get the current time zone name
static const char* get_current_timezone_name(void)
{
    int idx = load_timezone_index_from_nvs();
    return timezone_list[idx].name;
}

// Time Zone Selection Menu (Example)
void page_timezone_select(void)
{
    int current_idx = load_timezone_index_from_nvs();
    int selected_idx = current_idx;
    int time_count = 0;
    
    ESP_LOGI("timezone", "Current time zone: %s", timezone_list[current_idx].name);
    
    // Display the list of time zones
    Paint_Clear(WHITE);
    char title[64];
    snprintf(title, sizeof(title), "时区设置,当前时区: %s", timezone_list[current_idx].CH_name);
    Paint_DrawString_CN(10, 10, title, &Font24_UTF8, WHITE, BLACK);
    snprintf(title, sizeof(title), "时区选择: %s", timezone_list[current_idx].CH_name);
    Paint_DrawString_CN(10, Font24_UTF8.Height+20, title, &Font24_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(10, Font24_UTF8.Height*2+30, "↑↓: 选择时区", &Font18_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(10, Font24_UTF8.Height*3+30, "单击确认: 确认选择时区", &Font18_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(10, Font24_UTF8.Height*4+30, "双击确认/Boot: 退出", &Font18_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(10, Font24_UTF8.Height*5+30, "60s 无操作退出", &Font18_UTF8, WHITE, BLACK);
    Refresh_page_clock();
    
    while (1) {
        int button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        if(button == -1) time_count++;
        if (button == 0) {
            selected_idx--;
            time_count = 0;
            if (selected_idx < 0) selected_idx = TIMEZONE_COUNT - 1;
            Paint_DrawRectangle(5,Font24_UTF8.Height+15, Font24_UTF8.Width_CH * 10+ 10, Font24_UTF8.Height*2+20,WHITE,DOT_PIXEL_1X1,DRAW_FILL_FULL);
            ESP_LOGI("timezone", "time zone > %s",timezone_list[selected_idx].name);
            snprintf(title, sizeof(title), "时区选择: %s", timezone_list[selected_idx].CH_name);
            Paint_DrawString_CN(10, Font24_UTF8.Height+20, title, &Font24_UTF8, WHITE, BLACK);
            Refresh_page_clock();
        } else if (button == 14) {
            selected_idx++;
            time_count = 0;
            if (selected_idx > TIMEZONE_COUNT - 1) selected_idx = 0;
            Paint_DrawRectangle(5,Font24_UTF8.Height+15, Font24_UTF8.Width_CH * 10+ 10, Font24_UTF8.Height*2+20,WHITE,DOT_PIXEL_1X1,DRAW_FILL_FULL);
            ESP_LOGI("timezone", "time zone > %s",timezone_list[selected_idx].name);
            snprintf(title, sizeof(title), "时区选择: %s", timezone_list[selected_idx].CH_name);
            Paint_DrawString_CN(10, Font24_UTF8.Height+20, title, &Font24_UTF8, WHITE, BLACK);
            Refresh_page_clock();
        } else if (button == 7) {
            time_count = 0;
            Paint_DrawRectangle(5,5, Font24_UTF8.Width_CH * 15+ 10, Font24_UTF8.Height+15,WHITE,DOT_PIXEL_1X1,DRAW_FILL_FULL);
            snprintf(title, sizeof(title), "时区设置,当前时区: %s", timezone_list[selected_idx].CH_name);
            Paint_DrawString_CN(10, 10, title, &Font24_UTF8, WHITE, BLACK);
            Refresh_page_clock();
        } else if (button == 12) { 
            time_count = 0;
            Forced_refresh_clock();
        } else if (button == 8 || button == 22 || (time_count >= EPD_Sleep_Time)) {  // Boot - 取消
            save_timezone_index_to_nvs(selected_idx);
            apply_timezone(selected_idx);
            ESP_LOGI("timezone", "The time zone has been changed to: %s", timezone_list[selected_idx].name);
            break;
        }
    }
}

void page_clock_init(void)
{
    // Read and apply time zones from NVS
    int timezone_idx = load_timezone_index_from_nvs();
    apply_timezone(timezone_idx);
    
    Time_data rtc_time = {0};
    struct tm ntp_tm = {0};
    int i=0;
    while(i < 30)
    {
        if(get_time_from_ntp(&ntp_tm) == 0)
        {
            ESP_LOGI("clock", "The NTP successfully obtained the time and wrote it to the RTC");
            tm_to_timedata(&ntp_tm, &rtc_time);
            ESP_LOGI("clock", "Prepare to write into the RTC: %04d-%02d-%02d %02d:%02d:%02d", rtc_time.years+2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds);
            PCF85063_SetTime(rtc_time);
            vTaskDelay(pdMS_TO_TICKS(1000));
            break;
        }
        i++;
    }
}


void page_clock_show(void)
{
    Time_data rtc_time = {0};
    int force_update = 0;

    int last_minutes = -1;
    int last_hours = -1;
    int sleep_js = 0;

    if((Image_Mono_last = (UBYTE *)heap_caps_malloc(EPD_SIZE_MONO,MALLOC_CAP_SPIRAM)) == NULL) 
    {
        ESP_LOGE("clock","Failed to apply for black memory...");
        // return ESP_FAIL;
    }

    int timezone_idx = load_timezone_index_from_nvs();
    apply_timezone(timezone_idx);

    display_clock_init();
    while (1) {
        if(force_update){
            struct tm ntp_tm = {0};
            if (wifi_is_connected() && get_time_from_ntp(&ntp_tm) == 0) {
                ESP_LOGI("clock", "The NTP successfully obtained the time and wrote it to the RTC");
                tm_to_timedata(&ntp_tm, &rtc_time);
                ESP_LOGI("clock", "Prepare to write into the RTC: %04d-%02d-%02d %02d:%02d:%02d", rtc_time.years+2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds);
                xSemaphoreTake(rtc_mutex, portMAX_DELAY);
                PCF85063_SetTime(rtc_time);
                xSemaphoreGive(rtc_mutex);
            } else {
                ESP_LOGW("clock", "The NTP time acquisition failed. Read the RTC time");
                // Mutex lock, preventing internal call conflicts
                xSemaphoreTake(rtc_mutex, portMAX_DELAY);
                rtc_time = PCF85063_GetTime();
                xSemaphoreGive(rtc_mutex);
                ESP_LOGI("clock", "The RTC reading result: %04d-%02d-%02d %02d:%02d:%02d", rtc_time.years+2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds);

            }
            force_update = 0;
            last_minutes = rtc_time.minutes;
            last_hours = rtc_time.hours;
            ESP_LOGI("clock", "EPD_Init");
            EPD_Init();
            display_clock_img(rtc_time, Global_refresh);
            ESP_LOGI("clock", "EPD_Sleep");
            EPD_Sleep();
        } else {
            xSemaphoreTake(rtc_mutex, portMAX_DELAY);
            rtc_time = PCF85063_GetTime();
            xSemaphoreGive(rtc_mutex);
            ESP_LOGI("clock", "The RTC reading result: %04d-%02d-%02d %02d:%02d:%02d", rtc_time.years+2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds);
        }

        if (rtc_time.minutes != last_minutes) {
            last_minutes = rtc_time.minutes;
            ESP_LOGI("clock", "EPD_Init");
            EPD_Init();
            if (rtc_time.hours != last_hours){
                last_hours = rtc_time.hours;
                display_clock_img(rtc_time, Global_refresh);
            } else {
                display_clock_img(rtc_time, Partial_refresh);
            }
            ESP_LOGI("clock", "EPD_Sleep");
            EPD_Sleep();

            sleep_js++;
            if(sleep_js > Unattended_Time){
                ESP_LOGI("home", "pwr_off");
                save_mode_enable_to_nvs(1);
                Time_data alarm_time = rtc_time;
                alarm_time.minutes += 1;
                alarm_time.seconds = 0;
                PCF85063_alarm_Time_Enabled(alarm_time);
                if (!sd_write_buffer_to_file(CLOCK_PARTIAL_PATH, Image_Mono, EPD_SIZE_MONO)) {
                    ESP_LOGW("sdio", "Failed to save the local cache to SD: %s", CLOCK_PARTIAL_PATH);
                    save_clock_to_nvs_if_changed();
                }
                vTaskDelay(pdMS_TO_TICKS(50));
                axp_pwr_off();
            } 
        }
        show_time(&rtc_time);

        int button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        if (button == 12) {
            force_update = 1;
        } else if (button == 7) {
            EPD_Init();
            EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
            page_timezone_select();
            ESP_LOGI("clock", "EPD_Sleep");
            EPD_Sleep();
            while (1)
            {
                button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
                vTaskDelay(pdMS_TO_TICKS(100));
                if(button == -1)
                    break;
            }
            force_update = 1;
            display_clock_init();
        } else if (button == 8 || button == 22) {
            EPD_Init();
            Refresh_page_clock();
            break;
        }
    }
    heap_caps_free(Image_Mono_last);
}

// Used in clock mode
void page_clock_show_mode()
{
    load_alarms_from_nvs();
    Time_data rtc_time = PCF85063_GetTime();

    // Clock calibration time
    if(rtc_time.hours == 8 && rtc_time.minutes == 0)
    {
        if(page_network_init_mode())
        {   
            int timezone_idx = load_timezone_index_from_nvs();
            apply_timezone(timezone_idx);
            
            struct tm ntp_tm = {0};
            if (wifi_is_connected() && get_time_from_ntp(&ntp_tm) == 0) {
                ESP_LOGI("clock", "The NTP successfully obtained the time and wrote it to the RTC");
                tm_to_timedata(&ntp_tm, &rtc_time);
                ESP_LOGI("clock", "Prepare to write into the RTC: %04d-%02d-%02d %02d:%02d:%02d", rtc_time.years+2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds);
                PCF85063_SetTime(rtc_time);
            }
        }
        
    }

    if(!check_alarm(rtc_time.hours, rtc_time.minutes)){
        // Do a full brush at every hour and half
        if(rtc_time.minutes == 0 || rtc_time.minutes == 30){
            display_clock_init();
            display_clock_img(rtc_time, Global_refresh);
        } else {
            display_clock_mode_img(rtc_time);
        }
        ESP_LOGI("clock", "EPD_Sleep");
        EPD_Sleep();
    } else {
        if(rtc_time.minutes == 0 || rtc_time.minutes == 30){
            display_clock_init();
            display_clock_img(rtc_time, Global_refresh);
        } else {
            display_clock_mode_img(rtc_time);
        }
        ESP_LOGI("clock", "EPD_Sleep");
        EPD_Sleep();
        page_audio_play_memory();
    }

    Time_data alarm_time = rtc_time;
    alarm_time.minutes += 1;
    alarm_time.seconds = 0;
    PCF85063_alarm_Time_Enabled(alarm_time);
    vTaskDelay(pdMS_TO_TICKS(50));
    axp_pwr_off();
}



// Wake-up time setting
void Wake_up_time_setting_calendar(Time_data rtc_time)
{
    for (size_t i = 0; i < MAX_ALARMS; i++)
    {
        if (alarms[i].enabled){
            if(alarms[i].hour > rtc_time.hours){
                Time_data alarm_time = rtc_time;
                alarm_time.hours = alarms[i].hour;
                alarm_time.minutes = alarms[i].minute;
                PCF85063_alarm_Time_Enabled(alarm_time);
                break;
            } else if((alarms[i].hour == rtc_time.hours) && (alarms[i].minute > rtc_time.minutes)){
                Time_data alarm_time = rtc_time;
                alarm_time.hours = alarms[i].hour;
                alarm_time.minutes = alarms[i].minute;
                PCF85063_alarm_Time_Enabled(alarm_time);
                break;
            } else {
                Time_data alarm_time = rtc_time;
                alarm_time.days += 1;
                alarm_time.hours = 0;
                alarm_time.minutes = 0;
                PCF85063_alarm_Time_Enabled(alarm_time);
            }
        } else {
            Time_data alarm_time = rtc_time;
            alarm_time.days += 1;
            alarm_time.hours = 0;
            alarm_time.minutes = 0;
            PCF85063_alarm_Time_Enabled(alarm_time);
        }
    }
}

// calendar
void page_calendar_show(void)
{
    Time_data rtc_time = {0};
    int force_update = 0;
    int lunar_force_update = 0; // The lunar calendar mandatory renewal logo

    int timezone_idx = load_timezone_index_from_nvs();
    apply_timezone(timezone_idx);

    int last_days = -1;
    int last_hour = -1;
    int last_minutes = -1;
    int sleep_js = 0;

    last_minutes = rtc_time.minutes;
    last_days = rtc_time.days;

    LunarInfo* month_info = (LunarInfo*)heap_caps_calloc(31, sizeof(LunarInfo), MALLOC_CAP_SPIRAM);
    if (!month_info) {
        ESP_LOGE("lunar", "PSRAM allocation failed");
    }

    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);
    last_days = rtc_time.days;
    last_hour = rtc_time.hours;
    display_calendar_img(rtc_time, month_info);

    while (1) {
        if (wifi_is_connected() && force_update) {
            struct tm ntp_tm = {0};
            if (get_time_from_ntp(&ntp_tm) == 0) {
                ESP_LOGI("clock", "The NTP successfully obtained the time and wrote it to the RTC");
                tm_to_timedata(&ntp_tm, &rtc_time);
                xSemaphoreTake(rtc_mutex, portMAX_DELAY);
                PCF85063_SetTime(rtc_time);
                xSemaphoreGive(rtc_mutex);
            } else {
                ESP_LOGW("clock", "The NTP time acquisition failed. Read the RTC time");
                xSemaphoreTake(rtc_mutex, portMAX_DELAY);
                rtc_time = PCF85063_GetTime();
                xSemaphoreGive(rtc_mutex);
            }
            force_update = 0;
        } else {
            xSemaphoreTake(rtc_mutex, portMAX_DELAY);
            rtc_time = PCF85063_GetTime();
            xSemaphoreGive(rtc_mutex);
        }

        //print time
        show_time(&rtc_time);
        
        if ((rtc_time.days != last_days) || lunar_force_update) {
            last_days = rtc_time.days;
            last_hour = rtc_time.hours;
            last_minutes = rtc_time.minutes;

            if(wifi_is_connected() && lunar_force_update)
            {
                esp_netif_ip_info_t ip_info;
                esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
                esp_err_t ip_ret = esp_netif_get_ip_info(netif, &ip_info);
                if (ip_ret != ESP_OK || ip_info.ip.addr == 0) {
                    ESP_LOGI("lunar1", "The IP address for WiFi was not obtained. Please check your network!");
                    Paint_DrawString_CN(10, 110, "WiFi未获取到IP地址，请检查网络！", &Font24_UTF8, WHITE, BLACK);
                    Paint_DrawString_CN(10, 165, "三秒后显示原内容", &Font24_UTF8, WHITE, BLACK);
                    Refresh_page_clock();
                    vTaskDelay(pdMS_TO_TICKS(3000));
                } else {
                    ESP_LOGI("lunar", "The lunar calendar data is being obtained and saved through the network connection...");
                    ESP_LOGI("clock", "EPD_Init");
                    EPD_Init();
                    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
                    Paint_Clear(WHITE);
                    Paint_DrawString_CN(10, 110, "正在联网获取并保存农历数据...", &Font24_UTF8, WHITE, BLACK);
                    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
                    ESP_LOGI("clock", "EPD_Sleep");
                    EPD_Sleep();

                    char year_str[8], month_str[8];
                    // Obtain the current year and month string
                    snprintf(year_str, sizeof(year_str), "%04d", rtc_time.years + 2000);
                    snprintf(month_str, sizeof(month_str), "%02d", rtc_time.months);
                    fetch_and_save_lunar_month_to_sd(year_str, month_str, month_info);
                }
            } else {
                ESP_LOGI("lunar", "No network connection");
                Paint_DrawString_CN(10, 110, "WiFi未获取到IP地址，请检查网络！", &Font24_UTF8, WHITE, BLACK);
                Paint_DrawString_CN(10, 165, "三秒后显示原内容", &Font24_UTF8, WHITE, BLACK);
                Refresh_page_clock();
                vTaskDelay(pdMS_TO_TICKS(3000));
            }

            force_update = 1;
            lunar_force_update = 0;
            display_calendar_img(rtc_time, month_info);
        }

        if (rtc_time.minutes != last_minutes) {
            last_minutes = rtc_time.minutes;
            sleep_js++;
            if(sleep_js > Unattended_Time){
                ESP_LOGI("home", "pwr_off");
                // Set the mode to 2, calendar
                save_mode_enable_to_nvs(2);
                load_alarms_from_nvs();
                Wake_up_time_setting_calendar(rtc_time);
                vTaskDelay(pdMS_TO_TICKS(50));
                axp_pwr_off();
            } 
        }

        int button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        if (button == 12) {
            force_update = 1;
            lunar_force_update = 1;
        } else if (button == 7) {
            // reserved
        } else if (button == 8 || button == 22) {
            ESP_LOGI("clock", "EPD_Init");
            EPD_Init();
            Refresh_page_clock();
            break;
        }
    }
    heap_caps_free(month_info);
}

// Mode 2 Usage calendar
void page_calendar_show_mode() 
{
    load_alarms_from_nvs();
    Time_data rtc_time = PCF85063_GetTime();
    Wake_up_time_setting_calendar(rtc_time);

    LunarInfo* month_info = (LunarInfo*)heap_caps_calloc(31, sizeof(LunarInfo), MALLOC_CAP_SPIRAM);
    if (!month_info) {
        ESP_LOGE("lunar", "PSRAM allocation failed");
    }

    if((!check_alarm(rtc_time.hours, rtc_time.minutes)) || (rtc_time.hours == 0 && rtc_time.minutes == 0)){
        if(page_network_init_mode())
        {   
            setenv("TZ", "CST-8", 1);
            tzset();
            struct tm ntp_tm = {0};
            if (wifi_is_connected() && get_time_from_ntp(&ntp_tm) == 0) {
                ESP_LOGI("clock", "The NTP successfully obtained the time and wrote it to the RTC");
                tm_to_timedata(&ntp_tm, &rtc_time);
                ESP_LOGI("clock", "Prepare to write into the RTC: %04d-%02d-%02d %02d:%02d:%02d", rtc_time.years+2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds);
                PCF85063_SetTime(rtc_time);
            }
        }
        display_calendar_img(rtc_time, month_info);
        ESP_LOGI("clock", "EPD_Sleep");
        EPD_Sleep();
        if(check_alarm(rtc_time.hours, rtc_time.minutes))
        {
            page_audio_play_memory();
        }
    } else {
        ESP_LOGI("clock", "EPD_Sleep");
        EPD_Sleep();
        page_audio_play_memory();
    }
    vTaskDelay(pdMS_TO_TICKS(50));
    axp_pwr_off();
}

extern const char api_root_cert_pem_start[] asm("_binary_api_root_cert_pem_start");
extern const char api_root_cert_pem_end[]   asm("_binary_api_root_cert_pem_end");

// The API sub-function for obtaining lunar calendar information
static int fetch_lunar_info(const char* date_str, LunarInfo* info)
{
    char url[128];
    snprintf(url, sizeof(url), LUNAR_API_URL_BASE, date_str);

    esp_http_client_config_t config = {};
    config.url = url;
    config.timeout_ms = 3000;
    config.cert_pem = api_root_cert_pem_start;

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (!client) return -1;
    esp_http_client_set_header(client, "User-Agent", "Mozilla/5.0");
    esp_http_client_set_header(client, "Accept", "application/json");
    esp_http_client_set_header(client, "Referer", "https://api.mu-jie.cc/");

    esp_err_t err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        ESP_LOGW("lunar", "HTTP open failed: %s", esp_err_to_name(err));
        esp_http_client_cleanup(client);
        return -1;
    }

    int content_length = esp_http_client_fetch_headers(client);
    ESP_LOGI("lunar", "HTTP content length: %d", content_length);

    int buffer_size = (content_length > 0 && content_length < 4096) ? content_length + 1 : 4096;
    char *buffer = (char*)malloc(buffer_size);
    if (!buffer) {
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        return -1;
    }

    int total_read = 0, read_len = 0;
    while ((read_len = esp_http_client_read(client, buffer + total_read, buffer_size - total_read - 1)) > 0) {
        total_read += read_len;
        if (total_read >= buffer_size - 1) break;
    }
    buffer[total_read] = '\0';
    ESP_LOGI("lunar", "HTTP body: %s", buffer);

    cJSON* root = cJSON_Parse(buffer);
    free(buffer);
    if (!root) {
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        return -1;
    }

    cJSON* data = cJSON_GetObjectItem(root, "data");
    if (!data) {
        cJSON_Delete(root);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        return -1;
    }

    #define COPY_JSON_STR(field, key) do { \
        cJSON* item = cJSON_GetObjectItem(data, key); \
        if (item && cJSON_IsString(item)) strncpy(info->field, item->valuestring, sizeof(info->field)-1); \
        else info->field[0] = 0; \
    } while(0)

    COPY_JSON_STR(lunarDate, "lunarDate");
    COPY_JSON_STR(festival, "festival");
    COPY_JSON_STR(lunarFestival, "lunarFestival");
    COPY_JSON_STR(IMonthCn, "IMonthCn");
    COPY_JSON_STR(IDayCn, "IDayCn");
    COPY_JSON_STR(gzYear, "gzYear");
    COPY_JSON_STR(gzMonth, "gzMonth");
    COPY_JSON_STR(gzDay, "gzDay");
    COPY_JSON_STR(ncWeek, "ncWeek");
    COPY_JSON_STR(Term, "Term");
    COPY_JSON_STR(astro, "astro");

    cJSON_Delete(root);
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    return 0;
}

static LunarInfo g_lunar_info = {0};
static int g_lunar_info_valid = 0;

static void show_lunar_for_today(const Time_data* t)
{
    if (!g_lunar_info_valid) {
        char date_str[32];
        snprintf(date_str, sizeof(date_str), "%04d-%02d-%02d", t->years + 2000, t->months, t->days);
        if (fetch_lunar_info(date_str, &g_lunar_info) == 0) {
            g_lunar_info_valid = 1;
        }
    }
    if (g_lunar_info_valid) {
        ESP_LOGI("lunar", "Chinese calendar: %s %s%s festival: %s solar terms: %s constellation: %s", g_lunar_info.lunarDate, g_lunar_info.IMonthCn, g_lunar_info.IDayCn, g_lunar_info.festival, g_lunar_info.Term, g_lunar_info.astro);
    } else {
        ESP_LOGW("lunar", "The lunar calendar information acquisition failed");
    }
}


// Obtain the number of days of the specified Gregorian calendar year and month
static int get_days_in_month(int year, int month)
{
    static const int days[12] = {31,28,31,30,31,30,31,31,30,31,30,31};
    if (month < 1 || month > 12) return 0;
    if (month == 2) { // February in a leap year
        if ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0))
            return 29;
    }
    return days[month - 1];
}


// Check whether the SD card has been mounted
static bool is_sdcard_mounted(void) {
    struct stat st;
    // Check whether the /sdcard directory exists and is a directory
    if (stat("/sdcard", &st) == 0 && S_ISDIR(st.st_mode)) {
        return true;
    }
    ESP_LOGW("lunar", "If the SD card is not mounted, it will switch to SPIFFS storage");
    return false;
}
// Main function: Obtain the entire lunar calendar of the month and save it to the SD card
static void fetch_and_save_lunar_month_to_sd(const char* year, const char* month, LunarInfo* month_info)
{
    if (!year || !month || !month_info) {
        ESP_LOGE("lunar", "Invalid parameters");
        return;
    }

    int y = atoi(year);
    int m = atoi(month);
    int days = get_days_in_month(y, m);
    if (days <= 0 || days > 31) {
        ESP_LOGE("lunar", "Invalid days in month: %d", days);
        return;
    }

    // Loop to obtain the lunar information of all dates in the current month (up to 5 retries)
    for (int day = 1; day <= days; ++day) {
        char date_str[32];
        snprintf(date_str, sizeof(date_str), "%04d-%02d-%02d", y, m, day);
        
        int retry = 1;
        while((fetch_lunar_info(date_str, &month_info[day-1]) != 0) && (retry < 6)) {
            retry++;
            ESP_LOGW("lunar", "Failed to obtain %s. Retry %d/5", date_str, retry);
        }
        
        if (retry >= 6) {
            ESP_LOGE("lunar", "Failed to obtain %s after 5 retries", date_str);
        }
    }

    // Select the storage path based on the mount status of the SD card
    bool use_sdcard = is_sdcard_mounted();
    char dir_path[64];
    char file_path[64];
    
    if (use_sdcard) {
        // SD card mounted: Save to SD card
        snprintf(dir_path, sizeof(dir_path), "/sdcard/lunar");
        snprintf(file_path, sizeof(file_path), "/sdcard/lunar/%s-%s.json", year, month);

        // create directory
        if (mkdir(dir_path, 0777) != 0 && errno != EEXIST) {
            ESP_LOGE("lunar", "Failed to create directory: %s, errno: %d", dir_path, errno);
            return;
        }
    } else {
        // SD card not mounted: Save to SPIFFS
        snprintf(file_path, sizeof(file_path), "/spiffs/lunar_%s-%s.json", year, month);
    }

    FILE* fp = fopen(file_path, "w");
    if (!fp) {
        ESP_LOGE("lunar", "Cannot open file for writing: %s", file_path);
        return;
    }

    cJSON* root = cJSON_CreateArray();
    if (!root) {
        ESP_LOGE("lunar", "Failed to create JSON root array");
        fclose(fp);
        return;
    }

    for (int i = 0; i < days; ++i) {
        cJSON* day_obj = cJSON_CreateObject();
        if (!day_obj) {
            ESP_LOGE("lunar", "Failed to create JSON object for day %d", i+1);
            continue;
        }

        cJSON_AddStringToObject(day_obj, "lunarDate", month_info[i].lunarDate);
        cJSON_AddStringToObject(day_obj, "festival", month_info[i].festival);
        cJSON_AddStringToObject(day_obj, "lunarFestival", month_info[i].lunarFestival);
        cJSON_AddStringToObject(day_obj, "IMonthCn", month_info[i].IMonthCn);
        cJSON_AddStringToObject(day_obj, "IDayCn", month_info[i].IDayCn);
        cJSON_AddStringToObject(day_obj, "gzYear", month_info[i].gzYear);
        cJSON_AddStringToObject(day_obj, "gzMonth", month_info[i].gzMonth);
        cJSON_AddStringToObject(day_obj, "gzDay", month_info[i].gzDay);
        cJSON_AddStringToObject(day_obj, "ncWeek", month_info[i].ncWeek);
        cJSON_AddStringToObject(day_obj, "Term", month_info[i].Term);
        cJSON_AddStringToObject(day_obj, "astro", month_info[i].astro);

        cJSON_AddItemToArray(root, day_obj);
    }

    char* json_str = cJSON_PrintUnformatted(root);
    if (json_str) {
        size_t write_len = fwrite(json_str, 1, strlen(json_str), fp);
        if (write_len != strlen(json_str)) {
            ESP_LOGE("lunar", "Failed to write all data: wrote %zu/%zu bytes", write_len, strlen(json_str));
        }
        free(json_str);
    } else {
        ESP_LOGE("lunar", "Failed to print JSON");
    }

    fflush(fp);
    fclose(fp);
    cJSON_Delete(root);

    ESP_LOGI("lunar", "Lunar calendar saved to %s: %s", use_sdcard ? "SD card" : "SPIFFS", file_path);
}

static int load_lunar_month_from_sd(const char* year, const char* month, LunarInfo* month_info)
{
    char file_path[64];
    bool use_sdcard = is_sdcard_mounted();
    if (use_sdcard) {
        snprintf(file_path, sizeof(file_path), "/sdcard/lunar/%s-%s.json", year, month);
    } else {
        snprintf(file_path, sizeof(file_path), "/spiffs/lunar_%s-%s.json", year, month);
    }

    int y = atoi(year);
    int m = atoi(month);
    int max_days = get_days_in_month(y, m);

    FILE* fp = fopen(file_path, "r");
    if (!fp) {
        ESP_LOGE("lunar", "Cannot open the file: %s", file_path);
        return -1;
    }

    fseek(fp, 0, SEEK_END);
    long len = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    char* buf = (char*)malloc(len + 1);
    fread(buf, 1, len, fp);
    buf[len] = 0;
    fclose(fp);

    cJSON* root = cJSON_Parse(buf);
    free(buf);
    if (!root) return -1;

    int day_count = cJSON_GetArraySize(root);
    if (day_count > max_days) day_count = max_days;

    for (int i = 0; i < day_count; ++i) {
        cJSON* day_obj = cJSON_GetArrayItem(root, i);
        #define READ_JSON_STR(field, key) do { \
            cJSON* item = cJSON_GetObjectItem(day_obj, key); \
            if (item && cJSON_IsString(item)) strncpy(month_info[i].field, item->valuestring, sizeof(month_info[i].field)-1); \
            else month_info[i].field[0] = 0; \
        } while(0)
        READ_JSON_STR(IDayCn, "day");
        READ_JSON_STR(lunarFestival, "lunarFestival");
        READ_JSON_STR(festival, "festival");
        READ_JSON_STR(gzYear, "gzYear");
        READ_JSON_STR(gzMonth, "gzMonth");
        READ_JSON_STR(gzDay, "gzDay");
        READ_JSON_STR(ncWeek, "ncWeek");
        READ_JSON_STR(lunarDate, "lunarDate");
        READ_JSON_STR(IMonthCn, "IMonthCn");
        READ_JSON_STR(IDayCn, "IDayCn");
        READ_JSON_STR(Term, "Term");
        READ_JSON_STR(astro, "astro");
    }
    cJSON_Delete(root);
    return day_count;
}

// E-paper refresh function
static void display_clock_init(void)
{
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 0, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);

#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_temperature, 148, 64, 48, 48);
    Paint_ReadBmp(gImage_humidity, 450, 64, 48, 48);
    Paint_ReadBmp(gImage_point_in_time, 379, 184, 42, 132);
    Paint_ReadBmp(gImage_BAT_1, 526, 410, 32, 32);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_TEMPERATURE_PATH, 148, 64);
    GUI_ReadBmp(BMP_HUMIDITY_PATH, 450, 64);
    GUI_ReadBmp(BMP_POINT_IN_TIME_PATH, 379, 184);
    GUI_ReadBmp(BMP_BAT_1_PATH, 526, 410);
#endif
}


void Forced_refresh_clock(void)
{
    EPD_Display_Base(Image_Mono);
}
void Refresh_page_clock(void)
{
    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
}

static void display_clock_nvs_img()
{
    display_clock_init();
    char Time_str[50]={0};
    char hours[10] = {0};
    char minutes[10] = {0};
    const char* week_str[] = {"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"};

    ESP_LOGI("clock", "current time: %04d-%02d-%02d %02d:%02d week:%s", Clock_TH_Old.years + 2000, Clock_TH_Old.months, Clock_TH_Old.days, Clock_TH_Old.hours, Clock_TH_Old.minutes, week_str[Clock_TH_Old.week]);

    snprintf(Time_str, sizeof(Time_str), "%04d-%02d-%02d %s", Clock_TH_Old.years + 2000, Clock_TH_Old.months, Clock_TH_Old.days, week_str[Clock_TH_Old.week]);

    snprintf(hours, sizeof(hours), "%02d", Clock_TH_Old.hours);
    snprintf(minutes, sizeof(minutes), "%02d", Clock_TH_Old.minutes);
    
    Paint_DrawString_EN(129, 157, hours, &Font182, WHITE, BLACK);
    Paint_DrawString_EN(431, 157, minutes, &Font182, WHITE, BLACK);
    Paint_DrawString_CN(125, 410, Time_str, &Font18_UTF8, WHITE, BLACK);

    char temperature_str[10] = {0};
    char humidity_str[10] = {0};
    ESP_LOGI("TemperatureHumidity", "Temperature = %.2f C, Humidity = %.2f%%", Clock_TH_Old.temperature_val, Clock_TH_Old.humidity_val);
    snprintf(temperature_str, sizeof(temperature_str), "%2.1f℃", Clock_TH_Old.temperature_val);
    snprintf(humidity_str, sizeof(humidity_str), "%2.1f％", Clock_TH_Old.humidity_val);
    Paint_DrawRectangle(208, 67, 328, 108, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(208, 67, temperature_str, &Font24_UTF8, WHITE, BLACK);
    Paint_DrawRectangle(510, 67, 630, 108, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(510, 67, humidity_str, &Font24_UTF8, WHITE, BLACK);    

    int BAT_Power;
    char BAT_str[10] = {0};
    BAT_Power = Clock_TH_Old.BAT_Power;
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%", BAT_Power);
    Clock_TH_Old.BAT_Power = BAT_Power;
    snprintf(BAT_str, sizeof(BAT_str), "%d％", BAT_Power);
    if (BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawRectangle(531, 423, 551, 431, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(531, 423, 531 + BAT_Power, 431, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(568, 410, 688, 441, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(568, 410, BAT_str, &Font18_UTF8, WHITE, BLACK);
}

static void display_clock_mode_img(Time_data rtc_time)
{
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 0, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);

    // The SD card reads the corresponding file and writes it into the cache
    if (!sd_read_file_to_buffer(CLOCK_PARTIAL_PATH, Image_Mono, EPD_SIZE_MONO)) {
        ESP_LOGI("sdio", "The local cache file is not loaded and is displayed using the current buffer");
        load_clock_from_nvs();
        display_clock_nvs_img();
    }

    EPD_Display_Partial(Image_Mono, 0, 0, EPD_WIDTH, EPD_HEIGHT);

    ESP_LOGI("clock", "current time: %04d-%02d-%02d %02d:%02d:%02d", rtc_time.years + 2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds);
    
    char minutes[10] = {0};
    Clock_TH_Old.minutes = rtc_time.minutes;
    snprintf(minutes, sizeof(minutes), "%02d", rtc_time.minutes);
    Paint_DrawString_EN(431, 157, minutes, &Font182, WHITE, BLACK);

    float temperature_val = 0.0f;
    float humidity_val = 0.0f;
    char temperature_str[10] = {0};
    char humidity_str[10] = {0};
    SHTC3_GetEnvTemperatureHumidity(&temperature_val, &humidity_val);
    ESP_LOGI("TemperatureHumidity", "Temperature = %.2f C, Humidity = %.2f%%", temperature_val, humidity_val);
    Clock_TH_Old.temperature_val = temperature_val;
    Clock_TH_Old.humidity_val = humidity_val;
    snprintf(temperature_str, sizeof(temperature_str), "%2.1f℃", temperature_val);
    snprintf(humidity_str, sizeof(humidity_str), "%2.1f％", humidity_val);
    Paint_DrawRectangle(208, 67, 328, 108, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(208, 67, temperature_str, &Font24_UTF8, WHITE, BLACK);
    Paint_DrawRectangle(510, 67, 630, 108, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(510, 67, humidity_str, &Font24_UTF8, WHITE, BLACK);    

    int BAT_Power;
    char BAT_str[10] = {0};
    BAT_Power = get_battery_power();
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%", BAT_Power);
    Clock_TH_Old.BAT_Power = BAT_Power;
    snprintf(BAT_str, sizeof(BAT_str), "%d％", BAT_Power);
    if (BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawRectangle(531, 423, 551, 431, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(531, 423, 531 + BAT_Power, 431, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(568, 410, 688, 441, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(568, 410, BAT_str, &Font18_UTF8, WHITE, BLACK);

    EPD_Display_Partial(Image_Mono, 0, 0, EPD_WIDTH, EPD_HEIGHT);

    // The data in the cache is written to the corresponding SD card
    if (!sd_write_buffer_to_file(CLOCK_PARTIAL_PATH, Image_Mono, EPD_SIZE_MONO)) {
        ESP_LOGW("sdio", "Failed to save the local cache to SD: %s", CLOCK_PARTIAL_PATH);
        save_clock_to_nvs_if_changed();
    }
}


static void display_clock_img(Time_data rtc_time, int Refresh_mode)
{
    char Time_str[50]={0};
    char hours[10] = {0};
    char minutes[10] = {0};
    const char* week_str[] = {"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"};

    ESP_LOGI("clock", "current time: %04d-%02d-%02d %02d:%02d:%02d week:%s", rtc_time.years + 2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds, week_str[rtc_time.week]);

    Clock_TH_Old.years = rtc_time.years;
    Clock_TH_Old.months = rtc_time.months;
    Clock_TH_Old.days = rtc_time.days;
    Clock_TH_Old.week = rtc_time.week;

    snprintf(Time_str, sizeof(Time_str), "%04d-%02d-%02d %s", rtc_time.years + 2000, rtc_time.months, rtc_time.days, week_str[rtc_time.week]);

    Clock_TH_Old.hours = rtc_time.hours;
    Clock_TH_Old.minutes = rtc_time.minutes;
    snprintf(hours, sizeof(hours), "%02d", rtc_time.hours);
    snprintf(minutes, sizeof(minutes), "%02d", rtc_time.minutes);
    
    Paint_DrawString_EN(129, 157, hours, &Font182, WHITE, BLACK);
    Paint_DrawString_EN(431, 157, minutes, &Font182, WHITE, BLACK);
    Paint_DrawString_CN(125, 410, Time_str, &Font18_UTF8, WHITE, BLACK);

    float temperature_val = 0.0f;
    float humidity_val = 0.0f;
    char temperature_str[10] = {0};
    char humidity_str[10] = {0};
    SHTC3_GetEnvTemperatureHumidity(&temperature_val, &humidity_val);
    ESP_LOGI("TemperatureHumidity", "Temperature = %.2f C, Humidity = %.2f%%", temperature_val, humidity_val);
    Clock_TH_Old.temperature_val = temperature_val;
    Clock_TH_Old.humidity_val = humidity_val;
    snprintf(temperature_str, sizeof(temperature_str), "%2.1f℃", temperature_val);
    snprintf(humidity_str, sizeof(humidity_str), "%2.1f％", humidity_val);
    Paint_DrawRectangle(208, 67, 328, 108, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(208, 67, temperature_str, &Font24_UTF8, WHITE, BLACK);
    Paint_DrawRectangle(510, 67, 630, 108, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(510, 67, humidity_str, &Font24_UTF8, WHITE, BLACK);    

    int BAT_Power;
    char BAT_str[10] = {0};
    BAT_Power = get_battery_power();
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%", BAT_Power);
    Clock_TH_Old.BAT_Power = BAT_Power;
    snprintf(BAT_str, sizeof(BAT_str), "%d％", BAT_Power);
    if (BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawRectangle(531, 423, 551, 431, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(531, 423, 531 + BAT_Power, 431, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(568, 410, 688, 441, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(568, 410, BAT_str, &Font18_UTF8, WHITE, BLACK);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(Image_Mono);
    } else if (Refresh_mode == Partial_refresh) {
        EPD_Display_Partial(Image_Mono_last, 0, 0, EPD_WIDTH, EPD_HEIGHT);
        EPD_Display_Partial(Image_Mono, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    }

    if(load_mode_enable_from_nvs()) {
        if (!sd_write_buffer_to_file(CLOCK_PARTIAL_PATH, Image_Mono, EPD_SIZE_MONO)) {
            ESP_LOGW("sdio", "Failed to save the local cache to SD: %s", CLOCK_PARTIAL_PATH);
            save_clock_to_nvs_if_changed();
        }
    } else {
        for (size_t i = 0; i < EPD_SIZE_MONO; i++)
        {
            Image_Mono_last[i] = Image_Mono[i];
        }
    }
    
}


static void display_calendar_img(Time_data rtc_time, LunarInfo* month_info)
{

    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 0, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
    int BAT_Power;
    char BAT_str[10] = {0};
    BAT_Power = get_battery_power();
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%", BAT_Power);
    snprintf(BAT_str, sizeof(BAT_str), "%d％", BAT_Power);
    if (BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;

#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_BAT,694,28,32,16);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_BAT_PATH, 694, 28);
#endif
    Paint_DrawRectangle(699, 33, 719, 41, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(699, 33, 699+BAT_Power, 41, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(734, 25, 800, 60, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(734, 25, BAT_str, &Font12_UTF8, WHITE, BLACK);

    Paint_DrawRectangle(3, 70, 113, 106, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(46, 74, "一", &Font16_UTF8, BLACK, WHITE);
    Paint_DrawRectangle(117, 70, 227, 106, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(161, 74, "二", &Font16_UTF8, BLACK, WHITE);
    Paint_DrawRectangle(231, 70, 341, 106, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(274, 74, "三", &Font16_UTF8, BLACK, WHITE);
    Paint_DrawRectangle(345, 70, 455, 106, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(388, 74, "四", &Font16_UTF8, BLACK, WHITE);
    Paint_DrawRectangle(459, 70, 569, 106, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(502, 74, "五", &Font16_UTF8, BLACK, WHITE);
    Paint_DrawRectangle(573, 70, 683, 106, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(616, 74, "六", &Font16_UTF8, BLACK, WHITE);
    Paint_DrawRectangle(687, 70, 797, 106, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(730, 74, "日", &Font16_UTF8, BLACK, WHITE);


    char Time_str[50]={0};

    ESP_LOGI("clock", "current time: %04d-%02d-%02d %02d:%02d:%02d week: %d", rtc_time.years + 2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds, rtc_time.week);

    snprintf(Time_str, sizeof(Time_str), "%04d-%02d-%02d", rtc_time.years + 2000, rtc_time.months, rtc_time.days);
    Paint_DrawString_CN(24, 18, Time_str, &Font24_UTF8, WHITE, BLACK);
    
    char year_str[8], month_str[8];
    snprintf(year_str, sizeof(year_str), "%04d", rtc_time.years + 2000);
    snprintf(month_str, sizeof(month_str), "%02d", rtc_time.months);

    int lunar_days = 0;
    char lunar_file[64];
    bool use_sdcard = is_sdcard_mounted();

    if (use_sdcard) {
        snprintf(lunar_file, sizeof(lunar_file), "/sdcard/lunar/%04d-%02d.json", rtc_time.years + 2000, rtc_time.months);
    } else {
        snprintf(lunar_file, sizeof(lunar_file), "/spiffs/lunar_%04d-%02d.json", rtc_time.years + 2000, rtc_time.months);
    }

    ESP_LOGI("lunar", "lunar = %s",lunar_file);
    FILE* fp = fopen(lunar_file, "r");
    bool file_exist = (fp != NULL);
    ESP_LOGI("lunar", "file_exist = %d",file_exist);

    char lunar_days_str[128] = {0};
    char calendar_days_str[16] = {0};
    if (!file_exist) {
        if (fp) fclose(fp);
        if(wifi_is_connected())
        {
            esp_netif_ip_info_t ip_info;
            esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
            esp_err_t ip_ret = esp_netif_get_ip_info(netif, &ip_info);
            if (ip_ret != ESP_OK || ip_info.ip.addr == 0) {
                ESP_LOGI("lunar", "The IP address for WiFi was not obtained. Please check your network!");
                Paint_DrawString_CN(10, 110, "WiFi未获取到IP地址，请检查网络！", &Font24_UTF8, WHITE, BLACK);
            } else {
                ESP_LOGI("lunar", "The lunar calendar data is being obtained and saved through the network connection...");
                Paint_DrawString_CN(10, 110, "正在联网获取并保存农历数据...", &Font24_UTF8, WHITE, BLACK);
                Refresh_page_clock();
                fetch_and_save_lunar_month_to_sd(year_str, month_str, month_info);
                fp = fopen(lunar_file, "r");
                file_exist = (fp != NULL);
                fclose(fp);
                Paint_DrawRectangle(0, 110, EPD_WIDTH, EPD_HEIGHT, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            }
        } else {
            ESP_LOGI("lunar", "There is no network connection and no local files. Calendar acquisition failed...");
            Paint_DrawString_CN(10, 110, "无网络连接，也无本地文件，日历获取失败", &Font24_UTF8, WHITE, BLACK);
        }
    } 

    if(file_exist) {
        ESP_LOGI("lunar", "The local lunar data file has been found: %s", lunar_file);
        lunar_days = load_lunar_month_from_sd(year_str, month_str, month_info);
    } else if(wifi_is_connected()){
        int y = atoi(year_str);
        int m = atoi(month_str);
        lunar_days = get_days_in_month(y, m);
    } else {
        lunar_days = 0;
    }
    
    if(lunar_days) {
        int day = rtc_time.days;
        if (day >= 1 && day <= lunar_days) {
            LunarInfo* info = &month_info[day-1];
            ESP_LOGI("lunar", "Chinese calendar: %s %s%s%s festival: %s solar terms: %s week: %s", info->lunarDate, info->gzYear, info->IMonthCn, info->IDayCn, info->lunarFestival[0] ? info->lunarFestival : info->festival, info->Term, info->ncWeek);
            snprintf(lunar_days_str, sizeof(lunar_days_str), "%s%s%s  %s", info->gzYear, info->IMonthCn, info->IDayCn, info->ncWeek);
            Paint_DrawString_CN(280, 27, lunar_days_str, &Font16_UTF8, WHITE, BLACK);
        } else {
            ESP_LOGW("lunar", "The lunar information for that day does not exist");
            const char* fallback_week = (month_info && month_info[0].ncWeek[0]) ? month_info[0].ncWeek : "";
            snprintf(lunar_days_str, sizeof(lunar_days_str), "当天农历信息不存在  %s", fallback_week);
            Paint_DrawString_CN(280, 27, lunar_days_str, &Font16_UTF8, WHITE, BLACK);
        }

        int x_[7] = {3,117,231,345,459,573,687};
        int x_e[7] = {58,172,286,400,514,628,742};
        int y[5] = {110,184,258,332,406};
        int y_e[5] = {117,191,265,339,413};
        int y_c[5] = {152,226,300,374,448};
        int x_size = 0;
        int y_size = 0;
        uint16_t x_or = 0;
        const char* week_str[] = {"星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"};
        if (month_info && month_info[0].ncWeek[0] != '\0') {
            for (size_t i = 0; i < 7; i++) {
                if (strcmp(month_info[0].ncWeek, week_str[i]) == 0) {
                    x_size = (int)i;
                    break;
                }
            }
        }
        ESP_LOGI("lunar", "month start weekday index = %d", x_size + 1);

        for (int i = 0; i < lunar_days; i++) {
            if(x_size > 6){
                y_size++;
                x_size=0;
            }
            if (y_size > 4){
                y_size = 0;
            }

            if (i == day - 1) {
                Paint_DrawRectangle(x_[x_size], y[y_size], x_[x_size] + 110, y[y_size] + 70, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
            }

            // Japanese version of the Gregorian calendar
            snprintf(calendar_days_str, sizeof(calendar_days_str), "%d", i + 1);
            x_or = reassignCoordinates_EN(x_e[x_size], calendar_days_str, &Font16);
            Paint_DrawString_EN(x_or, y_e[y_size], calendar_days_str, &Font16, WHITE, BLACK);

            // Lunar/festival priority: Lunar Festival > festival > Term > IDayCn
            if (month_info[i].lunarFestival[0] != '\0') {
                x_or = reassignCoordinates_CH(x_e[x_size], month_info[i].lunarFestival, &Font12_UTF8);
                Paint_DrawString_CN(x_or, y_c[y_size], month_info[i].lunarFestival, &Font12_UTF8, WHITE, BLACK);
            } else if (month_info[i].festival[0] != '\0') {
                x_or = reassignCoordinates_CH(x_e[x_size], month_info[i].festival, &Font12_UTF8);
                Paint_DrawString_CN(x_or, y_c[y_size], month_info[i].festival, &Font12_UTF8, WHITE, BLACK);
            } else if (month_info[i].Term[0] != '\0') {
                x_or = reassignCoordinates_CH(x_e[x_size], month_info[i].Term, &Font12_UTF8);
                Paint_DrawString_CN(x_or, y_c[y_size], month_info[i].Term, &Font12_UTF8, WHITE, BLACK);
            } else if (month_info[i].IDayCn[0] != '\0') {
                if(strcmp(month_info[i].IDayCn, "初一") == 0) {
                    x_or = reassignCoordinates_CH(x_e[x_size], month_info[i].IMonthCn, &Font12_UTF8);
                    Paint_DrawString_CN(x_or, y_c[y_size], month_info[i].IMonthCn, &Font12_UTF8, WHITE, BLACK);
                } else {
                    x_or = reassignCoordinates_CH(x_e[x_size], month_info[i].IDayCn, &Font12_UTF8);
                    Paint_DrawString_CN(x_or, y_c[y_size], month_info[i].IDayCn, &Font12_UTF8, WHITE, BLACK);
                }
                
            }

            x_size++;
            // if (x_size >= 7) x_size = 0;
        }
    }

    ESP_LOGI("clock", "EPD_Init");
    EPD_Init();
    Forced_refresh_clock();
    ESP_LOGI("clock", "EPD_Sleep");
    EPD_Sleep();

}


// "Lunar calendar acquisition"
int Lunar_calendar_acquisition(char *str, int str_len, const char* Time)
{
    LunarInfo month_info;

    if(fetch_lunar_info(Time, &month_info) == 0) {
        snprintf(str, str_len, "%s %s %s", month_info.gzYear, month_info.IMonthCn, month_info.IDayCn);
        return 0;
    } else {
        snprintf(str, str_len, "fail to get");
        return -1;
    }
    
}






