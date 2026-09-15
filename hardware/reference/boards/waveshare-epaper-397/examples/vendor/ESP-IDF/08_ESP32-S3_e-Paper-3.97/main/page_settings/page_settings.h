#ifndef PAGE_SETTINGS_H
#define PAGE_SETTINGS_H

typedef struct {
    float acc[3];
    float gyro[3];
} imu_status_t;


#ifdef __cplusplus
extern "C" {
#endif

extern int qmi8658_status;
extern bool auto_rotate;

int qmi8658_status_t(void);

void page_settings_show(void);

#ifdef __cplusplus
}
#endif

#endif





