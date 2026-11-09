#include "EPD_3in97.h"
#include "GUI_Paint.h"
#include "fonts.h"
#include "ImageData.h"
#include <Wire.h>
#include <SPI.h>
#include "SensorQMI8658.hpp"

#ifndef SENSOR_SDA
#define SENSOR_SDA  41
#endif

#ifndef SENSOR_SCL
#define SENSOR_SCL  42
#endif

#ifndef SENSOR_IRQ
#define SENSOR_IRQ  39
#endif

SensorQMI8658 qmi;

IMUdata acc;
IMUdata gyr;

UBYTE *BlackImage;

void setup() {
    printf("EPD_3IN97_test Demo\r\n");
    DEV_Module_Init();

    printf("e-Paper Init and Clear...\r\n");
    EPD_3IN97_Init();
    EPD_3IN97_Clear(); // White
    DEV_Delay_ms(2000);

    qmi8658a();

    //Create a new image cache
    UWORD Imagesize = ((EPD_3IN97_WIDTH % 8 == 0)? (EPD_3IN97_WIDTH / 8 ): (EPD_3IN97_WIDTH / 8 + 1)) * EPD_3IN97_HEIGHT;
    if((BlackImage = (UBYTE *)malloc(Imagesize)) == NULL) {
        printf("Failed to apply for black memory...\r\n");
        while(1);
    }
    printf("Paint_NewImage\r\n");
    Paint_NewImage(BlackImage, EPD_3IN97_WIDTH, EPD_3IN97_HEIGHT, 270, WHITE);
    

    Paint_SelectImage(BlackImage);
    Paint_Clear(WHITE);
    Paint_DrawString_EN(50, 50, "ACCEL.x:", &Font24, WHITE, BLACK);
    Paint_DrawString_EN(50, 80, "ACCEL.y:", &Font24, WHITE, BLACK);
    Paint_DrawString_EN(50, 110, "ACCEL.z:", &Font24, WHITE, BLACK);
    Paint_DrawString_EN(50, 140, "GYRO.x:", &Font24, WHITE, BLACK);
    Paint_DrawString_EN(50, 170, "GYRO.y:", &Font24, WHITE, BLACK);
    Paint_DrawString_EN(50, 200, "GYRO.z:", &Font24, WHITE, BLACK);
    EPD_3IN97_Display_Base(BlackImage);
    DEV_Delay_ms(2000);
	
}
void qmi8658a()
{
    Serial.begin(115200);
    while (!Serial);

#if IMU_INT > 0
    qmi.setPins(IMU_INT);
#endif

    //Using WIRE !!
    if (!qmi.begin(Wire, QMI8658_H_SLAVE_ADDRESS, SENSOR_SDA, SENSOR_SCL)) {
        Serial.println("Failed to find QMI8658 - check your wiring!");
        while (1) {
            delay(1000);
        }
    }

    /* Get chip id*/
    Serial.print("Device ID:");
    Serial.println(qmi.getChipID(), HEX);


    if (qmi.selfTestAccel()) {
        Serial.println("Accelerometer self-test successful");
    } else {
        Serial.println("Accelerometer self-test failed!");
    }

    if (qmi.selfTestGyro()) {
        Serial.println("Gyroscope self-test successful");
    } else {
        Serial.println("Gyroscope self-test failed!");
    }


    qmi.configAccelerometer(
        /*
         * ACC_RANGE_2G
         * ACC_RANGE_4G
         * ACC_RANGE_8G
         * ACC_RANGE_16G
         * */
        SensorQMI8658::ACC_RANGE_4G,
        /*
         * ACC_ODR_1000H
         * ACC_ODR_500Hz
         * ACC_ODR_250Hz
         * ACC_ODR_125Hz
         * ACC_ODR_62_5Hz
         * ACC_ODR_31_25Hz
         * ACC_ODR_LOWPOWER_128Hz
         * ACC_ODR_LOWPOWER_21Hz
         * ACC_ODR_LOWPOWER_11Hz
         * ACC_ODR_LOWPOWER_3H
        * */
        SensorQMI8658::ACC_ODR_1000Hz,
        /*
        *  LPF_MODE_0     //2.66% of ODR
        *  LPF_MODE_1     //3.63% of ODR
        *  LPF_MODE_2     //5.39% of ODR
        *  LPF_MODE_3     //13.37% of ODR
        *  LPF_OFF        // OFF Low-Pass Fitter
        * */
        SensorQMI8658::LPF_MODE_0);




    qmi.configGyroscope(
        /*
        * GYR_RANGE_16DPS
        * GYR_RANGE_32DPS
        * GYR_RANGE_64DPS
        * GYR_RANGE_128DPS
        * GYR_RANGE_256DPS
        * GYR_RANGE_512DPS
        * GYR_RANGE_1024DPS
        * */
        SensorQMI8658::GYR_RANGE_64DPS,
        /*
         * GYR_ODR_7174_4Hz
         * GYR_ODR_3587_2Hz
         * GYR_ODR_1793_6Hz
         * GYR_ODR_896_8Hz
         * GYR_ODR_448_4Hz
         * GYR_ODR_224_2Hz
         * GYR_ODR_112_1Hz
         * GYR_ODR_56_05Hz
         * GYR_ODR_28_025H
         * */
        SensorQMI8658::GYR_ODR_896_8Hz,
        /*
        *  LPF_MODE_0     //2.66% of ODR
        *  LPF_MODE_1     //3.63% of ODR
        *  LPF_MODE_2     //5.39% of ODR
        *  LPF_MODE_3     //13.37% of ODR
        *  LPF_OFF        // OFF Low-Pass Fitter
        * */
        SensorQMI8658::LPF_MODE_3);

    /*
    * If both the accelerometer and gyroscope sensors are turned on at the same time,
    * the output frequency will be based on the gyroscope output frequency.
    * The example configuration is 896.8HZ output frequency,
    * so the acceleration output frequency is also limited to 896.8HZ
    * */
    qmi.enableGyroscope();
    qmi.enableAccelerometer();

    // Print register configuration information
    qmi.dumpCtrlRegister();



#if IMU_INT > 0
    // If you want to enable interrupts, then turn on the interrupt enable
    qmi.enableINT(SensorQMI8658::INTERRUPT_PIN_1, true);
    qmi.enableINT(SensorQMI8658::INTERRUPT_PIN_2, false);
#endif

    Serial.println("Read data now...");

}

void qmi8658_data_show()
{
    char buff[80];

    Paint_NewImage(BlackImage, Font20.Height *9, Font20.Width * 7, 270, WHITE);
    Paint_SelectImage(BlackImage);
    Paint_Clear(WHITE);
	//
    sprintf(buff, "%.2f", acc.x);
    Paint_DrawString_EN(0, 0, buff, &Font20, WHITE, BLACK);
    sprintf(buff, "%.2f", acc.y);
    Paint_DrawString_EN(0, 30, buff, &Font20, WHITE, BLACK);
    sprintf(buff, "%.2f", acc.z);
    Paint_DrawString_EN(0, 60, buff, &Font20, WHITE, BLACK);
    sprintf(buff, "%.2f", gyr.x);
    Paint_DrawString_EN(0, 90, buff, &Font20, WHITE, BLACK);
    sprintf(buff, "%.2f", gyr.y);
    Paint_DrawString_EN(0, 120, buff, &Font20, WHITE, BLACK);
    sprintf(buff, "%.2f", gyr.z);
    Paint_DrawString_EN(0, 150, buff, &Font20, WHITE, BLACK);

    EPD_3IN97_Display_Partial(BlackImage, 60, 300, 60 + Font20.Height*9 , 300+ Font20.Width * 7);
    DEV_Delay_ms(1000);
}

void loop() {
    if (qmi.getDataReady()) {

        if (qmi.getAccelerometer(acc.x, acc.y, acc.z)) {
            // Print to serial plotter
            Serial.print("ACCEL.x:"); Serial.print(acc.x); Serial.print(",");
            Serial.print("ACCEL.y:"); Serial.print(acc.y); Serial.print(",");
            Serial.print("ACCEL.z:"); Serial.print(acc.z); Serial.println();
        }
        if (qmi.getGyroscope(gyr.x, gyr.y, gyr.z)) {
            // Print to serial plotter
            Serial.print(" GYRO.x:"); Serial.print(gyr.x); Serial.print(",");
            Serial.print(" GYRO.y:"); Serial.print(gyr.y); Serial.print(",");
            Serial.print(" GYRO.z:"); Serial.print(gyr.z); Serial.println();

        }
        qmi8658_data_show();
    }
    delay(1000);
}