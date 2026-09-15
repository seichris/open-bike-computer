#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MAX_ALARMS 6

typedef struct {
    uint8_t hour;
    uint8_t minute;
    uint8_t enabled;  // 1= On, 0= off
} Alarm;

extern Alarm alarms[MAX_ALARMS];

bool add_alarm(uint8_t hour, uint8_t minute);
bool remove_alarm(uint8_t hour, uint8_t minute);
bool check_alarm(uint8_t hour, uint8_t minute);
void print_alarms(void);

void save_alarms_to_nvs(void);
void load_alarms_from_nvs(void);

void page_alarm_menu(void);
void alarm_task(void *param);

#ifdef __cplusplus
}
#endif
