#include "page_network.h"
#include "wifi_station.h"
#include "wifi_configuration_ap.h"
#include "ssid_manager.h"
#include "button_bsp.h"
#include "esp_log.h"

#include <nvs.h>
#include <nvs_flash.h>
#include "esp_wifi.h"

#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"

#include "pcf85063_bsp.h"
#include "axp_prot.h"
#include "epaper_port.h"
#include "GUI_BMPfile.h"
#include "GUI_Paint.h"

#include "page_clock.h"

extern bool wifi_enable; 
static EventGroupHandle_t wifi_event_group = nullptr;
static bool page_network_inited = false;

#define WIFI_CONFIG_DONE_BIT BIT0
// E-ink screen sleep time (S)
#define EPD_Sleep_Time   60
// Equipment shutdown time (minutes)
#define Unattended_Time  10

#define BMP_BAT_PATH                        "/sdcard/GUI/BAT.bmp"
#define BMP_WIFI_PATH                       "/sdcard/GUI/WIFI.bmp"

// Define the data cache area of the electronic paper
extern uint8_t *Image_Mono;
extern SemaphoreHandle_t rtc_mutex;   // Protect RTC

static void display_network_init();
static void display_network_option(int option);
static void display_network_time_img(Time_data rtc_time);
static void Forced_refresh_network(void);
static void Refresh_page_network(void);
static int Sleep_wake_network(void);

// Determine whether the WiFi is connected
extern "C" bool wifi_is_connected(void)
{
    wifi_ap_record_t ap_info;
    return esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK;
}

// WiFi off function
esp_err_t safe_wifi_stop()
{
    wifi_mode_t mode;
    esp_err_t err = esp_wifi_get_mode(&mode);
    if (err == ESP_ERR_WIFI_NOT_INIT) {
        // The WiFi is not initialized and there is no need to stop it
        return ESP_OK;
    }
    return esp_wifi_stop();
}

// WiFi resource release function
esp_err_t safe_wifi_deinit()
{
    wifi_mode_t mode;
    esp_err_t err = esp_wifi_get_mode(&mode);
    if (err == ESP_ERR_WIFI_NOT_INIT) {
        // The WiFi is not initialized and does not require deinit
        return ESP_OK;
    }
    return esp_wifi_deinit();
}



// IP acquisition event callback
static void on_got_ip(void* arg, esp_event_base_t event_base, int32_t event_id, void* event_data)
{
    wifi_ap_record_t ap_info;
    if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
        ESP_LOGI("network", "Current WiFi connection information:");
        ESP_LOGI("network", "  SSID: %s", ap_info.ssid);
        ESP_LOGI("network", "  BSSID: %02x:%02x:%02x:%02x:%02x:%02x", ap_info.bssid[0], ap_info.bssid[1], ap_info.bssid[2], ap_info.bssid[3], ap_info.bssid[4], ap_info.bssid[5]);
        ESP_LOGI("network", "  signal strength(RSSI): %d dBm", ap_info.rssi);
        ESP_LOGI("network", "  (information)  channel: %d", ap_info.primary);
        ESP_LOGI("network", "  Encryption type(authmode): %d", ap_info.authmode);

        ip_event_got_ip_t* event = (ip_event_got_ip_t*) event_data;
        ESP_LOGI("network", "The IP address has been obtained:");
        ESP_LOGI("network", "  IP Address: " IPSTR, IP2STR(&event->ip_info.ip));
        ESP_LOGI("network", "  subnet mask: " IPSTR, IP2STR(&event->ip_info.netmask));
        ESP_LOGI("network", "  gateway: " IPSTR, IP2STR(&event->ip_info.gw));
    } else {
        ESP_LOGI("network", "The WiFi is disconnected. Please reconnect to WiFi");
    }
}

// Write the wifi status
void save_wifi_enable_to_nvs(bool enable) {
    nvs_handle_t nvs_handle;
    ESP_ERROR_CHECK(nvs_open("wifi_state", NVS_READWRITE, &nvs_handle));
    ESP_ERROR_CHECK(nvs_set_u8(nvs_handle, "enable", enable ? 1 : 0));
    ESP_ERROR_CHECK(nvs_commit(nvs_handle));
    nvs_close(nvs_handle);
}

// Read the wifi network status
bool load_wifi_enable_from_nvs() {
    nvs_handle_t nvs_handle;
    uint8_t enable = 0; //Off by default
    if (nvs_open("wifi_state", NVS_READONLY, &nvs_handle) == ESP_OK) {
        nvs_get_u8(nvs_handle, "enable", &enable);
        nvs_close(nvs_handle);
    }
    return enable != 0;
}

// Get information about WiFi
void page_network_show(void)
{
    // Display the list of saved Wi-Fi
    auto& ssid_list = SsidManager::GetInstance().GetSsidList();
    if (!ssid_list.empty()) {
        ESP_LOGI("network", "The number of WiFi has been saved: %d", (int)ssid_list.size());
        for (auto& item : ssid_list) {
            ESP_LOGI("network", "SSID: %s", item.ssid.c_str());
        }
    } else {
        ESP_LOGI("network", "There is no saved Wi-Fi at present");
    }

    char wifi_str[50] = {0};

    // Display the detailed information of the current WiFi connection
    wifi_ap_record_t ap_info;
    if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
        ESP_LOGI("network", "  Current WiFi connection information:");
        ESP_LOGI("network", "  SSID: %s", ap_info.ssid);
        ESP_LOGI("network", "  BSSID: %02x:%02x:%02x:%02x:%02x:%02x", ap_info.bssid[0], ap_info.bssid[1], ap_info.bssid[2], ap_info.bssid[3], ap_info.bssid[4], ap_info.bssid[5]);
        ESP_LOGI("network", "  signal strength(RSSI): %d dBm", ap_info.rssi);
        ESP_LOGI("network", "  (information)  channel: %d", ap_info.primary);
        ESP_LOGI("network", "  Encryption type(authmode): %d", ap_info.authmode);
        
        Paint_DrawString_CN(10, 59, "WiFi 信息：", &Font18_UTF8, WHITE, BLACK);
        snprintf(wifi_str, sizeof(wifi_str), "SSID: %s", ap_info.ssid );
        Paint_DrawString_CN(25, 95, wifi_str, &Font18_UTF8, WHITE, BLACK);
        snprintf(wifi_str, sizeof(wifi_str), "BSSID: %02x:%02x:%02x:%02x:%02x:%02x", ap_info.bssid[0], ap_info.bssid[1], ap_info.bssid[2], ap_info.bssid[3], ap_info.bssid[4], ap_info.bssid[5]);
        Paint_DrawString_CN(25, 131, wifi_str, &Font18_UTF8, WHITE, BLACK);
        snprintf(wifi_str, sizeof(wifi_str), "信号强度(RSSI): %d dBm", ap_info.rssi);
        Paint_DrawString_CN(25, 167, wifi_str, &Font18_UTF8, WHITE, BLACK);
        snprintf(wifi_str, sizeof(wifi_str), "信道: %d", ap_info.primary);
        Paint_DrawString_CN(25, 203, wifi_str, &Font18_UTF8, WHITE, BLACK);
        snprintf(wifi_str, sizeof(wifi_str), "加密类型(authmode): %d", ap_info.authmode);
        Paint_DrawString_CN(25, 239, wifi_str, &Font18_UTF8, WHITE, BLACK);


        // Obtain IP information correctly
        esp_netif_ip_info_t ip_info;
        esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
        if (netif && esp_netif_get_ip_info(netif, &ip_info) == ESP_OK) {
            ESP_LOGI("network", "  IP address: " IPSTR, IP2STR(&ip_info.ip));
            ESP_LOGI("network", "  subnet mask: " IPSTR, IP2STR(&ip_info.netmask));
            ESP_LOGI("network", "  gateway: " IPSTR, IP2STR(&ip_info.gw));

            snprintf(wifi_str, sizeof(wifi_str), "IP地址: " IPSTR, IP2STR(&ip_info.ip));
            Paint_DrawString_CN(25, 275, wifi_str, &Font18_UTF8, WHITE, BLACK);
            snprintf(wifi_str, sizeof(wifi_str), "子网掩码: " IPSTR, IP2STR(&ip_info.netmask));
            Paint_DrawString_CN(25, 311, wifi_str, &Font18_UTF8, WHITE, BLACK);
            snprintf(wifi_str, sizeof(wifi_str), "网关: " IPSTR, IP2STR(&ip_info.gw));
            Paint_DrawString_CN(25, 347, wifi_str, &Font18_UTF8, WHITE, BLACK);
        } else {
            Paint_DrawString_CN(25, 275, "IP获取失败", &Font18_UTF8, WHITE, BLACK);
        }
    } else {
        // ESP_LOGI("network", "The Web distribution network mode has been entered. Please connect your mobile phone to the ESP32 hotspot SSID: %s and visit 192.168.4.1", ap.GetSsid().c_str());
    }
}

// Delete the WiFi, restart after 2 seconds, and re-enter the distribution network mode
void page_network_config(void)
{
    SsidManager::GetInstance().Clear();

    Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(10, 59, "以删除WiFi，2秒后重启，并重新进入配网模式", &Font18_UTF8, WHITE, BLACK);
    Refresh_page_network();
    ESP_LOGI("network","Delete the WiFi, restart after 2 seconds, and re-enter the distribution network mode");
    vTaskDelay(pdMS_TO_TICKS(2000));
    esp_restart();
}

// To turn on or off WiFi: enable=true to enable, enable=false to turn off
void wifi_set_enable(bool enable)
{
    save_wifi_enable_to_nvs(enable);
    if (enable) {
        ESP_LOGI("network", "Turn on WiFi and enter the distribution network");
        // ESP_ERROR_CHECK(esp_wifi_start());
        page_network_init();
    } else {
        ESP_LOGI("network", "Turn off WiFi");
        // 先停止 WiFi Station（会调用内部清理）
        WifiStation::GetInstance().Stop();
        ESP_ERROR_CHECK(safe_wifi_stop());
        // ESP_ERROR_CHECK(safe_wifi_deinit());

        // Destroy the default WiFi STA netif to avoid creating it again when it is turned on next time
        esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
        if (netif) {
            ESP_LOGI("network", "Destroy WiFi STA netif");
            esp_netif_destroy_default_wifi(netif);
        }
    }
}

// Destroy WiFi STA netifWiFi configuration initialization
void page_network_init(void)
{
    int button = -1;        // Key status
    EventBits_t event_bits;  // Store the event group and wait for the result
    char wifi_str[150];
    if (!wifi_event_group) {
        wifi_event_group = xEventGroupCreate();
    }

    // // Force clear NVS and experience Web distribution network
    // ESP_ERROR_CHECK(nvs_flash_erase());

    // Initialize NVS
    if (!page_network_inited) {
        esp_err_t err = esp_event_loop_create_default();      
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
            ESP_ERROR_CHECK(err);
        }
      
        err = esp_netif_init();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
            ESP_ERROR_CHECK(err);
        }       
        ESP_ERROR_CHECK(esp_event_handler_instance_register(+IP_EVENT, IP_EVENT_STA_GOT_IP, &on_got_ip, NULL, NULL));

        page_network_inited = true;
    }

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);
    
    // Determine if there is a saved WiFi
    auto& ssid_list = SsidManager::GetInstance().GetSsidList();
    if (ssid_list.empty()) {
        auto& ap = WifiConfigurationAp::GetInstance();

        ap.SetOnConfigDone([](){
            xEventGroupSetBits(wifi_event_group, WIFI_CONFIG_DONE_BIT);
        });
        ap.Start();
        ESP_LOGI("network", "The Web distribution network mode has been entered. Please connect your mobile phone to the ESP32 hotspot SSID: %s and visit 192.168.4.1", ap.GetSsid().c_str());

        snprintf(wifi_str, sizeof(wifi_str), "已进入Web配网模式，请用手机连接ESP32热点 SSID: %s 并访问192.168.4.1", ap.GetSsid().c_str());
        Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(10, 59, wifi_str, &Font18_UTF8, WHITE, BLACK);
        Refresh_page_network();

        ESP_LOGI("clock", "EPD_Sleep");
        EPD_Sleep();
        
        // // Wait for the distribution network to be completed
        // xEventGroupWaitBits(wifi_event_group, WIFI_CONFIG_DONE_BIT, pdTRUE, pdTRUE, portMAX_DELAY);
        // Wait for the distribution network to be completed
        while(1){
            event_bits = xEventGroupWaitBits(wifi_event_group, WIFI_CONFIG_DONE_BIT, pdTRUE, pdTRUE, pdMS_TO_TICKS(1000));
            if(event_bits & WIFI_CONFIG_DONE_BIT){
                break;
            }
            button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
            if (button == 23){
                // Turn off WiFi
                ESP_LOGI("wifi", "Turn off WiFi");
                wifi_set_enable(false);
                vTaskDelay(pdMS_TO_TICKS(1000));
                // restart
                ESP_LOGI("wifi", "esp restart");
                esp_restart();

                // wifi_enable = 0;
                // ESP_LOGI("wifi", "quit");
                // return;
                
            }
        }
         
        

        ESP_LOGI("network", "The distribution network is completed. Continue with the subsequent streams...");
        return;
    }

    int i=0;
    wifi_ap_record_t ap_info;
    // Connect to the saved WiFi
    WifiStation::GetInstance().Start();
    Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(10, 59, "连接WiFi中", &Font18_UTF8, WHITE, BLACK);
    Refresh_page_network();
    while (esp_wifi_sta_get_ap_info(&ap_info) != ESP_OK)
    {
        ESP_LOGI("network", "Wait for the successful WiFi connection");
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (i++ > 30)
        {
            ESP_LOGI("network", "Failed WiFi connection");
            Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(10, 59, "WiFi连接失败，请手动清除WiFi并重新配置WiFi，或者重启本设备", &Font18_UTF8, WHITE, BLACK);
            Refresh_page_network();
            return;
            // SsidManager::GetInstance().Clear();
            // esp_restart();
        }
        
    }

    // Wait for the IP address to be obtained
    esp_netif_ip_info_t ip_info;
    i = 0;
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(10, 59, "等待获取IP地址...", &Font18_UTF8, WHITE, BLACK);
    Refresh_page_network();
    while ((!netif || esp_netif_get_ip_info(netif, &ip_info) != ESP_OK || ip_info.ip.addr == 0) && i++ < 30) {
        ESP_LOGI("network", "Waiting to obtain the IP address...");
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    if (!netif || ip_info.ip.addr == 0) {
        ESP_LOGI("network", "Failed to obtain the IP address. Restart the device");
        Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(10, 59, "获取IP地址失败，请手动清除WiFi并重新配置WiFi，或者重启本设备", &Font18_UTF8, WHITE, BLACK);
        Refresh_page_network();
        return;
        // Clear WiFi
        // page_network_config();
        // esp_restart();
    }

    Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(10, 59, "WiFi已连接，获取网络时间中", &Font18_UTF8, WHITE, BLACK);
    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
    page_clock_init();

    ESP_LOGI("network", "The IP address has been obtained: " IPSTR, IP2STR(&ip_info.ip));
        
}

// WiFi configuration initialization
void page_network_init_main(void)
{
    int button = -1;        // Key status
    EventBits_t event_bits;  // Store the event group and wait for the result
    char wifi_str[150];
    if (!wifi_event_group) {
        wifi_event_group = xEventGroupCreate();
    }

    // Force clear NVS and experience Web distribution network
    // ESP_ERROR_CHECK(nvs_flash_erase());

    // Initialize NVS
    if (!page_network_inited) {
        esp_err_t err = esp_event_loop_create_default();      
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
            ESP_ERROR_CHECK(err);
        }
      
        err = esp_netif_init();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
            ESP_ERROR_CHECK(err);
        }    
        ESP_ERROR_CHECK(esp_event_handler_instance_register(+IP_EVENT, IP_EVENT_STA_GOT_IP, &on_got_ip, NULL, NULL));

        page_network_inited = true;
    }

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);
    
    // Determine if there is a saved WiFi
    auto& ssid_list = SsidManager::GetInstance().GetSsidList();
    if (ssid_list.empty()) {
        // Start the Web distribution AP
        auto& ap = WifiConfigurationAp::GetInstance();
        ap.SetSsidPrefix("ESP32");

        ap.SetOnConfigDone([](){
            xEventGroupSetBits(wifi_event_group, WIFI_CONFIG_DONE_BIT);
        });
        ap.Start();
        ESP_LOGI("network", "The Web distribution network mode has been entered. Please connect your mobile phone to the ESP32 hotspot SSID: %s and visit 192.168.4.1", ap.GetSsid().c_str());

        snprintf(wifi_str, sizeof(wifi_str), "已进入Web配网模式，请用手机连接ESP32热点 SSID: %s 并访问192.168.4.1", ap.GetSsid().c_str());
        Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(10, 59, wifi_str, &Font18_UTF8, WHITE, BLACK);
        Refresh_page_network();

        ESP_LOGI("clock", "EPD_Sleep");
        EPD_Sleep();
        
        // // Wait for the distribution network to be completed
        // xEventGroupWaitBits(wifi_event_group, WIFI_CONFIG_DONE_BIT, pdTRUE, pdTRUE, portMAX_DELAY);
        // Wait for the distribution network to be completed
        while(1){
            event_bits = xEventGroupWaitBits(wifi_event_group, WIFI_CONFIG_DONE_BIT, pdTRUE, pdTRUE, pdMS_TO_TICKS(1000));
            if(event_bits & WIFI_CONFIG_DONE_BIT){
                break;
            }
            button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
            if (button == 23){
                // Turn off WiFi
                ESP_LOGI("wifi", "Turn off WiFi");
                wifi_set_enable(false);
                vTaskDelay(pdMS_TO_TICKS(1000));
                // restart
                ESP_LOGI("wifi", "esp restart");
                esp_restart();
            }
        }

        ESP_LOGI("network", "The distribution network is completed. Proceed with the subsequent processes...");
        return;
    }

    int i=0;
    wifi_ap_record_t ap_info;
    // Connect to the saved WiFi
    WifiStation::GetInstance().Start();
    Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(10, 59, "连接WiFi中", &Font18_UTF8, WHITE, BLACK);
    Refresh_page_network();
    while (esp_wifi_sta_get_ap_info(&ap_info) != ESP_OK)
    {
        ESP_LOGI("network", "Wait for the successful WiFi connection");
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (i++ > 30)
        {
            ESP_LOGI("network", "Failed WiFi connection");
            Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawString_CN(10, 59, "WiFi连接失败", &Font18_UTF8, WHITE, BLACK);
            Paint_DrawString_CN(10, 90, "三秒后进入主页面", &Font18_UTF8, WHITE, BLACK);
            Refresh_page_network();
            vTaskDelay(pdMS_TO_TICKS(3000));
            return;
            // SsidManager::GetInstance().Clear();
            // esp_restart();
        }
    }

    // Wait for the IP address to be obtained
    esp_netif_ip_info_t ip_info;
    i = 0;
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(10, 59, "等待获取IP地址...", &Font18_UTF8, WHITE, BLACK);
    Refresh_page_network();
    while ((!netif || esp_netif_get_ip_info(netif, &ip_info) != ESP_OK || ip_info.ip.addr == 0) && i++ < 30) {
        ESP_LOGI("network", "Waiting to obtain the IP address...");
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    if (!netif || ip_info.ip.addr == 0) {
        ESP_LOGI("network", "Failed to obtain the IP address. Restart the device");
        Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawString_CN(10, 59, "获取IP地址失败", &Font18_UTF8, WHITE, BLACK);
        Paint_DrawString_CN(10, 90, "三秒后进入主页面", &Font18_UTF8, WHITE, BLACK);
        Refresh_page_network();
        vTaskDelay(pdMS_TO_TICKS(3000));
        return;
        // Clear WiFi
        // page_network_config();
        // esp_restart();
    }

    Paint_DrawRectangle(0, 57, 480, 650, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawString_CN(10, 59, "WiFi已连接，获取网络时间中", &Font18_UTF8, WHITE, BLACK);
    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
    page_clock_init();

    ESP_LOGI("network", "The IP address has been obtained: " IPSTR, IP2STR(&ip_info.ip));
}


// WiFi configuration initialization
int page_network_init_mode(void)
{
    if (!wifi_event_group) {
        wifi_event_group = xEventGroupCreate();
    }

    // Force clear NVS and experience Web distribution network
    // ESP_ERROR_CHECK(nvs_flash_erase());

    // Initialize NVS
    if (!page_network_inited) {
        esp_err_t err = esp_event_loop_create_default();      
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
            ESP_ERROR_CHECK(err);
        }
      
        err = esp_netif_init();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
            ESP_ERROR_CHECK(err);
        }      
        ESP_ERROR_CHECK(esp_event_handler_instance_register(+IP_EVENT, IP_EVENT_STA_GOT_IP, &on_got_ip, NULL, NULL));

        page_network_inited = true;
    }

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    auto& ssid_list = SsidManager::GetInstance().GetSsidList();
    if (ssid_list.empty()) {
        return 0;
    }

    int i=0;
    wifi_ap_record_t ap_info;
    // Connect to the saved WiFi
    WifiStation::GetInstance().Start();
    while (esp_wifi_sta_get_ap_info(&ap_info) != ESP_OK)
    {
        ESP_LOGI("network", "Wait for the successful WiFi connection");
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (i++ > 30)
        {
            ESP_LOGI("network", "Failed WiFi connection");
            return 0;
            // SsidManager::GetInstance().Clear();
            // esp_restart();
        }
    }

    // Wait for the IP address to be obtained
    esp_netif_ip_info_t ip_info;
    i = 0;
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    while ((!netif || esp_netif_get_ip_info(netif, &ip_info) != ESP_OK || ip_info.ip.addr == 0) && i++ < 10) {
        ESP_LOGI("network", "Waiting to obtain the IP address...");
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    if (!netif || ip_info.ip.addr == 0) {
        ESP_LOGI("network", "Failed to obtain the IP address");
        return 0;
        // esp_restart();
    }
    ESP_LOGI("network", "The IP address has been obtained: " IPSTR, IP2STR(&ip_info.ip));
    return 1;
}



// Network Settings menu, key interaction
void page_handle_network_key_event()
{
    int button = -1;
    wifi_enable = load_wifi_enable_from_nvs();

    int idx = 0;
    int time_count = 0;
    Time_data rtc_time;
    int last_minutes = -1;

    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);
    last_minutes = rtc_time.minutes;

    // Refresh the initial page
    display_network_init();
    // ESP_LOGI("network", "Button_Up: Previous Button_Down: Next Button_Function: Confirm Button_Function. Long press: Force full flashing of Button_Function/Boot. Double-click: Return");
    while (1) {
        
        button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        if(button == -1) time_count++;

        if(time_count >= EPD_Sleep_Time){
            button = Sleep_wake_network();
        }

        if (!wifi_enable) {
            if (button == 14) {
                idx = (idx + 1) % (2);
                display_network_option(idx);
                time_count = 0;
            } else if (button == 0) {
                idx = (idx + 1) % (2);
                display_network_option(idx);
                time_count = 0;
            } else if (button == 7) {
                if(!idx){
                    wifi_enable = 1;
                    wifi_set_enable(true);
                    idx = 0;
                    display_network_init();
                    ESP_LOGI("network", "WiFi is turned on.");
                } else {
                    return;
                }
            } else if (button == 8 || button == 22) {
                return;
            }
        } else { 
            if (button == 14) { 
                idx = (idx + 1) % (3);
                display_network_option(idx);
                time_count = 0;
            } else if (button == 0) {
                idx = (idx + 2) % (3);
                display_network_option(idx);
                time_count = 0;
            } else if (button == 7) {
                if(idx == 0){
                    wifi_enable = 0;
                    wifi_set_enable(false);
                    idx = 0;
                    display_network_init();
                    ESP_LOGI("network", "The WiFi has been turned off.");
                } else if(idx == 1){
                    page_network_config();
                    ESP_LOGI("network", "The WiFi has been cleared and entered the distribution network mode");
                } else{
                    return;
                }
            } else if (button == 8 || button == 22) {
                EPD_Init();
                Refresh_page_network();
                return;

            }
        }

        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        if ((rtc_time.minutes != last_minutes)) {
            last_minutes = rtc_time.minutes;
            display_network_time_img(rtc_time);
        }
    }
}

// Electronic paper refresh
static void display_network_init()
{
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono);
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
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    snprintf(BAT_Power_str, sizeof(BAT_Power_str), "%d%%", BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawString_EN(411, 11, BAT_Power_str, &Font16, WHITE, BLACK);
    Paint_DrawRectangle(375, 22, 395, 30, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(375, 22, 375+BAT_Power, 30, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawLine(2, 54, EPD_HEIGHT-2, 54, BLACK, DOT_PIXEL_2X2, LINE_STYLE_SOLID);


    if(wifi_enable) {
        page_network_show();
        Paint_DrawLine(2, 652, EPD_HEIGHT-2, 652, BLACK, DOT_PIXEL_2X2, LINE_STYLE_SOLID);
        Paint_DrawString_CN(10, 657, " 关闭 WiFi ", &Font24_UTF8, BLACK, WHITE);
        Paint_DrawString_CN(10, 703, " 清除 WiFi 并进入配网 ", &Font24_UTF8, WHITE, BLACK);
        Paint_DrawString_CN(10, 749, " 返回主菜单 ", &Font24_UTF8, WHITE, BLACK);
    } else {
        Paint_DrawLine(2, 652, EPD_HEIGHT-2, 652, BLACK, DOT_PIXEL_2X2, LINE_STYLE_SOLID);
        Paint_DrawString_CN(10, 59, "当前 WiFi 未开启", &Font18_UTF8, WHITE, BLACK);
        Paint_DrawString_CN(10, 657, " 开启 WiFi ", &Font24_UTF8, BLACK, WHITE);
        Paint_DrawString_CN(10, 703, " 返回主菜单 ", &Font24_UTF8, WHITE, BLACK);
    }
    Refresh_page_network();
}

static void display_network_option(int option)
{
    if(wifi_enable) {
        if(option == 0){
            Paint_DrawString_CN(10, 657, " 关闭 WiFi ", &Font24_UTF8, BLACK, WHITE);
            Paint_DrawString_CN(10, 703, " 清除 WiFi 并进入配网 ", &Font24_UTF8, WHITE, BLACK);
            Paint_DrawString_CN(10, 749, " 返回主菜单 ", &Font24_UTF8, WHITE, BLACK);
        } else if(option == 1){
            Paint_DrawString_CN(10, 657, " 关闭 WiFi ", &Font24_UTF8, WHITE, BLACK);
            Paint_DrawString_CN(10, 703, " 清除 WiFi 并进入配网 ", &Font24_UTF8, BLACK, WHITE);
            Paint_DrawString_CN(10, 749, " 返回主菜单 ", &Font24_UTF8, WHITE, BLACK);
        } else if(option == 2){
            Paint_DrawString_CN(10, 657, " 关闭 WiFi ", &Font24_UTF8, WHITE, BLACK);
            Paint_DrawString_CN(10, 703, " 清除 WiFi 并进入配网 ", &Font24_UTF8, WHITE, BLACK);
            Paint_DrawString_CN(10, 749, " 返回主菜单 ", &Font24_UTF8, BLACK, WHITE);
        }
        
    } else {
        if(option == 0) {
            Paint_DrawString_CN(10, 657, " 开启 WiFi ", &Font24_UTF8, BLACK, WHITE);
            Paint_DrawString_CN(10, 703, " 返回主菜单 ", &Font24_UTF8, WHITE, BLACK);
        } else if(option == 1){
            Paint_DrawString_CN(10, 657, " 开启 WiFi ", &Font24_UTF8, WHITE, BLACK);
            Paint_DrawString_CN(10, 703, " 返回主菜单 ", &Font24_UTF8, BLACK, WHITE);
        }
    }
    Refresh_page_network();
}

static void display_network_time_img(Time_data rtc_time)
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
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    snprintf(BAT_Power_str, sizeof(BAT_Power_str), "%d%%", BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawString_EN(411, 11, BAT_Power_str, &Font16, WHITE, BLACK);
    Paint_DrawRectangle(375, 22, 395, 30, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(375, 22, 375+BAT_Power, 30, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);

    Refresh_page_network();
}

static void Forced_refresh_network(void)
{
    EPD_Display_Base(Image_Mono);
}
static void Refresh_page_network(void)
{
    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
}
static int Sleep_wake_network(void)
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
            // Forced_refresh();
            break;
        } else if (button == 8 || button == 22 || button == 14 || button == 0 || button == 7){
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            // Forced_refresh_network();
            break;
        } 
        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        if(rtc_time.minutes != last_minutes) {
            last_minutes = rtc_time.minutes;
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            Refresh_page_network();
            display_network_time_img(rtc_time);
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




