#ifndef I2C_BSP_H
#define I2C_BSP_H
#include "driver/i2c_master.h"

#ifdef __cplusplus
extern "C" {
#endif

// I2C Master Bus Handle
extern i2c_master_bus_handle_t i2c_bus_handle;

// Handles for each device (optional, used to enhance performance)
extern i2c_master_dev_handle_t rtc_dev_handle;
extern i2c_master_dev_handle_t shtc3_dev_handle;
extern i2c_master_dev_handle_t axp2101_dev_handle;
extern i2c_master_dev_handle_t qmi8658_dev_handle;


#define AXP2101Addr    0x34
#define SHTC3Addr      0x70
#define PCF85063Addr   0x51
#define ES8311_I2C_ADDR 0x18
#define QMI8658_SLAVE_ADDR_L 0x6a      // SA0 is GND
#define QMI8658_SLAVE_ADDR_H 0x6b      // SA0 is VCC

#define ESP32_SCL_NUM    42
#define ESP32_SDA_NUM    41
#define I2C_MASTER_NUM   0
#define I2C_MASTER_FREQ_HZ 400000



// Initialize the I2C Master bus
void i2c_master_init(void);

// Initialize all I2C devices (create device handles)
esp_err_t i2c_devices_init(void);

// Add a device to the bus (return device handle)
esp_err_t i2c_bus_add_device(uint8_t dev_addr, uint32_t scl_speed_hz, i2c_master_dev_handle_t *dev_handle);

// Write to the register (with register address
esp_err_t i2c_write_reg(uint8_t dev_addr, uint8_t reg, uint8_t *data, size_t len);

// Read the register (write the register address first and then read the data)
esp_err_t i2c_read_reg(uint8_t dev_addr, uint8_t reg, uint8_t *data, size_t len);

// Only write data (without register addresses)
esp_err_t i2c_write_bytes(uint8_t dev_addr, uint8_t *data, size_t len);

// Read-only data (without register address)
esp_err_t i2c_read_bytes(uint8_t dev_addr, uint8_t *data, size_t len);

// Macro definitions compatible with old code
#define i2c_master_write_read_dev(addr, wbuf, wlen, rbuf, rlen) \
    i2c_master_write_read_device_compat(addr, wbuf, wlen, rbuf, rlen)

#define i2c_writr_buff(addr, reg, buf, len) \
    i2c_write_bytes(addr, buf, len)

#define i2c_read_buff(addr, reg, buf, len) \
    i2c_read_bytes(addr, buf, len)

// Compatibility function
esp_err_t i2c_master_write_read_device_compat(uint8_t addr, const uint8_t *wbuf, size_t wlen, uint8_t *rbuf, size_t rlen);


#ifdef __cplusplus
}
#endif

#endif