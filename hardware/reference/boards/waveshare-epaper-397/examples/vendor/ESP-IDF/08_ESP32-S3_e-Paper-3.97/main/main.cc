#include <stdio.h>
#include <inttypes.h>
#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_chip_info.h"
// #include "esp_flash.h"
#include "esp_system.h"
#include <nvs.h>
#include <nvs_flash.h>
#include "esp_wifi.h"
#include "sdmmc_cmd.h"

// Module header file
#include "esp_wifi_bsp.h"
#include "button_bsp.h"
#include "i2c_bsp.h"
#include "shtc3_bsp.h"
#include "pcf85063_bsp.h"
#include "sdcard_bsp.h"
#include "epaper_bsp.h"
#include "epaper_port.h"
#include "es8311_bsp.h"
#include "qmi8658_bsp.h"
#include "axp_prot.h"
#include "wifi_configuration_ap.h"
#include "wifi_station.h"
#include "ssid_manager.h"

// Page header file
#include "file_browser.h"
#include "page_network.h"
#include "page_weather.h"
#include "page_clock.h"
#include "page_alarm.h"
#include "page_audio.h"
#include "page_settings.h"
#include "page_fiction.h"

#include "freertos/semphr.h"


// Create a mutex lock to protect the device from interference when reading
SemaphoreHandle_t alarm_mutex = NULL; // protect alarms
SemaphoreHandle_t rtc_mutex = NULL;   // protect RTC
SemaphoreHandle_t nvs_mutex = NULL;   // protect NVS
SemaphoreHandle_t qmi8658_mutex = NULL;   // protect qmi8658

// The wifi is on indicator
bool wifi_enable;      


// The priority of creating thread tasks
#define ALARM_TASK_PRIO   5
#define USER_TASK_PRIO    3

// Quantity of individual main courses
#define HOME_PAGE_NUM   8

// E-ink screen sleep time (S)
#define EPD_Sleep_Time   60
// Equipment shutdown time (minutes)
#define Unattended_Time  10

// Icon location
#define Icon_X_1   77
#define Icon_X_2   307
#define Icon_Y_1   78
#define Icon_Y_2   264
#define Icon_Y_3   450
#define Icon_Y_4   636

#define Text_X_1   Icon_X_1 + 48
#define Text_X_2   Icon_X_2 + 48
#define Text_Y_1   Icon_Y_1 + 100
#define Text_Y_2   Icon_Y_2 + 100
#define Text_Y_3   Icon_Y_3 + 100
#define Text_Y_4   Icon_Y_4 + 100


// Define the data cache area of the e-ink screen
uint8_t *Image_Mono;

// Main menu content
const char *home_page[HOME_PAGE_NUM] = {"文件","时钟","日历","闹钟","天气","网络","音频","阅读"};

// Log tag
static const char *TAG = "main";


void draw_selection_box_old(int selection)
{
    // Define the position and size of each menu item
    const int box_width = 210;
    const int box_height = 160;
    
    int y_positions[8] = {57, 57, 243, 243, 429, 429, 615, 615}; 
    int x_positions[8] = {20, 250, 20, 250, 20, 250, 20, 250}; 
    if (selection >= 0 && selection < 8) {
        int x = x_positions[selection];  // The frame is slightly larger
        int y = y_positions[selection];
        
        Paint_DrawRectangle(x, y, x + box_width, y + box_height, WHITE, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    }
}

void draw_selection_box(int selection)
{
    // Define the position and size of each menu item
    const int box_width = 210;
    const int box_height = 160;
    
    int y_positions[8] = {57, 57, 243, 243, 429, 429, 615, 615}; 
    int x_positions[8] = {20, 250, 20, 250, 20, 250, 20, 250}; 

    if (selection >= 0 && selection < 8) {
        int x = x_positions[selection];
        int y = y_positions[selection];
        
        Paint_DrawRectangle(x, y, x + box_width, y + box_height, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    }
}

// The main page displays
void esp_home(int selection, int Refresh_mode)
{
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
    uint16_t x_or = 0;
    char Time_str[16]={0};
    int BAT_Power;
    char BAT_Power_str[16]={0};

    // Draw the top state
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
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    snprintf(BAT_Power_str, sizeof(BAT_Power_str), "%d%%", BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawString_EN(411, 11, BAT_Power_str, &Font16, WHITE, BLACK);
    Paint_DrawRectangle(375, 22, 395, 30, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(375, 22, 375+BAT_Power, 30, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawLine(2, 54, EPD_HEIGHT-2, 54, BLACK, DOT_PIXEL_2X2, LINE_STYLE_SOLID);

// Use the built-in image or the TF card image
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_file,Icon_X_1,Icon_Y_1,96,96);
    Paint_ReadBmp(gImage_clock,Icon_X_2,Icon_Y_1,96,96);
    Paint_ReadBmp(gImage_calendar,Icon_Y_1,Icon_Y_2,96,96);
    Paint_ReadBmp(gImage_alarm,Icon_X_2,Icon_Y_2,96,96);
    Paint_ReadBmp(gImage_weather,Icon_Y_1,Icon_Y_3,96,96);
    Paint_ReadBmp(gImage_network,Icon_X_2,Icon_Y_3,96,96);
    Paint_ReadBmp(gImage_audio_file,Icon_Y_1,Icon_Y_4,96,96);
    Paint_ReadBmp(gImage_read,Icon_X_2,Icon_Y_4,96,96);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_FILE_PATH,Icon_X_1,Icon_Y_1);
    GUI_ReadBmp(BMP_CLOCK_PATH,Icon_X_2,Icon_Y_1);
    GUI_ReadBmp(BMP_CALENDAR_PATH,Icon_Y_1,Icon_Y_2);
    GUI_ReadBmp(BMP_ALARM_PATH,Icon_X_2,Icon_Y_2);
    GUI_ReadBmp(BMP_WEATHER_PATH,Icon_Y_1,Icon_Y_3);
    GUI_ReadBmp(BMP_NETWORK_PATH,Icon_X_2,Icon_Y_3);
    GUI_ReadBmp(BMP_AUDIO_FILE_PATH,Icon_Y_1,Icon_Y_4);
    GUI_ReadBmp(BMP_READ_PATH,Icon_X_2,Icon_Y_4);
#endif
    x_or = reassignCoordinates_CH(Text_X_1,home_page[0],&Font16_UTF8);
    Paint_DrawString_CN(x_or, Text_Y_1, home_page[0], &Font16_UTF8, WHITE, BLACK);
    x_or = reassignCoordinates_CH(Text_X_2,home_page[1],&Font16_UTF8);
    Paint_DrawString_CN(x_or, Text_Y_1, home_page[1], &Font16_UTF8, WHITE, BLACK);
    x_or = reassignCoordinates_CH(Text_X_1,home_page[2],&Font16_UTF8);
    Paint_DrawString_CN(x_or, Text_Y_2, home_page[2], &Font16_UTF8, WHITE, BLACK);
    x_or = reassignCoordinates_CH(Text_X_2,home_page[3],&Font16_UTF8);
    Paint_DrawString_CN(x_or, Text_Y_2, home_page[3], &Font16_UTF8, WHITE, BLACK);
    x_or = reassignCoordinates_CH(Text_X_1,home_page[4],&Font16_UTF8);
    Paint_DrawString_CN(x_or, Text_Y_3, home_page[4], &Font16_UTF8, WHITE, BLACK);
    x_or = reassignCoordinates_CH(Text_X_2,home_page[5],&Font16_UTF8);
    Paint_DrawString_CN(x_or, Text_Y_3, home_page[5], &Font16_UTF8, WHITE, BLACK);
    x_or = reassignCoordinates_CH(Text_X_1,home_page[6],&Font16_UTF8);
    Paint_DrawString_CN(x_or, Text_Y_4, home_page[6], &Font16_UTF8, WHITE, BLACK);
    x_or = reassignCoordinates_CH(Text_X_2,home_page[7],&Font16_UTF8);
    Paint_DrawString_CN(x_or, Text_Y_4, home_page[7], &Font16_UTF8, WHITE, BLACK);

    // Draw a selection box based on the selected items
    draw_selection_box(selection);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(Image_Mono);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
    }
}

// On the main page, select "Process" at the top or bottom
void Page_Down_home(int selection, int Refresh_mode)
{
    int selection_old = selection - 1 ;
    if((selection-1) < 0 ) selection_old = HOME_PAGE_NUM - 1;
    draw_selection_box_old(selection_old);
    draw_selection_box(selection);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(Image_Mono);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
    }
}
void Page_Up_home(int selection, int Refresh_mode)
{
    int selection_old = selection + 1 ;
    if((selection + 1) >= HOME_PAGE_NUM ) selection_old = 0;
    draw_selection_box_old(selection_old);
    draw_selection_box(selection);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(Image_Mono);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
    }
}

// Display time and battery level
void display_home_time_img(Time_data rtc_time)
{
    char Time_str[16]={0};
    int BAT_Power;
    char BAT_Power_str[16]={0};

    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", rtc_time.hours, rtc_time.minutes);
    Paint_DrawString_EN(20, 11, Time_str, &Font16, WHITE, BLACK);

// Use the built-in image or the TF card image
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    if (wifi_enable) Paint_ReadBmp(gImage_WIFI, 326, 8, 32, 32);
    Paint_ReadBmp(gImage_BAT, 370, 17, 32, 16);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    if (wifi_enable) GUI_ReadBmp(BMP_WIFI_PATH, 326, 8);
    GUI_ReadBmp(BMP_BAT_PATH, 370, 17);
#endif
    BAT_Power = get_battery_power();
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    snprintf(BAT_Power_str, sizeof(BAT_Power_str), "%d%%", BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawString_EN(411, 11, BAT_Power_str, &Font16, WHITE, BLACK);
    Paint_DrawRectangle(375, 22, 395, 30, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(375, 22, 375+BAT_Power, 30, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);

    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
}
static void display_home_time_img_last(Time_data rtc_time)
{
    char Time_str[20]={0};
    int hours = rtc_time.hours;
    int minutes = rtc_time.minutes-1;

    if(minutes < 0){
        minutes = 59;
        hours = rtc_time.hours - 1;
        if(hours < 0 )
            hours = 23;
    }

    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", hours, minutes);
    Paint_DrawString_EN(20, 11, Time_str, &Font16, WHITE, BLACK);

    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
}


// Main menu task
void user_Task(void *arg)
{
    int home_selection = 0; // Current main menu options
    int button = -1;        // Key status

    int time_count = 0;
    Time_data rtc_time = {0};
    int last_minutes = -1;
    
    esp_home(home_selection, Global_refresh);
    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);
    last_minutes = rtc_time.minutes;

    while (1)
    {
        // // The log loop prints the main menu
        // for (int i = 0; i < HOME_PAGE_NUM; ++i) {
        //     ESP_LOGI("home", "%s%s", home_page[i], (i == home_selection) ? " <" : "");
        // }

        button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        time_count++;

        if((time_count > EPD_Sleep_Time)) {
            ESP_LOGI("home", "EPD_Sleep");
            EPD_Sleep();
            int sleep_js = 0;
            while(1)
            {
                button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
                if (button == 12){
                    ESP_LOGI("home", "EPD_Init");
                    EPD_Init();
                    time_count = 0;
                    break;
                } else if (button == 8 || button == 22 || button == 14 || button == 0 || button == 7 || button == 23){
                    ESP_LOGI("home", "EPD_Init");
                    EPD_Init();
                    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
                    time_count = 0;
                    break;
                }
                xSemaphoreTake(rtc_mutex, portMAX_DELAY);
                rtc_time = PCF85063_GetTime();
                xSemaphoreGive(rtc_mutex);
                // Refresh the time and battery level once every minute
                if(rtc_time.minutes != last_minutes) {
                    last_minutes = rtc_time.minutes;
                    ESP_LOGI("home", "EPD_Init");
                    EPD_Init();
                    // display_home_time_img_last(rtc_time);
                    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
                    display_home_time_img(rtc_time);
                    ESP_LOGI("home", "EPD_Sleep");
                    EPD_Sleep();
                    sleep_js++;
                    if(sleep_js > Unattended_Time){
                        ESP_LOGI("home", "power off");
                        axp_pwr_off();
                    } 
                }
            }
        }

        if (button == 14) {
            // The next main course item
            home_selection++;
            if (home_selection >= HOME_PAGE_NUM) home_selection = 0;
            Page_Down_home(home_selection, Partial_refresh);
            time_count = 0;
        } else if (button == 0) {
            // The previous main course item
            home_selection--;
            if (home_selection < 0) home_selection = HOME_PAGE_NUM - 1;
            Page_Up_home(home_selection, Partial_refresh);
            time_count = 0;
        } else if (button == 7) {
            // Enter the sub-menu
            if (home_selection == 0) {
                // Enter File browsing
                file_browser_task();
            } else if (home_selection == 1) {
                // clock
                page_clock_show();
            } else if (home_selection == 2) {
                // calendar
                page_calendar_show();
            } else if (home_selection == 3) {
                // alarm
                page_alarm_menu();
            } else if (home_selection == 4) {
                // weather
                page_weather_city_select();
            } else if (home_selection == 5) {
                // network
                page_handle_network_key_event();
            } else if (home_selection == 6) {
                // audio
                page_audio_main();
            } else if (home_selection == 7) {
                page_fiction_file();
            } else {
                ESP_LOGI("home", "entry page: %s", home_page[home_selection]);
                // Other pages can be expanded here
            }
            vTaskDelay(pdMS_TO_TICKS(50)); 
            esp_home(home_selection, Partial_refresh);
            time_count = 0;
        } else if (button == 12) {
            ESP_LOGI("home", "Global_refresh");
            EPD_Init();
            esp_home(home_selection, Global_refresh);
            time_count = 0;
        }  else if (button == 22) {
            ESP_LOGI("home", "power off");
            axp_pwr_off();
        } else if (button == 23) {
            ESP_LOGI("home", "settings");
            page_settings_show();
            esp_home(home_selection, Partial_refresh);
        }

        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        // Refresh the time and battery level once every minute
        if(rtc_time.minutes != last_minutes) {
            last_minutes = rtc_time.minutes;
            display_home_time_img(rtc_time);
        }
    }
}


// Add threads that work in modes such as clock, weather, and calendar
static void clock_mode_task(void *arg)
{
    page_clock_show_mode();
    vTaskDelete(NULL);
}
static void calendar_mode_task(void *arg)
{
    page_calendar_show_mode();
    vTaskDelete(NULL);
}
static void weather_mode_task(void *arg)
{
    weather_city_select_mode();
    vTaskDelete(NULL);
}

extern "C" void app_main(void)
{
    ESP_ERROR_CHECK(nvs_flash_init());
    ESP_LOGE("EVEN","Hello world!\n");

    // Initialize the SD card
    _sdcard_init();
    i2c_master_init();   // Initialize the I2C bus
    vTaskDelay(pdMS_TO_TICKS(50)); 
    i2c_devices_init();  // Initialize all I2C devices
    vTaskDelay(pdMS_TO_TICKS(50));

    spiffs_init();

    // Initialize the RTC
    PCF85063_init();
    // PCF85063_alarm_Time_Disable();
    // PCF85063_clear_alarm_flag();

    // Initialize the power supply and perform mode judgment simultaneously
    axp_init();
    char mode = load_mode_enable_from_nvs();
    if(RTC_INT && mode!=0)
    {
        // Determine whether the time is up or if the USB power supply is connected
        if(get_usb_connected()){
            vTaskDelay(pdMS_TO_TICKS(100));
            if((!PWR_OUT))
            {
                ESP_LOGE(TAG,"USB connection, but the device is shut down when the mode is not set to 0");
                axp_pwr_off();
            } else {
                ESP_LOGE(TAG,"Others, continue the process");
            }
        }
        // Set the mode to 0
        ESP_LOGE(TAG,"Set the mode to 0");
        save_mode_enable_to_nvs(0);
        mode = 0;
    }

    // The program officially begins to execute
    // ESP_LOGE(TAG,"Hello world!\n");
    // Initialize key
    button_Init();

    // Initialize the temperature and humidity sensor
    i2c_shtc3_init();  

    // Initialize the audio
    page_audio_int();

    // E-ink screen pin initialization
    epaper_port_init();
    // EPD_display_BMP(NULL);
    // vTaskDelay(pdMS_TO_TICKS(500));

    // EPD_Init
    EPD_Init();
    // Create a data cache area for the e-paper
    if((Image_Mono = (UBYTE *)heap_caps_malloc(EPD_SIZE_MONO,MALLOC_CAP_SPIRAM)) == NULL) 
    {
        ESP_LOGE(TAG,"Failed to apply for black memory...");
        // return ESP_FAIL;
    }

    // Confirm the current mode
    ESP_LOGE(TAG,"mode = %d",mode);

    // Clear the alarm clock
    PCF85063_clear_alarm_flag();
    
    if(mode == 1) {
        // clock
        xTaskCreate(clock_mode_task, "clock_mode", 12 * 1024, NULL, USER_TASK_PRIO, NULL);
    } else if(mode == 2) {
        // calendar
        xTaskCreate(calendar_mode_task, "calendar_mode", 12 * 1024, NULL, USER_TASK_PRIO, NULL);
    } else if(mode == 3) {
        // weather
        xTaskCreate(weather_mode_task, "weather_mode", 12 * 1024, NULL, USER_TASK_PRIO, NULL);
    } else {
        // Clear the alarm clock
        PCF85063_alarm_Time_Disable();
        PCF85063_clear_alarm_flag();

        // Initialize the six-axis sensor
        QMI8658_init();

        Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
        Paint_SetScale(2);
        Paint_SelectImage(Image_Mono);
        Paint_Clear(WHITE);

        // Read the NVS to determine whether the WiFi is enabled
        wifi_enable = load_wifi_enable_from_nvs();
        if (wifi_enable)
        {
            ESP_LOGI("network", "WiFi is enabled and the connection to WiFi begins");
            EPD_Clear();
            vTaskDelay(pdMS_TO_TICKS(500));
            page_network_init_main();
        }
        else 
        {
            ESP_LOGI("network", "Turn off WiFi");
            // Turn off WiFi
            ESP_ERROR_CHECK(safe_wifi_stop());
            ESP_ERROR_CHECK(safe_wifi_deinit());
        }

        // Initialize the mutex lock
        alarm_mutex = xSemaphoreCreateMutex();
        rtc_mutex = xSemaphoreCreateMutex();
        qmi8658_mutex = xSemaphoreCreateMutex();

        // Check whether the creation was successful
        assert(alarm_mutex != NULL);
        assert(rtc_mutex != NULL);

        // Create the main menu task
        xTaskCreate(user_Task, "user_Task", 64 * 1024, NULL, USER_TASK_PRIO, NULL);
        // Create an alarm clock background monitoring task
        xTaskCreate(alarm_task, "alarm_task", 4 * 1024, NULL, ALARM_TASK_PRIO, NULL);

        ESP_LOGE("EVEN","Restarting now.\n");
    }
    while (1) {
        vTaskDelay(portMAX_DELAY);
    }

    heap_caps_free(Image_Mono);
    fflush(stdout);
    // esp_restart();
}
