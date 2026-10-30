#ifndef EPAPER_DRIVER_H
#define EPAPER_DRIVER_H

#include "GUI_BMPfile.h"
#include "GUI_Paint.h"
#include "ImageData.h"


/**
 * GPIO config
**/
#define EPD_SCLK_PIN    11
#define EPD_MOSI_PIN    12

#define EPD_CS_PIN      10

#define EPD_DC_PIN      9

#define EPD_RST_PIN     46
#define EPD_BUSY_PIN    3



#define epaper_rst_1    gpio_set_level(EPD_RST_PIN,1)
#define epaper_rst_0    gpio_set_level(EPD_RST_PIN,0)
#define epaper_cs_1     gpio_set_level(EPD_CS_PIN,1)
#define epaper_cs_0     gpio_set_level(EPD_CS_PIN,0)
#define epaper_dc_1     gpio_set_level(EPD_DC_PIN,1)
#define epaper_dc_0     gpio_set_level(EPD_DC_PIN,0)

#define ReadBusy        gpio_get_level(EPD_BUSY_PIN)




// Display resolution
#define EPD_WIDTH               800
#define EPD_HEIGHT              480
#define EPD_SIZE_MONO           48000
#define EPD_SIZE_4GRAY          96000

// Refresh mode
#define Partial_refresh         0
#define Global_refresh          1

#ifdef __cplusplus
extern "C" {
#endif

void epaper_port_init(void);

void EPD_Init(void);
void EPD_Init_Fast(void);
void EPD_Init_Partial(void);
void EPD_Init_4GRAY(void);
void EPD_Clear(void);
void EPD_Clear_Black(void);
void EPD_Display(const UBYTE *Image);
void EPD_Display_Base(const UBYTE *Image);
void EPD_Display_Fast(const UBYTE *Image);
void EPD_Display_Fast_Base(const UBYTE *Image);
void EPD_Display_OneShot(const UBYTE *Image);
void EPD_Display_Partial(const UBYTE *Image, UWORD Xstart, UWORD Ystart, UWORD Xend, UWORD Yend);
void EPD_Display_4Gray(const UBYTE *Image);
void EPD_Sleep(void);

#ifdef __cplusplus
}
#endif



#endif // !EPAPER_PORT_H
