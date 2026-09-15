
#include "axp_prot.h"
#include "freertos/FreeRTOS.h"
#include "i2c_bsp.h"
#include "esp_log.h"
#include "esp_err.h"
#include "driver/gpio.h"
#include "XPowersLib.h"
#include <stdint.h>
#include "es8311_bsp.h"

const char *TAG = "axp2101";

static XPowersPMU axp2101;

static int AXP2101_SLAVE_Read(uint8_t devAddr, uint8_t regAddr, uint8_t *data, uint8_t len)
{
    esp_err_t ret = i2c_read_reg(devAddr, regAddr, data, len);
    if (ret == ESP_OK) {
        return 0;
    } else {
        ESP_LOGE(TAG, "I2C read failed: addr=0x%02X, reg=0x%02X, len=%d, err=%d", devAddr, regAddr, len, ret);
        return -1; 
    }
}

static int AXP2101_SLAVE_Write(uint8_t devAddr, uint8_t regAddr, uint8_t *data, uint8_t len)
{
    esp_err_t ret = i2c_write_reg(devAddr, regAddr, data, len);
    if (ret == ESP_OK) {
        return 0;
    } else {
        ESP_LOGE(TAG, "I2C write failed: addr=0x%02X, reg=0x%02X, len=%d, err=%d", devAddr, regAddr, len, ret);
        return -1;
    }
}

void axp_init(void)
{
    if (axp2101.begin(AXP2101_SLAVE_ADDRESS, AXP2101_SLAVE_Read, AXP2101_SLAVE_Write)) {
        ESP_LOGI(TAG, "Init PMU SUCCESS!");
    } else {
        ESP_LOGE(TAG, "Init PMU FAILED!");
    }

    axp2101.setVbusVoltageLimit(XPOWERS_AXP2101_VBUS_VOL_LIM_4V36);
    axp2101.setVbusCurrentLimit(XPOWERS_AXP2101_VBUS_CUR_LIM_1500MA);
    uint16_t vol = axp2101.getSysPowerDownVoltage();
    // ESP_LOGI(TAG,"getvSysshutdownVoltage:%d", vol);
    axp2101.setSysPowerDownVoltage(2600);
    vol = axp2101.getSysPowerDownVoltage();
    // ESP_LOGI(TAG,"getvSysshutdownVoltage:%d", vol);
    axp2101.setDC1Voltage(3300);
    // ESP_LOGI(TAG,"getDC1Voltage:%d", axp2101.getDC1Voltage());
    axp2101.setALDO1Voltage(3300);
    axp2101.setALDO2Voltage(3300);
    axp2101.setALDO3Voltage(3300);
    // ESP_LOGI(TAG,"%s",axp2101.isEnableALDO1() ? "ALDO1_ON" : "ALDO1_OFF");

    /* Press the button to turn off the time setting */
    axp2101.setPowerKeyPressOffTime(XPOWERS_POWEROFF_4S);
    uint8_t opt = axp2101.getPowerKeyPressOffTime();
    // switch (opt) {
    // case XPOWERS_POWEROFF_4S: ESP_LOGI(TAG,"PowerKeyPressOffTime:4 Second");
    //     break;
    // case XPOWERS_POWEROFF_6S: ESP_LOGI(TAG,"PowerKeyPressOffTime:6 Second");
    //     break;
    // case XPOWERS_POWEROFF_8S: ESP_LOGI(TAG,"PowerKeyPressOffTime:8 Second");
    //     break;
    // case XPOWERS_POWEROFF_10S: ESP_LOGI(TAG,"PowerKeyPressOffTime:10 Second");
    //     break;
    // default:
    //     break;
    // }
    /* Set the power-on time by pressing the button */
    axp2101.setPowerKeyPressOnTime(XPOWERS_POWERON_1S);
    opt = axp2101.getPowerKeyPressOnTime();
    // switch (opt) {
    // case XPOWERS_POWERON_128MS: ESP_LOGI(TAG,"PowerKeyPressOnTime:128 Ms");
    //     break;
    // case XPOWERS_POWERON_512MS: ESP_LOGI(TAG,"PowerKeyPressOnTime:512 Ms");
    //     break;
    // case XPOWERS_POWERON_1S: ESP_LOGI(TAG,"PowerKeyPressOnTime:1 Second");
    //     break;
    // case XPOWERS_POWERON_2S: ESP_LOGI(TAG,"PowerKeyPressOnTime:2 Second");
    //     break;
    // default:
    //     break;
    // }

    axp2101.enableTemperatureMeasure();
    axp2101.enableBattDetection();
    axp2101.enableVbusVoltageMeasure();
    axp2101.enableBattVoltageMeasure();
    axp2101.enableSystemVoltageMeasure();

    /* Disable the CHGLED function */
    axp2101.setChargingLedMode(XPOWERS_CHG_LED_OFF);

    /* Charge the VBAT */
    axp2101.setPrechargeCurr(XPOWERS_AXP2101_PRECHARGE_50MA); // Precharging current
    axp2101.setChargerConstantCurr(XPOWERS_AXP2101_CHG_CUR_200MA);//Constant current charging current directly affects the charging speed
    axp2101.setChargerTerminationCurr(XPOWERS_AXP2101_CHG_ITERM_25MA);//Charging termination current

    /* Set the cut-off voltage for battery charging */
    axp2101.setChargeTargetVoltage(XPOWERS_AXP2101_CHG_VOL_4V2);

    /* Watchdog function */
#if 0
    axp2101.setWatchdogConfig(XPOWERS_AXP2101_WDT_IRQ_TO_PIN); // Trigger the interrupt pin
    axp2101.setWatchdogTimeout(XPOWERS_AXP2101_WDT_TIMEOUT_4S);// The dog feeding time is 4 seconds
    axp2101.enableWatchdog();// enabled
    //axp2101.clrWatchdog(); // feed dogs
#endif
    /* RTC battery charging Settings */
    axp2101.setButtonBatteryChargeVoltage(3000);  // Set the charging termination voltage of the RTC battery to 3
    axp2101.enableButtonBatteryCharge();          // Start RTC charging
    /* The learning curve and low battery warning of BAT batteries */
    axp2101.setLowBatWarnThreshold(10);           // Output is interrupted when the rate is below 10%
    axp2101.setLowBatShutdownThreshold(5);        // Turn off the battery when it drops below 5%
    axp2101.fuelGaugeControl(true, true);         // Enable battery learning and save the data to ROM 
}


// The status of axp2101
void axp2101_getVoltage_Task(void *arg)
{
  static const char *sTag = "bat";
  for(;;)
  {
    ESP_LOGI(sTag,"CHARG:%s",axp2101.isCharging() ? "YES" : "NO ");     // Is it charging?
    ESP_LOGI(sTag,"DISC:%s",axp2101.isDischarge() ? "YES" : "NO ");     // Is it discharging?
    ESP_LOGI(sTag,"STBY:%s",axp2101.isStandby() ? "YES" : "NO ");       // Is it in standby mode
    ESP_LOGI(sTag,"VBUSIN:%s",axp2101.isVbusIn() ? "YES" : "NO ");       // Has VBUS input been detected
    ESP_LOGI(sTag,"VGOOD:%s",axp2101.isVbusGood() ? "YES" : "NO ");       // Is the power supply stable?
    ESP_LOGI(sTag,"VBAT:%dmV",axp2101.getBattVoltage());                 // Battery voltage
    ESP_LOGI(sTag,"VBUS:%dmV",axp2101.getVbusVoltage());                 // VBUS voltage
    ESP_LOGI(sTag,"VSYS:%dmV",axp2101.getSystemVoltage());                // VSYS voltage
    ESP_LOGI(sTag,"Percentage:%d%%",axp2101.getBatteryPercent());              // Battery power %
    /* Charging state */
    uint8_t charge_status = axp2101.getChargerStatus();
    switch (charge_status)
    {
      case XPOWERS_AXP2101_CHG_TRI_STATE:
        ESP_LOGI(sTag,"CHG_STATUS:tri_charge");    // Three charging states
        break;
      case XPOWERS_AXP2101_CHG_PRE_STATE:
        ESP_LOGI(sTag,"CHG_STATUS:pre_charge");    // Pre-charging state
        break;
      case XPOWERS_AXP2101_CHG_CC_STATE:
        ESP_LOGI(sTag,"constant charge(CC)");     // Constant current charging state
        break;
      case XPOWERS_AXP2101_CHG_CV_STATE:
        ESP_LOGI(sTag,"constant voltage(CV)");    // Constant voltage charging state
        break;
      case XPOWERS_AXP2101_CHG_DONE_STATE:
        ESP_LOGI(sTag,"charge done");            // Charging completed
        break;
      case XPOWERS_AXP2101_CHG_STOP_STATE:
        ESP_LOGI(sTag,"not charging");           // No charging
        break;
      default:
        break;
    }
    ESP_LOGI(sTag,"ButtonBatteryVoltage:%dmV",axp2101.getButtonBatteryVoltage());              // Button battery voltage
    ESP_LOGI(sTag,"\n\n");
    vTaskDelay(pdMS_TO_TICKS(1000));
  }
}

// Obtain battery power
int get_battery_power(void)
{
    return axp2101.getBatteryPercent();
}

// Obtain the power output status
bool gatpwrstate(uint8_t tab)
{
    switch (tab) {
        case DC1:
            return axp2101.isEnableDC1();
        case ALDO1:
            return axp2101.isEnableALDO1();
        case ALDO2:
            return axp2101.isEnableALDO2();
        case ALDO3:
            return axp2101.isEnableALDO3();
        case ALDO4:
            return axp2101.isEnableALDO4();
        default:
            return 0;
    }
}

// Enable power supply output
bool enapwrstate(uint8_t tab)
{
    switch (tab) {
        case DC1:
            return axp2101.enableDC1();
        case ALDO1:
            return axp2101.enableALDO1();
        case ALDO2:
            return axp2101.enableALDO2();
        case ALDO3:
            return axp2101.enableALDO3();
        case ALDO4:
            return axp2101.enableALDO4();
        default:
            return 0;
    }
}

// Turn off the power output
bool disapwrstate(uint8_t tab)
{
    switch (tab) {
        case DC1:
            ESP_LOGW("POWER", "To ensure normal operation, it is strictly prohibited to turn off the power supply of DC1");
            return 0;
        case ALDO1:
            return axp2101.disableALDO1();
        case ALDO2:
            return axp2101.disableALDO2();
        case ALDO3:
            return axp2101.disableALDO3();
        case ALDO4:
            return axp2101.disableALDO4();
        default:
            return 0;
    }
}

// Obtain the current voltage of the power supply
uint16_t getpwrVoltage(uint8_t tab)
{
    switch (tab) {
        case DC1:
            return axp2101.getDC1Voltage();
        case ALDO1:
            return axp2101.getALDO1Voltage();
        case ALDO2:
            return axp2101.getALDO2Voltage();
        case ALDO3:
            return axp2101.getALDO3Voltage();
        case ALDO4:
            return axp2101.getALDO4Voltage();
        default:
            return 0;
    }
}

// Set the current voltage of the power supply
uint16_t setpwrVoltage(uint8_t tab, uint16_t millivolt)
{
    switch (tab) {
        case DC1:
            ESP_LOGW("POWER", "To ensure normal operation, it is strictly prohibited to modify the power supply of DC1");
            return 0;
        case ALDO1:
            return axp2101.setALDO1Voltage(millivolt);
        case ALDO2:
            return axp2101.setALDO2Voltage(millivolt);
        case ALDO3:
            return axp2101.setALDO3Voltage(millivolt);
        case ALDO4:
            return axp2101.setALDO4Voltage(millivolt);
        default:
            return 0;
    }
}

// power off
void axp_pwr_off()
{
    ESP_LOGI(TAG, "Preparing for power off - cleaning up audio");
    es8311_audio_shutdown_cleanup();  // Clean up the audio first
    ESP_LOGI(TAG, "Audio cleanup done, shutting down");

    axp2101.shutdown();
}


// Detect USB access
bool get_usb_connected()
{
    return axp2101.isVbusIn();
}


#ifdef __cplusplus
extern "C" {
#endif

uint16_t getstat()
{
    uint16_t state=axp2101.status();
    ESP_LOGI(TAG,"axp2101 state: = 0x%x", state);
    return state;
}

#ifdef __cplusplus
}
#endif