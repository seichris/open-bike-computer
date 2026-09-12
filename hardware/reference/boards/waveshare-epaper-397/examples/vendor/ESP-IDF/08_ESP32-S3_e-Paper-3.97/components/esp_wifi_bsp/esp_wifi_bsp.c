#include <stdio.h>
#include <string.h>
#include "esp_wifi_bsp.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "nvs_flash.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_http_server.h"

#define WIFI_CONNECTED_BIT  BIT0
#define WIFI_FAIL_BIT       BIT1

static const char *TAG = "wifi";
EventGroupHandle_t wifi_event_group;
esp_netif_t *sta_netif = NULL;
esp_netif_t *ap_netif = NULL;
static int s_retry_num = 0;
#define MAX_RETRY 5

static void start_ap_mode(void);
static void start_sta_mode(void);
static esp_err_t wifi_config_post_handler(httpd_req_t *req);

static void event_handler(void *arg, esp_event_base_t event_base, int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        if (s_retry_num < MAX_RETRY) {
            esp_wifi_connect();
            s_retry_num++;
            ESP_LOGI(TAG, "retry to connect to the AP");
        } else {
            xEventGroupSetBits(wifi_event_group, WIFI_FAIL_BIT);
        }
        ESP_LOGI(TAG,"connect to the AP fail");
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* event = (ip_event_got_ip_t*) event_data;
        ESP_LOGI(TAG, "got ip:" IPSTR, IP2STR(&event->ip_info.ip));
        s_retry_num = 0;
        xEventGroupSetBits(wifi_event_group, WIFI_CONNECTED_BIT);
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_AP_START) {
        ESP_LOGI(TAG, "AP mode started");
    }
}

void espwifi_Init(void)
{
    wifi_event_group = xEventGroupCreate();
    nvs_flash_init();
    esp_netif_init();
    esp_event_loop_create_default();

    //STA mode
    start_sta_mode();

    // Wait for the connection result
    EventBits_t bits = xEventGroupWaitBits(wifi_event_group,
            WIFI_CONNECTED_BIT | WIFI_FAIL_BIT,
            pdFALSE,
            pdFALSE,
            pdMS_TO_TICKS(3000));

    if (bits & WIFI_CONNECTED_BIT) {
        ESP_LOGI(TAG, "connected to ap");
        wifi_ap_record_t ap_info;
        if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
            ESP_LOGI(TAG, "Connected SSID:%s RSSI:%d", ap_info.ssid, ap_info.rssi);
        }
    } else {
        ESP_LOGI(TAG, "Failed to connect STA, switching to AP mode");
        start_ap_mode();
    }
}

// STA mode initialization
static void start_sta_mode(void)
{
    sta_netif = esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);

    esp_event_handler_instance_t instance_any_id;
    esp_event_handler_instance_t instance_got_ip;
    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &event_handler, NULL, &instance_any_id);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &event_handler, NULL, &instance_got_ip);

    wifi_config_t wifi_config = {0};
    // Here, the last saved WiFi information can be read from NVS
    strcpy((char*)wifi_config.sta.ssid, "PDCN");
    strcpy((char*)wifi_config.sta.password, "1234567890");

    esp_wifi_set_mode(WIFI_MODE_STA);
    esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
    esp_wifi_start();
}

// AP mode initialization
static void start_ap_mode(void)
{
    ap_netif = esp_netif_create_default_wifi_ap();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);

    esp_event_handler_instance_t instance_any_id;
    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &event_handler, NULL, &instance_any_id);

    wifi_config_t wifi_config = {
        .ap = {
            .ssid = "ESP32_Config",
            .ssid_len = strlen("ESP32_Config"),
            .password = "12345678",
            .max_connection = 4,
            .authmode = WIFI_AUTH_WPA_WPA2_PSK
        },
    };
    if (strlen("12345678") == 0) {
        wifi_config.ap.authmode = WIFI_AUTH_OPEN;
    }

    esp_wifi_set_mode(WIFI_MODE_AP);
    esp_wifi_set_config(WIFI_IF_AP, &wifi_config);
    esp_wifi_start();

    // Start the HTTP server for network distribution
    httpd_handle_t server = NULL;
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    httpd_start(&server, &config);

    // The registration page is provided
    httpd_uri_t wifi_config_uri = {
        .uri       = "/",
        .method    = HTTP_GET,
        .handler   = wifi_config_post_handler,
        .user_ctx  = NULL
    };
    httpd_register_uri_handler(server, &wifi_config_uri);
}

// A simple WiFi selection page (GET request returns HTML)
static esp_err_t wifi_config_post_handler(httpd_req_t *req)
{
    // Scan WiFi
    wifi_scan_config_t scan_config = {0};
    esp_wifi_scan_start(&scan_config, true);

    uint16_t ap_num = 0;
    esp_wifi_scan_get_ap_num(&ap_num);
    wifi_ap_record_t *ap_list = calloc(ap_num, sizeof(wifi_ap_record_t));
    esp_wifi_scan_get_ap_records(&ap_num, ap_list);

    // Allocate HTML buffers using the heap to prevent stack overflow
    char *html = calloc(1, 2048);
    strcat(html, "<!DOCTYPE html><html><body>"
                 "<h2>WiFi 配置</h2>"
                 "<form method='POST' action='/wifi'>"
                 "SSID:<select name='ssid'>");
    for (int i = 0; i < ap_num; ++i) {
        char option[128];
        snprintf(option, sizeof(option), "<option value='%s'>%s (%d)</option>", 
                 ap_list[i].ssid, ap_list[i].ssid, ap_list[i].rssi);
        strcat(html, option);
    }
    strcat(html, "</select><br>"
                 "密码:<input name='password' type='password'><br>"
                 "<input type='submit' value='连接'>"
                 "</form></body></html>");

    free(ap_list);
    httpd_resp_send(req, html, HTTPD_RESP_USE_STRLEN);
    free(html);
    return ESP_OK;
}