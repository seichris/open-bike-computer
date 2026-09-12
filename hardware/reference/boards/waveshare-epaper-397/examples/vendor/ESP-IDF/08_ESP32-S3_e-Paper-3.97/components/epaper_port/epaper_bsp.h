#ifndef EPAPER_PORT_H
#define EPAPER_PORT_H

#include "GUI_BMPfile.h"


#ifdef __cplusplus
extern "C" {
#endif

int EPD_display_BMP(const char *path);
int EPD_display(const UBYTE *Image);
int EPD_display_Clear(const char *path);

#ifdef __cplusplus
}
#endif


#endif // !EPAPER_PORT_H
