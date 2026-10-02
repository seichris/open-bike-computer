#ifndef __FONT_H_
#define __FONT_H_

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "sdkconfig.h"

#define CONFIG_FONT12_EMBEDDED 0
#define CONFIG_FONT16_EMBEDDED 1
#define CONFIG_FONT18_EMBEDDED 0
#define CONFIG_FONT24_EMBEDDED 0
// #define CONFIG_FONT28_EMBEDDED 1

// Font encoding type
typedef enum {
    FONT_ENCODING_UTF8 = 0,
    FONT_ENCODING_GBK = 1
} FONT_ENCODING_TYPE;

// Font structure definition
typedef struct
{
    const char *font_name_EN;      // English font file path
    const char *font_name_CH;      // The file path of Chinese fonts 
    const char *font_name_CH_ASICC; // File path of Chinese ASCII extended font
    
    uint16_t Width_EN;             // English character width
    uint16_t Width_CH;             // Chinese character width
    uint16_t Height;               // character height
    uint16_t size_EN;              // The number of English character bytes
    uint16_t size_CH;              // The number of Chinese character bytes
    FONT_ENCODING_TYPE encoding;   // encoding type
}cFONT;

// Font structure definition
typedef struct
{
    const char *font_name;      // English font file path
    
    uint16_t Width;             // English character width
    uint16_t Height;            // character height
    uint16_t size;              // The number of English character bytes
}sFONT;


// Add 12-point font to embed the data declaration
#ifdef CONFIG_FONT12_EMBEDDED
extern const uint8_t font12EN_fon_start[] asm("_binary_font12EN_FON_start");
extern const uint8_t font12EN_fon_end[] asm("_binary_font12EN_FON_end");

extern const uint8_t font12CH_utf_fon_start[] asm("_binary_UTF_font12CH_FON_start");
extern const uint8_t font12CH_utf_fon_end[] asm("_binary_UTF_font12CH_FON_end");
extern const uint8_t font12CH_ASICC_utf_fon_start[] asm("_binary_UTF_font12CH_ASICC_FON_start");
extern const uint8_t font12CH_ASICC_utf_fon_end[] asm("_binary_UTF_font12CH_ASICC_FON_end");

extern const uint8_t font12CH_gbk_fon_start[] asm("_binary_GBK_font12CH_FON_start");
extern const uint8_t font12CH_gbk_fon_end[] asm("_binary_GBK_font12CH_FON_end");
extern const uint8_t font12CH_ASICC_gbk_fon_start[] asm("_binary_GBK_font12CH_ASICC_FON_start");
extern const uint8_t font12CH_ASICC_gbk_fon_end[] asm("_binary_GBK_font12CH_ASICC_FON_end");
#endif

// Add 16-point font to embed the data declaration
#ifdef CONFIG_FONT16_EMBEDDED
extern const uint8_t font16EN_fon_start[] asm("_binary_font16EN_FON_start");
extern const uint8_t font16EN_fon_end[] asm("_binary_font16EN_FON_end");

extern const uint8_t font16CH_utf_fon_start[] asm("_binary_UTF_font16CH_FON_start");
extern const uint8_t font16CH_utf_fon_end[] asm("_binary_UTF_font16CH_FON_end");
extern const uint8_t font16CH_ASICC_utf_fon_start[] asm("_binary_UTF_font16CH_ASICC_FON_start");
extern const uint8_t font16CH_ASICC_utf_fon_end[] asm("_binary_UTF_font16CH_ASICC_FON_end");

extern const uint8_t font16CH_gbk_fon_start[] asm("_binary_GBK_font16CH_FON_start");
extern const uint8_t font16CH_gbk_fon_end[] asm("_binary_GBK_font16CH_FON_end");
extern const uint8_t font16CH_ASICC_gbk_fon_start[] asm("_binary_GBK_font16CH_ASICC_FON_start");
extern const uint8_t font16CH_ASICC_gbk_fon_end[] asm("_binary_GBK_font16CH_ASICC_FON_end");
#endif

// Add 18-point font to embed the data declaration
#ifdef CONFIG_FONT18_EMBEDDED
extern const uint8_t font18EN_fon_start[] asm("_binary_font18EN_FON_start");
extern const uint8_t font18EN_fon_end[] asm("_binary_font18EN_FON_end");

extern const uint8_t font18CH_utf_fon_start[] asm("_binary_UTF_font18CH_FON_start");
extern const uint8_t font18CH_utf_fon_end[] asm("_binary_UTF_font18CH_FON_end");
extern const uint8_t font18CH_ASICC_utf_fon_start[] asm("_binary_UTF_font18CH_ASICC_FON_start");
extern const uint8_t font18CH_ASICC_utf_fon_end[] asm("_binary_UTF_font18CH_ASICC_FON_end");

extern const uint8_t font18CH_gbk_fon_start[] asm("_binary_GBK_font18CH_FON_start");
extern const uint8_t font18CH_gbk_fon_end[] asm("_binary_GBK_font18CH_FON_end");
extern const uint8_t font18CH_ASICC_gbk_fon_start[] asm("_binary_GBK_font18CH_ASICC_FON_start");
extern const uint8_t font18CH_ASICC_gbk_fon_end[] asm("_binary_GBK_font18CH_ASICC_FON_end");
#endif

// Add 24-point font to embed the data declaration
#ifdef CONFIG_FONT24_EMBEDDED
extern const uint8_t font24EN_fon_start[] asm("_binary_font24EN_FON_start");
extern const uint8_t font24EN_fon_end[] asm("_binary_font24EN_FON_end");

extern const uint8_t font24CH_utf_fon_start[] asm("_binary_UTF_font24CH_FON_start");
extern const uint8_t font24CH_utf_fon_end[] asm("_binary_UTF_font24CH_FON_end");
extern const uint8_t font24CH_ASICC_utf_fon_start[] asm("_binary_UTF_font24CH_ASICC_FON_start");
extern const uint8_t font24CH_ASICC_utf_fon_end[] asm("_binary_UTF_font24CH_ASICC_FON_end");

extern const uint8_t font24CH_gbk_fon_start[] asm("_binary_GBK_font24CH_FON_start");
extern const uint8_t font24CH_gbk_fon_end[] asm("_binary_GBK_font24CH_FON_end");
extern const uint8_t font24CH_ASICC_gbk_fon_start[] asm("_binary_GBK_font24CH_ASICC_FON_start");
extern const uint8_t font24CH_ASICC_gbk_fon_end[] asm("_binary_GBK_font24CH_ASICC_FON_end");
#endif

// Add a 28-point font to embed the data declaration
#ifdef CONFIG_FONT28_EMBEDDED
extern const uint8_t font28EN_fon_start[] asm("_binary_font28EN_FON_start");
extern const uint8_t font28EN_fon_end[] asm("_binary_font28EN_FON_end");

extern const uint8_t font28CH_utf_fon_start[] asm("_binary_UTF_font28CH_FON_start");
extern const uint8_t font28CH_utf_fon_end[] asm("_binary_UTF_font28CH_FON_end");
extern const uint8_t font28CH_ASICC_utf_fon_start[] asm("_binary_UTF_font28CH_ASICC_FON_start");
extern const uint8_t font28CH_ASICC_utf_fon_end[] asm("_binary_UTF_font28CH_ASICC_FON_end");

extern const uint8_t font28CH_gbk_fon_start[] asm("_binary_GBK_font28CH_FON_start");
extern const uint8_t font28CH_gbk_fon_end[] asm("_binary_GBK_font28CH_FON_end");
extern const uint8_t font28CH_ASICC_gbk_fon_start[] asm("_binary_GBK_font28CH_ASICC_FON_start");
extern const uint8_t font28CH_ASICC_gbk_fon_end[] asm("_binary_GBK_font28CH_ASICC_FON_end");
#endif

// Add 36-point font to embed the data declaration
#ifdef CONFIG_FONT36_EMBEDDED
extern const uint8_t font36EN_fon_start[] asm("_binary_font36EN_FON_start");
extern const uint8_t font36EN_fon_end[] asm("_binary_font36EN_FON_end");

extern const uint8_t font36CH_utf_fon_start[] asm("_binary_UTF_font36CH_FON_start");
extern const uint8_t font36CH_utf_fon_end[] asm("_binary_UTF_font36CH_FON_end");
extern const uint8_t font36CH_ASICC_utf_fon_start[] asm("_binary_UTF_font36CH_ASICC_FON_start");
extern const uint8_t font36CH_ASICC_utf_fon_end[] asm("_binary_UTF_font36CH_ASICC_FON_end");

extern const uint8_t font36CH_gbk_fon_start[] asm("_binary_GBK_font36CH_FON_start");
extern const uint8_t font36CH_gbk_fon_end[] asm("_binary_GBK_font36CH_FON_end");
extern const uint8_t font36CH_ASICC_gbk_fon_start[] asm("_binary_GBK_font36CH_ASICC_FON_start");
extern const uint8_t font36CH_ASICC_gbk_fon_end[] asm("_binary_GBK_font36CH_ASICC_FON_end");
#endif

// Add 48-point font to embed the data declaration
#ifdef CONFIG_FONT48_EMBEDDED
extern const uint8_t font48EN_fon_start[] asm("_binary_font48EN_FON_start");
extern const uint8_t font48EN_fon_end[] asm("_binary_font48EN_FON_end");

extern const uint8_t font48CH_utf_fon_start[] asm("_binary_UTF_font48CH_FON_start");
extern const uint8_t font48CH_utf_fon_end[] asm("_binary_UTF_font48CH_FON_end");
extern const uint8_t font48CH_ASICC_utf_fon_start[] asm("_binary_UTF_font48CH_ASICC_FON_start");
extern const uint8_t font48CH_ASICC_utf_fon_end[] asm("_binary_UTF_font48CH_ASICC_FON_end");

extern const uint8_t font48CH_gbk_fon_start[] asm("_binary_GBK_font48CH_FON_start");
extern const uint8_t font48CH_gbk_fon_end[] asm("_binary_GBK_font48CH_FON_end");
extern const uint8_t font48CH_ASICC_gbk_fon_start[] asm("_binary_GBK_font48CH_ASICC_FON_start");
extern const uint8_t font48CH_ASICC_gbk_fon_end[] asm("_binary_GBK_font48CH_ASICC_FON_end");
#endif

// Add an auxiliary font embedding data declaration
#ifdef CONFIG_Auxiliary_Font_EMBEDDED
extern const uint8_t font80EN_fon_start[] asm("_binary_font80EN_FON_start");
extern const uint8_t font80EN_fon_end[] asm("_binary_font80EN_FON_end");

extern const uint8_t font182EN_fon_start[] asm("_binary_font182EN_FON_start");
extern const uint8_t font182EN_fon_end[] asm("_binary_font182EN_FON_end");
#endif



// Definition of English font file path
#define Font12EN "/Font12/font12EN.FON"
#define Font16EN "/Font16/font16EN.FON"
#define Font18EN "/Font18/font18EN.FON"
#define Font24EN "/Font24/font24EN.FON"
#define Font28EN "/Font28/font28EN.FON"
#define Font36EN "/Font36/font36EN.FON"
#define Font48EN "/Font48/font48EN.FON"

// The file path of UTF-8 Chinese font
#define UTF_Font12CH            "/Font12/UTF_font12CH.FON"
#define UTF_Font12CH_ASICC      "/Font12/UTF_font12CH_ASICC.FON"
#define UTF_Font16CH            "/Font16/UTF_font16CH.FON"
#define UTF_Font16CH_ASICC      "/Font16/UTF_font16CH_ASICC.FON"
#define UTF_Font18CH            "/Font18/UTF_font18CH.FON"
#define UTF_Font18CH_ASICC      "/Font18/UTF_font18CH_ASICC.FON"
#define UTF_Font24CH            "/Font24/UTF_font24CH.FON"
#define UTF_Font24CH_ASICC      "/Font24/UTF_font24CH_ASICC.FON"
#define UTF_Font28CH            "/Font28/UTF_font28CH.FON"
#define UTF_Font28CH_ASICC      "/Font28/UTF_font28CH_ASICC.FON"
#define UTF_Font36CH            "/Font36/UTF_font36CH.FON"
#define UTF_Font36CH_ASICC      "/Font36/UTF_font36CH_ASICC.FON"
#define UTF_Font48CH            "/Font48/UTF_font48CH.FON"
#define UTF_Font48CH_ASICC      "/Font48/UTF_font48CH_ASICC.FON"

// The file path of GBK Chinese font
#define GBK_Font12CH            "/Font12/GBK_font12CH.FON"
#define GBK_Font12CH_ASICC      "/Font12/GBK_font12CH_ASICC.FON"
#define GBK_Font16CH            "/Font16/GBK_font16CH.FON"
#define GBK_Font16CH_ASICC      "/Font16/GBK_font16CH_ASICC.FON"
#define GBK_Font18CH            "/Font18/GBK_font18CH.FON"
#define GBK_Font18CH_ASICC      "/Font18/GBK_font18CH_ASICC.FON"
#define GBK_Font24CH            "/Font24/GBK_font24CH.FON"
#define GBK_Font24CH_ASICC      "/Font24/GBK_font24CH_ASICC.FON"
#define GBK_Font28CH            "/Font28/GBK_font28CH.FON"
#define GBK_Font28CH_ASICC      "/Font28/GBK_font28CH_ASICC.FON"
#define GBK_Font36CH            "/Font36/GBK_font36CH.FON"
#define GBK_Font36CH_ASICC      "/Font36/GBK_font36CH_ASICC.FON"
#define GBK_Font48CH            "/Font48/GBK_font48CH.FON"
#define GBK_Font48CH_ASICC      "/Font48/GBK_font48CH_ASICC.FON"

// Font size definition
#define font12_Width_EN         8
#define font12_Width_CH         16
#define font12_Height           21
#define font12_size_EN          (font12_Width_EN * font12_Height / 8)
#define font12_size_CH          (font12_Width_CH * font12_Height / 8)

#define font16_Width_EN         16
#define font16_Width_CH         24
#define font16_Height           28
#define font16_size_EN          (font16_Width_EN * font16_Height / 8)
#define font16_size_CH          (font16_Width_CH * font16_Height / 8)

#define font18_Width_EN         16
#define font18_Width_CH         24
#define font18_Height           31
#define font18_size_EN          (font18_Width_EN * font18_Height / 8)
#define font18_size_CH          (font18_Width_CH * font18_Height / 8)

#define font24_Width_EN         24
#define font24_Width_CH         32
#define font24_Height           41
#define font24_size_EN          (font24_Width_EN * font24_Height / 8)
#define font24_size_CH          (font24_Width_CH * font24_Height / 8)

#define font28_Width_EN         24
#define font28_Width_CH         40
#define font28_Height           48
#define font28_size_EN          (font28_Width_EN * font28_Height / 8)
#define font28_size_CH          (font28_Width_CH * font28_Height / 8)

#define font36_Width_EN         32
#define font36_Width_CH         48
#define font36_Height           62
#define font36_size_EN          (font36_Width_EN * font36_Height / 8)
#define font36_size_CH          (font36_Width_CH * font36_Height / 8)

#define font48_Width_EN         40
#define font48_Width_CH         64
#define font48_Height           83
#define font48_size_EN          (font48_Width_EN * font48_Height / 8)
#define font48_size_CH          (font48_Width_CH * font48_Height / 8)

#define font80_Width_EN         80
#define font80_Height           106
#define font80_size_EN          (font80_Width_EN * font80_Height / 8)

#define font182_Width_EN        120
#define font182_Height          182
#define font182_size_EN         (font182_Width_EN * font182_Height / 8)

// Predefined font sample declaration
extern cFONT Font12_UTF8;
extern cFONT Font16_UTF8;
extern cFONT Font18_UTF8;
extern cFONT Font24_UTF8;
extern cFONT Font28_UTF8;
extern cFONT Font36_UTF8;
extern cFONT Font48_UTF8;

extern cFONT Font12_GBK;
extern cFONT Font16_GBK;
extern cFONT Font18_GBK;
extern cFONT Font24_GBK;
extern cFONT Font28_GBK;
extern cFONT Font36_GBK;
extern cFONT Font48_GBK;

// Compatible with the font definitions of old versions
extern sFONT Font12;
extern sFONT Font16;
extern sFONT Font18;
extern sFONT Font24;
extern sFONT Font28;
extern sFONT Font36;
extern sFONT Font48;
extern sFONT Font80;
extern sFONT Font182;

#ifdef __cplusplus
extern "C" {
#endif

// Font reading function declaration
int Get_Char_Font_Data(cFONT* font, const char* character, unsigned char* buffer);
int Get_Char_Font_Data_ASCII(sFONT* font, const char* character, unsigned char* buffer);
int Get_UTF8_Char_Length(unsigned char first_byte);
uint32_t UTF8_To_Unicode(const char* utf8_char, int* char_len);
uint32_t GBK_To_Unicode(const char* gbk_char);
void Debug_Print_String_Font(cFONT* font, const char *str);

// Compatible with older versions of the function
void Get_Str_Font(cFONT* font, const char *str);

// orientation
uint16_t reassignCoordinates_EN(uint16_t x,const char *str,sFONT* Font);
uint16_t reassignCoordinates_CH(uint16_t x, const char *str, cFONT* font);


#ifdef __cplusplus
}
#endif

#endif