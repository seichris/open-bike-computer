#ifndef _FONTS_H
#define _FONTS_H

#include "esp_err.h"
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

uint16_t utf8_char_to_gb2312(const char* utf8_char, int* char_len);
int utf8_string_to_gb2312(const char* utf8_str, char* gb2312_str, size_t gb2312_size);

#ifdef __cplusplus
}
#endif

#endif // PAGE_FONT_H