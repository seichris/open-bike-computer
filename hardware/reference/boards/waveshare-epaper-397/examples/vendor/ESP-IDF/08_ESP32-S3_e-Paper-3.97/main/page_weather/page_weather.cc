#include "page_weather.h"
#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"
#include <stdio.h>
#include <string.h>
#include "button_bsp.h"
#include "esp_http_client.h"
#include "cJSON.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"

#include "esp_netif.h"

#include "epaper_port.h"
#include "GUI_BMPfile.h"
#include "GUI_Paint.h"
#include "pcf85063_bsp.h"
#include "axp_prot.h"

#include "sdcard_bsp.h"

#include "page_network.h"
#include "page_clock.h"
#include "page_alarm.h"
#include "page_audio.h"

#include "esp_spiffs.h"

extern uint8_t *Image_Mono;
extern SemaphoreHandle_t rtc_mutex; 
extern Alarm alarms[MAX_ALARMS];



#define CITY_FILE       "/sdcard/city_code.txt"
#define CITY_FILE_FFS   "/spiffs/city_code.txt"  // The file path in SPIFFS

#define MAX_PROVINCE 40
#define MAX_CITY     100
#define MAX_NAME_LEN 16

// Equipment shutdown time (minutes)
#define Unattended_Time  10



#define WEATHER_JSON_MAX_SIZE (16 * 1024)
// Currently, weather acquisition is only supported for the Chinese mainland region
// PS: The free weather API of this website updates data at fixed times and is only targeted at cities. If you need to obtain it more quickly, please contact the website developer directly for paid access
// https://www.sojson.com/blog/305.html
// The weather update time is at 3 a.m.,8 a.m.,1 p.m., and 7 p.m. every day. Therefore, it is recommended not to obtain it in the early hours of the morning. Additionally, the CDN has a one-hour cache. It is suggested to obtain it after 4 a.m.,9 a.m.,2 p.m., and 8 p.m
#define WEATHER_URL_PREFIX "http://t.weather.sojson.com/api/weather/city/"

// Automatically determine the address of the current network. For the WiFi connected to the ESP32, only the address of the currently connected router will be obtained
// https://www.sojson.com/api/ip.html
#define AMAP_IP_URL "http://restapi.amap.com/v3/ip?key=0113a13c88697dcea6a445584d535837"
#define AMAP_JSON_MAX_SIZE (4 * 1024)


static void display_weather_init(void);
static void display_weather_GUI(void);
static void Forced_refresh_weather(void);
static void Refresh_page_weather(void);
static void display_weather_time(Time_data rtc_time);
static char* getSdCardImageDirectory(const char* weather_desc);
static void Relay_page_weather();

static char province_list[MAX_PROVINCE][MAX_NAME_LEN];
static int province_count = 0;
static char city_list[MAX_CITY][MAX_NAME_LEN];
static int city_count = 0;

static int64_t last_weather_time = 0; // us
static char last_weather_city_code[16] = {0};
static char last_weather_json[WEATHER_JSON_MAX_SIZE] = {0};

static bool force_refresh = true;
static char prov_buf[MAX_NAME_LEN], city_buf[MAX_NAME_LEN];


// ========== SPIFFS initialization function (called once when the program starts) ==========
esp_err_t spiffs_init(void) {
    esp_vfs_spiffs_conf_t conf = {
      .base_path = "/spiffs",
      .partition_label = NULL,
      .max_files = 5,
      .format_if_mount_failed = true
    };

    esp_err_t ret = esp_vfs_spiffs_register(&conf);
    if (ret != ESP_OK) {
        if (ret == ESP_FAIL) {
            printf("SPIFFS Mounting failed. Try formatting...\n");
        } else if (ret == ESP_ERR_NOT_FOUND) {
            printf("SPIFFS The partition was not found.\n");
        } else {
            printf("SPIFFS fail to register: %s\n", esp_err_to_name(ret));
        }
        return ret;
    }

    size_t total = 0, used = 0;
    ret = esp_spiffs_info(NULL, &total, &used);
    if (ret != ESP_OK) {
        printf("Failed to obtain SPIFFS information: %s\n", esp_err_to_name(ret));
    } else {
        printf("SPIFFS mounted - Total size: %d KB used: %d KB\n", total / 1024, used / 1024);
    }
    return ESP_OK;
}



// Read all provinces
static void load_province_list(const char* filename) {
    province_count = 0;
    FILE* f = fopen(filename, "r");
    if (!f) return;
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        char province[MAX_NAME_LEN], city[MAX_NAME_LEN], code[16];
        if (sscanf(line, "%15[^,],%15[^,],%15s", province, city, code) == 3) {
            int found = 0;
            for (int i = 0; i < province_count; ++i) {
                if (strcmp(province_list[i], province) == 0) {
                    found = 1; break;
                }
            }
            if (!found && province_count < MAX_PROVINCE) {
                strncpy(province_list[province_count++], province, MAX_NAME_LEN);
            }
        }
    }
    fclose(f);
}

// Read all cities in the specified province
static void load_city_list(const char* filename, const char* province) {
    city_count = 0;
    FILE* f = fopen(filename, "r");
    if (!f) return;
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        char prov[MAX_NAME_LEN], city[MAX_NAME_LEN], code[16];
        if (sscanf(line, "%15[^,],%15[^,],%15s", prov, city, code) == 3) {
            if (strcmp(prov, province) == 0) {
                int found = 0;
                for (int i = 0; i < city_count; ++i) {
                    if (strcmp(city_list[i], city) == 0) {
                        found = 1; break;
                    }
                }
                if (!found && city_count < MAX_CITY) {
                    strncpy(city_list[city_count++], city, MAX_NAME_LEN);
                }
            }
        }
    }
    fclose(f);
}

// Obtain the corresponding codes of the provinces and cities
static int get_city_code(const char* filename, const char* province, const char* city, char* out_code) {
    FILE* f = fopen(filename, "r");
    if (!f) return 0;
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        char prov[MAX_NAME_LEN], cty[MAX_NAME_LEN], code[16];
        if (sscanf(line, "%15[^,],%15[^,],%15s", prov, cty, code) == 3) {
            if (strcmp(prov, province) == 0 && strcmp(cty, city) == 0) {
                strncpy(out_code, code, 16);
                fclose(f);
                return 1;
            }
        }
    }
    fclose(f);
    return 0;
}

// Save the city code to NVS
void save_city_code_to_nvs(const char* code) {
    nvs_handle_t nvs_handle;
    ESP_ERROR_CHECK(nvs_open("weather", NVS_READWRITE, &nvs_handle));
    ESP_ERROR_CHECK(nvs_set_str(nvs_handle, "city_code", code));
    ESP_ERROR_CHECK(nvs_commit(nvs_handle));
    nvs_close(nvs_handle);
}

// Read the city code
int load_city_code_from_nvs(char* out_code, size_t max_len) {
    nvs_handle_t nvs_handle;
    size_t len = max_len;
    if (nvs_open("weather", NVS_READONLY, &nvs_handle) == ESP_OK) {
        esp_err_t err = nvs_get_str(nvs_handle, "city_code", out_code, &len);
        nvs_close(nvs_handle);
        return err == ESP_OK;
    }
    return 0;
}

// The HTTP response callback writes data to the PSRAM buffer
static esp_err_t http_event_handler(esp_http_client_event_t *evt)
{
    static size_t total_len = 0;
    static char *buffer = NULL;
    switch(evt->event_id) {
        case HTTP_EVENT_ON_CONNECTED:
            total_len = 0;
            buffer = (char *)evt->user_data;
            break;
        case HTTP_EVENT_ON_DATA:
            if (!buffer) return ESP_FAIL;
            if (evt->data_len + total_len < WEATHER_JSON_MAX_SIZE) {
                memcpy(buffer + total_len, evt->data, evt->data_len);
                total_len += evt->data_len;
                buffer[total_len] = '\0';
            }
            break;
        case HTTP_EVENT_ON_FINISH:
            buffer = NULL;
            break;
        default:
            break;
    }
    return ESP_OK;
}


// Obtain and analyze the weather
void weather_fetch_and_show_cached(const char* city_code, bool force_refresh)
{
    int64_t now = esp_timer_get_time(); // us
    bool need_refresh = force_refresh;

    if (!force_refresh &&
        strcmp(city_code, last_weather_city_code) == 0 &&
        last_weather_time > 0 &&
        (now - last_weather_time) < 60 * 60 * 1000000LL && // One hour
        last_weather_json[0] != '\0')
    {
        ESP_LOGI("weather", "Use cached weather data");
        cJSON *root = cJSON_Parse(last_weather_json);
        cJSON_Delete(root);
        return; 
    }

    // Re-obtain the weather
    char url[128];
    snprintf(url, sizeof(url), WEATHER_URL_PREFIX "%s", city_code);

    char *json_buf = (char *)heap_caps_malloc(WEATHER_JSON_MAX_SIZE, MALLOC_CAP_SPIRAM);
    if (!json_buf) {
        ESP_LOGE("weather", "PSRAM allocation failed");
        return;
    }
    json_buf[0] = '\0';

    esp_http_client_config_t config = {
        .url = url,
        .event_handler = http_event_handler,
        .user_data = json_buf,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);

    esp_err_t err = esp_http_client_perform(client);
    esp_http_client_cleanup(client);

    if (err != ESP_OK) {
        ESP_LOGE("weather", "HTTP request failed: %s", esp_err_to_name(err));
        heap_caps_free(json_buf);
        return;
    }

    // Cache data
    strncpy(last_weather_city_code, city_code, sizeof(last_weather_city_code));
    strncpy(last_weather_json, json_buf, WEATHER_JSON_MAX_SIZE - 1);
    last_weather_time = now;

    cJSON *root = cJSON_Parse(json_buf);
    heap_caps_free(json_buf);
    if (!root) {
        ESP_LOGE("weather", "JSON parsing failed");
        return;
    }

    cJSON *cityInfo = cJSON_GetObjectItem(root, "cityInfo");
    cJSON *data = cJSON_GetObjectItem(root, "data");
    if (!cityInfo || !data) {
        ESP_LOGE("weather", "The JSON field is missing, the original response: %s", json_buf);
        cJSON_Delete(root);
        return;
    }
    cJSON *forecast = cJSON_GetObjectItem(data, "forecast");
    
    int year,month,days;
    const char *str = cJSON_GetObjectItem(root, "time") ? cJSON_GetObjectItem(root, "time")->valuestring : "";
    ESP_LOGI("weather", "today's date: %s",str);
    sscanf(str,"%d-%d-%d%*[^- ]",&year,&month,&days);
    ESP_LOGI("weather", "today's date: %04d-%02d-%02d",year,month,days);

    const char *city = cJSON_GetObjectItem(cityInfo, "city") ? cJSON_GetObjectItem(cityInfo, "city")->valuestring : "";
    const char *parent = cJSON_GetObjectItem(cityInfo, "parent") ? cJSON_GetObjectItem(cityInfo, "parent")->valuestring : "";
    const char *wendu = cJSON_GetObjectItem(data, "wendu") ? cJSON_GetObjectItem(data, "wendu")->valuestring : "";
    const char *quality = cJSON_GetObjectItem(data, "quality") ? cJSON_GetObjectItem(data, "quality")->valuestring : "";
    const char *shidu = cJSON_GetObjectItem(data, "shidu") ? cJSON_GetObjectItem(data, "shidu")->valuestring : "";

    ESP_LOGI("weather", "City: %s-%s Current temperature: %s°C Current Humidity: %s Air Quality: %s", parent, city, wendu, shidu, quality);
    char city_str[50];
    snprintf(city_str, sizeof(city_str), "%s-%s", prov_buf, city_buf);
    Paint_DrawRectangle(0, 172, 400, 222, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_GPS,10,181,32,32);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_GPS_PATH,10,181);
#endif
    Paint_DrawString_CN(52, 182, city_str, &Font16_UTF8, BLACK, WHITE);

    char wendu_str[50];
    snprintf(wendu_str, sizeof(wendu_str), "%s℃", wendu);
    Paint_DrawString_CN(469, 34, wendu_str, &Font18_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(663, 34, shidu, &Font18_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(663, 94, quality, &Font18_UTF8, WHITE, BLACK);

    // Read future weather
    char month_str[10];
    char day_str[10];
    int wendu_high;
    int wendu_low;
    int forecast_size = forecast ? cJSON_GetArraySize(forecast) : 0;
    for (int i = 0; i < 4; ++i) {
        cJSON *day = cJSON_GetArrayItem(forecast, i);
        const char *date = cJSON_GetObjectItem(day, "ymd") ? cJSON_GetObjectItem(day, "ymd")->valuestring : "";
        if (date && date[0] != '\0') {    
            sscanf(date, "%*[^-]-%d-%d", &month, &days);
            snprintf(month_str, sizeof(month_str), "%d", month);
            snprintf(day_str, sizeof(day_str), "%d", days);
        }
        const char *type = cJSON_GetObjectItem(day, "type") ? cJSON_GetObjectItem(day, "type")->valuestring : "";
        const char *high = cJSON_GetObjectItem(day, "high") ? cJSON_GetObjectItem(day, "high")->valuestring : "";
        if (high && high[0] != '\0') {    
            sscanf(high, "高温 %d℃", &wendu_high);
            ESP_LOGI("weather", "wendu_high = %d ",wendu_high);
        }
        const char *low = cJSON_GetObjectItem(day, "low") ? cJSON_GetObjectItem(day, "low")->valuestring : "";
        if (low && low[0] != '\0') {    
            sscanf(low, "低温 %d℃", &wendu_low);
            ESP_LOGI("weather", "wendu_low = %d ",wendu_low);
        }
        const char *fx = cJSON_GetObjectItem(day, "fx") ? cJSON_GetObjectItem(day, "fx")->valuestring : "";
        const char *fl = cJSON_GetObjectItem(day, "fl") ? cJSON_GetObjectItem(day, "fl")->valuestring : "";
        const char *sunset = cJSON_GetObjectItem(day, "sunset") ? cJSON_GetObjectItem(day, "sunset")->valuestring : "";
        
        const char *sunrise = cJSON_GetObjectItem(day, "sunrise") ? cJSON_GetObjectItem(day, "sunrise")->valuestring : "";
        char aqi_str[16] = {0};
        cJSON *aqi_item = cJSON_GetObjectItem(day, "aqi");
        if (cJSON_IsNumber(aqi_item)) {
            snprintf(aqi_str, sizeof(aqi_str), "%d", aqi_item->valueint);
        } else if (cJSON_IsString(aqi_item)) {
            strncpy(aqi_str, aqi_item->valuestring, sizeof(aqi_str) - 1);
        } else {
            strcpy(aqi_str, "-");
        }
        ESP_LOGI("weather", "%s %s %s %s", date, type, high, low);
        ESP_LOGI("weather", "date: %s-%s",month_str,day_str);
        ESP_LOGI("weather", "%s %s %s %s %s", fx, fl, sunset, sunrise, aqi_str);

        char weather_str[50];
        uint16_t x_or = 0;
        char *weather_img;
        if(i == 0){
            ESP_LOGI("weather", "i = %d ",i);
            snprintf(weather_str, sizeof(weather_str), "%s %s", fx, fl);
            Paint_DrawString_CN(469, 94, weather_str, &Font18_UTF8, WHITE, BLACK);
            Paint_DrawString_CN(469, 154, sunrise, &Font18_UTF8, WHITE, BLACK);
            Paint_DrawString_CN(663, 154, sunset, &Font18_UTF8, WHITE, BLACK);

            snprintf(weather_str, sizeof(weather_str), "%s月%s日", month_str, day_str);
            x_or = reassignCoordinates_CH(100, weather_str, &Font18_UTF8);
            Paint_DrawString_CN(x_or, 251, weather_str, &Font18_UTF8, WHITE, BLACK);

            // Read data from the TF card to conveniently add weather that is not available
            weather_img = getSdCardImageDirectory(type);
            if(weather_img == NULL){
                // ESP_LOGI("GUI_ReadBmp", "The TF card is not loaded/The corresponding image was not found");
            } else {
                GUI_ReadBmp(weather_img,46,286);
            }

            x_or = reassignCoordinates_CH(100, type, &Font18_UTF8);
            Paint_DrawString_CN(x_or, 400, type, &Font18_UTF8, WHITE, BLACK);

            snprintf(weather_str, sizeof(weather_str), "%d~%d℃", wendu_high, wendu_low);
            x_or = reassignCoordinates_CH(100, weather_str, &Font18_UTF8);
            Paint_DrawString_CN(x_or, 440, weather_str, &Font18_UTF8, WHITE, BLACK);
        } else if(i < 4 ){
            ESP_LOGI("weather", "i = %d ",i);

            snprintf(weather_str, sizeof(weather_str), "%s月%s日", month_str, day_str);
            x_or = reassignCoordinates_CH(100+i*200, weather_str, &Font18_UTF8);
            Paint_DrawString_CN(x_or, 251, weather_str, &Font18_UTF8, WHITE, BLACK);
            
            // Read data from the TF card to conveniently add weather that is not available
            weather_img = getSdCardImageDirectory(type);
            if(weather_img == NULL){
                // ESP_LOGI("GUI_ReadBmp", "The TF card is not loaded/The corresponding image was not found");
            } else {
                GUI_ReadBmp(weather_img,46+i*200,286);
            }

            x_or = reassignCoordinates_CH(100+i*200, type, &Font18_UTF8);
            Paint_DrawString_CN(x_or, 400, type, &Font18_UTF8, WHITE, BLACK);

            snprintf(weather_str, sizeof(weather_str), "%d~%d℃", wendu_high, wendu_low);
            x_or = reassignCoordinates_CH(100+i*200, weather_str, &Font18_UTF8);
            Paint_DrawString_CN(x_or, 440, weather_str, &Font18_UTF8, WHITE, BLACK);
        }
    }
    Forced_refresh_weather();
    cJSON_Delete(root);
}

// Look up the sojson city code based on adcode
int get_sojson_code_by_adcode(const char* adcode, char* sojson_code, size_t max_len) {
    FILE* f = fopen(CITY_FILE, "r");
    if (!f) {
        f = fopen(CITY_FILE_FFS, "r");
        if (!f) return 0;
    } 
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        char prov[MAX_NAME_LEN], city[MAX_NAME_LEN], file_adcode[16], file_sojson[16];
        if (sscanf(line, "%15[^,],%15[^,],%15[^,],%15s", prov, city, file_adcode, file_sojson) == 4) {
            if (strcmp(file_adcode, adcode) == 0) {
                strncpy(sojson_code, file_sojson, max_len - 1);
                sojson_code[max_len - 1] = '\0';
                fclose(f);
                return 1;
            }
        }
    }
    fclose(f);
    return 0;
}

// The search function searches the "province" and "city" fields returned by the Autonavi API
int get_sojson_code_by_name(const char* province, const char* city, char* sojson_code, size_t max_len) {
    FILE* f = fopen(CITY_FILE, "r");
    if (!f) {
        f = fopen(CITY_FILE_FFS, "r");
        if (!f) return 0;
    }
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        char file_prov[MAX_NAME_LEN], file_city[MAX_NAME_LEN], file_code[16];
        if (sscanf(line, "%15[^,],%15[^,],%15s", file_prov, file_city, file_code) == 3) {
            if (strcmp(file_prov, province) == 0 && strcmp(file_city, city) == 0) {
                strncpy(sojson_code, file_code, max_len - 1);
                sojson_code[max_len - 1] = '\0';
                fclose(f);
                return 1;
            }
        }
    }
    fclose(f);
    return 0;
}

// Remove the words "province", "city", "district", "county", "league", "autonomous prefecture" and "special administrative region" at the end
void trim_suffix(char *str) {
    size_t len = strlen(str);
    if (len >= 12 && strcmp(str + len - 12, "特别行政区") == 0) {
        str[len - 12] = '\0';
    } else if (len >= 9 && strcmp(str + len - 9, "自治州") == 0) {
        str[len - 9] = '\0';
    } else if (len >= 9 && strcmp(str + len - 9, "自治区") == 0) {
        str[len - 9] = '\0';
    } else if (len >= 3) {
        const char *suffixes[] = {"省", "市", "区", "县", "盟"};
        for (int i = 0; i < sizeof(suffixes)/sizeof(suffixes[0]); ++i) {
            size_t suf_len = strlen(suffixes[i]);
            if (len >= suf_len && strcmp(str + len - suf_len, suffixes[i]) == 0) {
                str[len - suf_len] = '\0';
                break;
            }
        }
    }
}

// Automatically match the city's code
int amap_ip_location_fetch_city_code_by_name(char *sojson_code, size_t code_len)
{
    char *json_buf = (char *)heap_caps_malloc(AMAP_JSON_MAX_SIZE, MALLOC_CAP_SPIRAM);
    if (!json_buf) return 0;
    json_buf[0] = '\0';

    esp_http_client_config_t config = {0};
    config.url = AMAP_IP_URL;
    esp_http_client_handle_t client = esp_http_client_init(&config);

    esp_err_t err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        esp_http_client_cleanup(client);
        heap_caps_free(json_buf);
        return 0;
    }

    esp_http_client_fetch_headers(client);
    int read_len = esp_http_client_read(client, json_buf, AMAP_JSON_MAX_SIZE - 1);
    esp_http_client_close(client);
    esp_http_client_cleanup(client);

    if (read_len <= 0) {
        heap_caps_free(json_buf);
        return 0;
    }
    json_buf[read_len] = '\0';

    cJSON *root = cJSON_Parse(json_buf);
    heap_caps_free(json_buf);
    if (!root) return 0;

    cJSON *province = cJSON_GetObjectItem(root, "province");
    cJSON *city = cJSON_GetObjectItem(root, "city");
    int ret = 0;
    if (province && city && cJSON_IsString(province) && cJSON_IsString(city)) {
        strncpy(prov_buf, province->valuestring, MAX_NAME_LEN - 1);
        prov_buf[MAX_NAME_LEN - 1] = '\0';
        strncpy(city_buf, city->valuestring, MAX_NAME_LEN - 1);
        city_buf[MAX_NAME_LEN - 1] = '\0';
        trim_suffix(prov_buf);
        trim_suffix(city_buf);
        ret = get_sojson_code_by_name(prov_buf, city_buf, sojson_code, code_len);
    }
    cJSON_Delete(root);
    return ret;
}

// Automatically locate and obtain the city
int amap_ip_location_fetch_city_code(char *city_code, size_t code_len)
{
    char *json_buf = (char *)heap_caps_malloc(AMAP_JSON_MAX_SIZE, MALLOC_CAP_SPIRAM);
    if (!json_buf) {
        ESP_LOGE("amap", "PSRAM allocation failed");
        return 0;
    }
    json_buf[0] = '\0';

    esp_http_client_config_t config = {0};
    config.url = AMAP_IP_URL;
    esp_http_client_handle_t client = esp_http_client_init(&config);

    esp_err_t err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        ESP_LOGE("amap", "Failed to open HTTP: %s (%d)", esp_err_to_name(err), err);
        esp_http_client_cleanup(client);
        heap_caps_free(json_buf);
        return 0;
    }

    int content_length = esp_http_client_fetch_headers(client);
    ESP_LOGI("amap", "HTTP content length: %d", content_length);

    int read_len = esp_http_client_read(client, json_buf, AMAP_JSON_MAX_SIZE - 1);
    if (read_len > 0 && read_len < AMAP_JSON_MAX_SIZE) {
        json_buf[read_len] = '\0';
        ESP_LOGI("amap", "Automatically locate the response content: %s", json_buf);
    } else {
        ESP_LOGE("amap", "Abnormal content length, read_len=%d", read_len);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        heap_caps_free(json_buf);
        return 0;
    }

    esp_http_client_close(client);
    esp_http_client_cleanup(client);

    cJSON *root = cJSON_Parse(json_buf);
    heap_caps_free(json_buf);
    if (!root) {
        ESP_LOGE("amap", "JSON parsing failed");
        return 0;
    }

    cJSON *adcode = cJSON_GetObjectItem(root, "adcode");
    int ret = 0;
    if (adcode && cJSON_IsString(adcode)) {
        strncpy(city_code, adcode->valuestring, code_len - 1);
        city_code[code_len - 1] = '\0';
        ret = 1;
    } else {
        ESP_LOGE("amap", "The adcode field was not obtained. The original response: %s", json_buf);
    }
    cJSON_Delete(root);
    return ret;
}

// Wake-up time setting
void Wake_up_time_setting_weather(Time_data rtc_time)
{
    int Weather_update_time;
    if(rtc_time.hours < 4){
        Weather_update_time = 4;
    } else if(rtc_time.hours < 9){
        Weather_update_time = 9;
    } else if(rtc_time.hours < 14){
        Weather_update_time = 14;
    } else if(rtc_time.hours < 20){
        Weather_update_time = 20;
    } else {
        Weather_update_time = 4;
    }

    for (size_t i = 0; i < MAX_ALARMS; i++)
    {
        if (alarms[i].enabled){
            if(rtc_time.hours >= 20){
                if(alarms[i].hour > rtc_time.hours){
                    Time_data alarm_time = rtc_time;
                    alarm_time.hours = alarms[i].hour;
                    alarm_time.minutes = alarms[i].minute;
                    PCF85063_alarm_Time_Enabled(alarm_time);
                } else if((alarms[i].hour == rtc_time.hours) && (alarms[i].minute > rtc_time.minutes)){
                    Time_data alarm_time = rtc_time;
                    alarm_time.hours = alarms[i].hour;
                    alarm_time.minutes = alarms[i].minute;
                    PCF85063_alarm_Time_Enabled(alarm_time);
                } else {
                    if(alarms[i].hour > 4) {
                        Time_data alarm_time = rtc_time;
                        alarm_time.days += 1;
                        alarm_time.hours = 4;
                        alarm_time.minutes = 0;
                        PCF85063_alarm_Time_Enabled(alarm_time);
                    } else {
                        Time_data alarm_time = rtc_time;
                        alarm_time.days += 1;
                        alarm_time.hours = alarms[i].hour;
                        alarm_time.minutes = alarms[i].minute;
                        PCF85063_alarm_Time_Enabled(alarm_time);
                    }
                }
                break;
            } else {
                if(alarms[i].hour > rtc_time.hours){
                    if(alarms[i].hour > Weather_update_time) {
                        Time_data alarm_time = rtc_time;
                        alarm_time.hours = Weather_update_time;
                        alarm_time.minutes = 0;
                        PCF85063_alarm_Time_Enabled(alarm_time);
                    } else {
                        Time_data alarm_time = rtc_time;
                        alarm_time.hours = alarms[i].hour;
                        alarm_time.minutes = alarms[i].minute;
                        PCF85063_alarm_Time_Enabled(alarm_time);
                    }
                    break;
                } else if((alarms[i].hour == rtc_time.hours) && (alarms[i].minute > rtc_time.minutes)){
                    Time_data alarm_time = rtc_time;
                    alarm_time.hours = alarms[i].hour;
                    alarm_time.minutes = alarms[i].minute;
                    PCF85063_alarm_Time_Enabled(alarm_time);
                    break;
                } else {
                    if(rtc_time.hours >= 20){
                        Time_data alarm_time = rtc_time;
                        alarm_time.days += 1;
                        alarm_time.hours = 4;
                        alarm_time.minutes = 0;
                        PCF85063_alarm_Time_Enabled(alarm_time);
                    } else {
                        Time_data alarm_time = rtc_time;
                        alarm_time.hours = Weather_update_time;
                        alarm_time.minutes = 0;
                        PCF85063_alarm_Time_Enabled(alarm_time);
                    }
                }
            }
        } else {
            if(rtc_time.hours >= 20){
                Time_data alarm_time = rtc_time;
                alarm_time.days += 1;
                alarm_time.hours = 4;
                alarm_time.minutes = 0;
                PCF85063_alarm_Time_Enabled(alarm_time);
            } else {
                Time_data alarm_time = rtc_time;
                alarm_time.hours = Weather_update_time;
                alarm_time.minutes = 0;
                PCF85063_alarm_Time_Enabled(alarm_time);
            }
            
        }
    }
}

// Main entrance, press the button to select automatic/manual
void page_weather_city_select(void)
{
    display_weather_init();
    if (!wifi_is_connected()) {
        ESP_LOGW("weather", "The WiFi is not connected. Please turn on WiFi!");
        ESP_LOGI("weather", "Button_Function/Boot Double-click to return to the main menu");
        Paint_DrawString_CN(10, 25, "WiFi未开启,请先开启WiFi!", &Font24_UTF8, WHITE, BLACK);
        Paint_DrawString_CN(10, 80, "双击 Button_Function/Boot 返回主菜单", &Font24_UTF8, WHITE, BLACK);
        Refresh_page_weather();
        ESP_LOGI("clock", "EPD_Sleep");
        EPD_Sleep();
        while (1) {
            int button = wait_key_event_and_return_code(portMAX_DELAY);
            if (button == 8 || button == 22) {
                // 返回主菜单
                ESP_LOGI("clock", "EPD_Init");
                EPD_Init();
                Refresh_page_weather();
                return;
            }
        }
    }

    esp_netif_ip_info_t ip_info;
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    esp_err_t ip_ret = esp_netif_get_ip_info(netif, &ip_info);
    if (ip_ret != ESP_OK || ip_info.ip.addr == 0) {
        ESP_LOGW("weather", "The IP address for WiFi was not obtained. Please check your network!");
        ESP_LOGI("weather", "Button_Function/Boot Double-click to return to the main menu");
        Paint_DrawString_CN(10, 25, "WiFi未获取到IP地址,请检查网络!", &Font24_UTF8, WHITE, BLACK);
        Paint_DrawString_CN(10, 80, "双击 Button_Function/Boot 返回主菜单", &Font24_UTF8, WHITE, BLACK);
        Refresh_page_weather();
        ESP_LOGI("clock", "EPD_Sleep");
        EPD_Sleep();
        while (1) {
            int button = wait_key_event_and_return_code(portMAX_DELAY);
            if (button == 8 || button == 22) {
                ESP_LOGI("clock", "EPD_Init");
                EPD_Init();
                Refresh_page_weather();
                return;
            }
        }
    }

    int button = -1;
    bool force_refresh = true;
    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    Time_data rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);
    int last_hours = rtc_time.hours;
    int last_minutes = rtc_time.minutes;
    int sleep_js = 0;

    Relay_page_weather();

    ESP_LOGI("clock", "Long press Button_Function: Force a full flash of Button_Function/Boot. Double-click: Return");
    while (1) {
        if (button == 12 || force_refresh) {
            force_refresh = false;
            char adcode[16] = {0};
            if (amap_ip_location_fetch_city_code(adcode, sizeof(adcode))) {
                char sojson_code[16] = {0};
                if (amap_ip_location_fetch_city_code_by_name(sojson_code, sizeof(sojson_code))) {
                    ESP_LOGI("weather", "Automatic Location City Code (sojson): %s", sojson_code);
                    display_weather_GUI();
                    display_weather_time(rtc_time);
                    weather_fetch_and_show_cached(sojson_code, true);
                } else {
                    ESP_LOGW("weather", "City matching failed");
                    Paint_DrawString_CN(10, 25, "城市匹配失败", &Font24_UTF8, WHITE, BLACK);
                    Paint_DrawString_CN(10, 80, "双击 Button_Function/Boot 返回主菜单", &Font24_UTF8, WHITE, BLACK);
                    Paint_DrawString_CN(10, 135, "长按 Button_Function 重试", &Font24_UTF8, WHITE, BLACK);
                    Forced_refresh_weather();
                }
            } else {
                ESP_LOGW("weather", "Automatic positioning failed");
                display_weather_init();
                Paint_DrawString_CN(10, 25, "自动定位失败", &Font24_UTF8, WHITE, BLACK);
                Paint_DrawString_CN(10, 80, "双击 Button_Function/Boot 返回主菜单", &Font24_UTF8, WHITE, BLACK);
                Paint_DrawString_CN(10, 135, "长按 Button_Function 重试", &Font24_UTF8, WHITE, BLACK);
                Forced_refresh_weather();
            }
        } else if(button == 8 || button == 22) {
            ESP_LOGI("clock", "EPD_Init");
            EPD_Init();
            Refresh_page_weather();
            return;
        }

        button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        if((rtc_time.hours != last_hours) && (rtc_time.hours == 4 || rtc_time.hours == 9 || rtc_time.hours == 14 || rtc_time.hours == 20))
        {
            last_hours = rtc_time.hours;
            force_refresh = true;
        }

        if (rtc_time.minutes != last_minutes) {
            last_minutes = rtc_time.minutes;
            sleep_js++;
            if(sleep_js > Unattended_Time){
                ESP_LOGI("home", "pwr_off");
                save_mode_enable_to_nvs(3);
                load_alarms_from_nvs();
                Wake_up_time_setting_weather(rtc_time);
                // Save the current buffer to SD for quick loading (overwriting) next time
                if (!sd_write_buffer_to_file(CLOCK_PARTIAL_PATH, Image_Mono, EPD_SIZE_MONO)) {
                    ESP_LOGW("sdio", "Failed to save the local cache to SD: %s", CLOCK_PARTIAL_PATH);
                }
                vTaskDelay(pdMS_TO_TICKS(50));
                axp_pwr_off();
            } 
        }

    }
}

void weather_city_select_mode()
{
    load_alarms_from_nvs();
    Time_data rtc_time = PCF85063_GetTime();
    Wake_up_time_setting_weather(rtc_time);

    if(!check_alarm(rtc_time.hours, rtc_time.minutes)){
        if(page_network_init_mode())
        {   
            char adcode[16] = {0};
            if (amap_ip_location_fetch_city_code(adcode, sizeof(adcode))) {
                char sojson_code[16] = {0};
                if (amap_ip_location_fetch_city_code_by_name(sojson_code, sizeof(sojson_code))) {
                    ESP_LOGI("weather", "Automatic Location City Code (sojson): %s", sojson_code);
                    display_weather_GUI();
                    display_weather_time(rtc_time);
                    weather_fetch_and_show_cached(sojson_code, true);
                } else {
                    ESP_LOGW("weather", "City matching failed");
                    if (!sd_read_file_to_buffer(CLOCK_PARTIAL_PATH, Image_Mono, EPD_SIZE_MONO)) {
                        ESP_LOGI("sdio", "The local cache file is not loaded and is displayed using the current buffer");
                    }
                    Paint_DrawString_CN(10, 137, "无匹配城市，更新失败", &Font16_UTF8, WHITE, BLACK);
                    Forced_refresh_weather();
                }
            } else {
                ESP_LOGW("weather", "Automatic positioning failed");
                if (!sd_read_file_to_buffer(CLOCK_PARTIAL_PATH, Image_Mono, EPD_SIZE_MONO)) {
                    ESP_LOGI("sdio", "The local cache file is not loaded and is displayed using the current buffer");
                }
                Paint_DrawString_CN(10, 137, "定位失败，更新失败", &Font16_UTF8, WHITE, BLACK);
                Forced_refresh_weather();
            }
            // standard time
            page_clock_init();
        }
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



// Automatically determine the address of the current network
void amap_ip_location_fetch(void)
{
    char *json_buf = (char *)heap_caps_malloc(AMAP_JSON_MAX_SIZE, MALLOC_CAP_SPIRAM);
    if (!json_buf) {
        ESP_LOGE("amap", "PSRAM allocation failed");
        return;
    }
    json_buf[0] = '\0';

    esp_http_client_config_t config = {0};
    config.url = AMAP_IP_URL;

    esp_http_client_handle_t client = esp_http_client_init(&config);
    esp_err_t err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        ESP_LOGE("amap", "Failed to open HTTP: %s", esp_err_to_name(err));
        esp_http_client_cleanup(client);
        heap_caps_free(json_buf);
        return;
    }

    int content_length = esp_http_client_fetch_headers(client);
    ESP_LOGI("amap", "HTTP content length: %d", content_length);

    int read_len = esp_http_client_read(client, json_buf, AMAP_JSON_MAX_SIZE - 1);
    if (read_len > 0 && read_len < AMAP_JSON_MAX_SIZE) {
        json_buf[read_len] = '\0';
        ESP_LOGI("amap", "Response content: %s", json_buf);
    } else {
        ESP_LOGE("amap", "Abnormal content length, read_len=%d", read_len);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        heap_caps_free(json_buf);
        return;
    }

    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    cJSON *root = cJSON_Parse(json_buf);
    heap_caps_free(json_buf);
    if (!root) {
        ESP_LOGE("amap", "JSON parsing failed");
        return;
    }

    cJSON *item = NULL;
    cJSON_ArrayForEach(item, root) {
        if (cJSON_IsString(item)) {
            ESP_LOGI("amap", "%s: %s", item->string, item->valuestring);
        } else if (cJSON_IsNumber(item)) {
            ESP_LOGI("amap", "%s: %lf", item->string, item->valuedouble);
        } else {
            ESP_LOGI("amap", "%s: (Non-string/numeric type)", item->string);
        }
    }
    cJSON_Delete(root);
}


// Electronic paper refresh
static void display_weather_init(void)
{
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 0, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
}
static void display_weather_GUI(void)
{
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 0, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);

#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_wendu,421,32,36,36);
    Paint_ReadBmp(gImage_shidu,615,32,36,36);
    Paint_ReadBmp(gImage_fx,421,92,36,36);
    Paint_ReadBmp(gImage_quality,615,92,36,36);
    Paint_ReadBmp(gImage_sunrise,421,152,36,36);
    Paint_ReadBmp(gImage_sunset,615,152,36,36);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_WENDU_PATH,421,32);
    GUI_ReadBmp(BMP_SHIDU_PATH,615,32);
    GUI_ReadBmp(BMP_FX_PATH,421,92);
    GUI_ReadBmp(BMP_QUALITY_PATH,615,92);
    GUI_ReadBmp(BMP_SUNRISE_PATH,421,152);
    GUI_ReadBmp(BMP_SUNSET_PATH,615,152);
#endif

    Paint_DrawLine(399, 2, 399, 222, BLACK, DOT_PIXEL_2X2, LINE_STYLE_SOLID);
    Paint_DrawLine(2, 222, EPD_WIDTH-2, 222, BLACK, DOT_PIXEL_2X2, LINE_STYLE_SOLID);
}

static void Forced_refresh_weather(void)
{
    ESP_LOGI("clock", "EPD_Init");
    EPD_Init();
    EPD_Display_Base(Image_Mono);
    ESP_LOGI("clock", "EPD_Sleep");
    EPD_Sleep();
}

static void Refresh_page_weather(void)
{
    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
}

static void display_weather_time(Time_data rtc_time)
{
    char Time_str[50]={0};
    const char* week_str[] = {"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"};

    ESP_LOGI("clock", "current time: %04d-%02d-%02d %02d:%02d:%02d 星期%d", rtc_time.years + 2000, rtc_time.months, rtc_time.days, rtc_time.hours, rtc_time.minutes, rtc_time.seconds, rtc_time.week);

    snprintf(Time_str, sizeof(Time_str), "%04d-%02d-%02d %s", rtc_time.years + 2000, rtc_time.months, rtc_time.days, week_str[rtc_time.week]);
    Paint_DrawString_CN(10, 25, Time_str, &Font24_UTF8, WHITE, BLACK);

    char Lunar_str[50]={0};
    snprintf(Time_str, sizeof(Time_str), "%04d-%02d-%02d", rtc_time.years + 2000, rtc_time.months, rtc_time.days);
    Lunar_calendar_acquisition(Lunar_str, 50, Time_str);
    Paint_DrawString_CN(10, 80, Lunar_str, &Font24_UTF8, WHITE, BLACK);
    
    snprintf(Time_str, sizeof(Time_str), "更新时间: %02d:%02d", rtc_time.hours, rtc_time.minutes);
    Paint_DrawString_CN(10, 137, Time_str, &Font16_UTF8, WHITE, BLACK);
}

// Obtain the corresponding BMP image path based on the weather description
static char* getSdCardImageDirectory(const char* weather_desc)
{
    bool flag = 0;
    static char weather_image_path[128];
    weather_image_path[0] = '\0';
    
    if (!weather_desc) return NULL;
    
    FILE *fp = fopen("/sdcard/Weather_img/Weather_img/Weather.txt", "r");
    if (!fp) {
        fp = fopen("/spiffs/Weather_img/Weather.txt", "r");
        if (!fp){
            ESP_LOGE("WEATHER", "cannot open /sdcard/Weather_img/Weather_img/Weather.txt");
            ESP_LOGE("WEATHER", "/spiffs/Weather_img/Weather.txt");
            return NULL;
        } else {
            flag = 1;
        }
    }
    
    char line[64];
    while (fgets(line, sizeof(line), fp)) {
        char chinese_desc[32], english_name[32];
        if (sscanf(line, "%31[^,],%31s", chinese_desc, english_name) == 2) {
            char *newline = strchr(english_name, '\n');
            if (newline) *newline = '\0';
            
            if (strcmp(chinese_desc, weather_desc) == 0) {
                if(!flag){
                    snprintf(weather_image_path, sizeof(weather_image_path), "/sdcard/Weather_img/Weather_img/%s.bmp", english_name);

                } else {
                    snprintf(weather_image_path, sizeof(weather_image_path), "/spiffs/Weather_img/%s.bmp", english_name);
                }
                ESP_LOGI("WEATHER", "Find weather pictures: %s", weather_image_path);
                fclose(fp);
                return weather_image_path;
            }
        }
    }
    fclose(fp);
    
    /**********If not found, it will return NULL by default. It is not recommended to return other images***********/
    return NULL;

    // // Default image
    // if(!flag){
    //     strcpy(weather_image_path, "/sdcard/Weather_img/Weather_img/qin.bmp");
    // } else {
    //     strcpy(weather_image_path, "/spiffs/Weather_img/qin.bmp");
    // }
    // return weather_image_path;
}

// The data acquisition time on the intermediate page is relatively long. Use this page as a prompt
static void Relay_page_weather()
{
    Paint_Clear(WHITE);
    Paint_DrawString_CN(10, 25, "数据获取中，请稍等", &Font24_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(10, 80, "Data is being obtained. Please wait a moment", &Font24_UTF8, WHITE, BLACK);
    Refresh_page_weather();
}


