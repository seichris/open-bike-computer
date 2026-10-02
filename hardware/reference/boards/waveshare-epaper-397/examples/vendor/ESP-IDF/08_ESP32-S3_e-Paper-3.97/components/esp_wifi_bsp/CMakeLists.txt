idf_component_register(
  SRCS "esp_wifi_bsp.c"
  INCLUDE_DIRS "."
  PRIV_REQUIRES
    esp_wifi
    esp_event
    nvs_flash
    esp_http_server
)