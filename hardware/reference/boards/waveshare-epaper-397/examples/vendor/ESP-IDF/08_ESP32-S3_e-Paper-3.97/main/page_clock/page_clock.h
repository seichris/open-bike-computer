#ifndef PAGE_CLOCK_H
#define PAGE_CLOCK_H


#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char lunarDate[16];
    char festival[32];
    char lunarFestival[32];
    char IMonthCn[16];
    char IDayCn[16];
    char gzYear[16];
    char gzMonth[16];
    char gzDay[16];
    char ncWeek[16];
    char Term[32];
    char astro[16];
} LunarInfo;

typedef struct {
    uint16_t years;
    uint16_t months;
    uint16_t days;
    uint16_t hours;
    uint16_t minutes;
    uint16_t week;
    int BAT_Power;
    float temperature_val = 0.0f;
    float humidity_val = 0.0f;
} Clock_TH;

void page_clock_show(void);
void page_calendar_show(void);
void page_clock_init(void);

void page_clock_show_mode();
void page_calendar_show_mode();



void Forced_refresh_clock(void);
void Refresh_page_clock(void);

// Lunar calendar acquisition
int Lunar_calendar_acquisition(char *str, int str_len, const char* Time);

#ifdef __cplusplus
}
#endif

#endif // PAGE_CLOCK_H
