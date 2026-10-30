#ifndef ESP_WIFI_BSP_H
#define ESP_WIFI_BSP_H

#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"

#ifdef __cplusplus
extern "C" {
#endif

extern EventGroupHandle_t wifi_event_group;
void espwifi_Init(void);
void espwifi_Deinit(void);

#ifdef __cplusplus
}
#endif

#endif