#ifndef ES8311_BSP_H
#define ES8311_BSP_H


#include "esp_system.h"
#include "esp_check.h"
#include "driver/i2s_std.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Example configurations */
#define EXAMPLE_RECV_BUF_SIZE   (2400)
#define EXAMPLE_SAMPLE_RATE     (16000)
#define EXAMPLE_MCLK_MULTIPLE   (384) // If not using 24-bit data width, 256 should be enough
#define EXAMPLE_MCLK_FREQ_HZ    (EXAMPLE_SAMPLE_RATE * EXAMPLE_MCLK_MULTIPLE)
#define EXAMPLE_VOICE_VOLUME    80
#define EXAMPLE_MIC_GAIN        4

// I2S configuration
#define I2S_NUM                 I2S_NUM_0
#define I2S_MCLK_PIN            GPIO_NUM_13    // Master clock
#define I2S_BCK_PIN             GPIO_NUM_14    // Bit clock
#define I2S_WS_PIN              GPIO_NUM_47    // Word selection/frame clock
#define I2S_DATA_PIN            GPIO_NUM_21    // Data input
#define I2S_DATA_POUT           GPIO_NUM_48    // Data output
#define I2S_PA_PIN              GPIO_NUM_39    // PA power amplifier pins


#define I2C_NUM         (0)

extern i2s_chan_handle_t tx_handle;
extern i2s_chan_handle_t rx_handle;
extern esp_codec_dev_handle_t play_dev_handle;
extern esp_codec_dev_handle_t record_dev_handle;


esp_err_t es8311_codec_init(void);
esp_err_t i2s_driver_init(void);

// Pre-shutdown processing
void es8311_audio_shutdown_cleanup(void);









#ifdef __cplusplus
}
#endif


#endif // ES8311_BSP_H



