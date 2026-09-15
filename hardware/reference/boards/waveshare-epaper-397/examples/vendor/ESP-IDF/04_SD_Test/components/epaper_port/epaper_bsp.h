#ifndef EPAPER_PORT_H
#define EPAPER_PORT_H

#include "GUI_BMPfile.h"


#ifdef __cplusplus
extern "C" {
#endif

int EPD_display_BMP();
int EPD_display(const UBYTE *Image);
int EPD_display_Clear();

#ifdef __cplusplus
}
#endif


#endif // !EPAPER_PORT_H
