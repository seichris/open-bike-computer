#ifndef USER_CONFIG_H
#define USER_CONFIG_H

#define EPD_SPI_NUM        SPI2_HOST
#define ESP32_I2C_DEV_NUM  I2C_NUM_0

#define EPD_WIDTH  800
#define EPD_HEIGHT 480

/*EPD port Init*/
#define EPD_DC_PIN    GPIO_NUM_9
#define EPD_CS_PIN    GPIO_NUM_10
#define EPD_SCK_PIN   GPIO_NUM_11
#define EPD_MOSI_PIN  GPIO_NUM_12
#define EPD_RST_PIN   GPIO_NUM_46
#define EPD_BUSY_PIN  GPIO_NUM_3

/*Low-power wake-up*/
#define ext_wakeup_pin_1 GPIO_NUM_0

/*ESP32 I2C Init*/
#define ESP32_I2C_SDA_PIN GPIO_NUM_41
#define ESP32_I2C_SCL_PIN GPIO_NUM_42

/*lvgl init*/
#define EXAMPLE_LVGL_TICK_PERIOD_MS    5
#define EXAMPLE_LVGL_TASK_MAX_DELAY_MS 500
#define EXAMPLE_LVGL_TASK_MIN_DELAY_MS 100

/*i2c dev*/
#define I2C_RTC_DEV_Address        0x51
#define I2C_SHTC3_DEV_Address      0x70           

#endif // !USER_CONFIG_H