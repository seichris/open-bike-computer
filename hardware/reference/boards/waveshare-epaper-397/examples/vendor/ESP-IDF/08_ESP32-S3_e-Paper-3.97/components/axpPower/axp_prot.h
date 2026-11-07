#ifndef AXP_PROT_H
#define AXP_PROT_H

#include <stdint.h>

typedef enum axp2101_pwr_tab {
    DC1 = 1,
    ALDO1,
    ALDO2,
    ALDO3,
    ALDO4,
} axp2101_pwr_tab_t;

#ifdef __cplusplus
extern "C" {
#endif


void axp_init(void);
void axp2101_getVoltage_Task(void *arg);
int get_battery_power(void);
bool gatpwrstate(uint8_t tab);
bool enapwrstate(uint8_t tab); 
bool disapwrstate(uint8_t tab);
uint16_t getpwrVoltage(uint8_t tab);
uint16_t setpwrVoltage(uint8_t tab, uint16_t millivolt);
uint16_t getstat();
void axp_pwr_off();
bool get_usb_connected();

#ifdef __cplusplus
}
#endif

#endif 