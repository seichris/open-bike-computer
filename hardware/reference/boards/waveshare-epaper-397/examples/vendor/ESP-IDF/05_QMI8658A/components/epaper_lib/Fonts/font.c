/*****************************************
 * To speed up the program execution, the vast majority of the logs in this file have been commented out. If you need to debug, please uncomment as needed
******************************************/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "font.h"
#include "fonts.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

static const char *TAG = "FONT";
// Predefined font instance
cFONT Font12_UTF8 = {
    .font_name_EN = Font12EN,
    .font_name_CH = UTF_Font12CH,
    .font_name_CH_ASICC = UTF_Font12CH_ASICC,
    .Width_EN = font12_Width_EN,
    .Width_CH = font12_Width_CH,
    .Height = font12_Height,
    .size_EN = font12_size_EN,
    .size_CH = font12_size_CH,
    .encoding = FONT_ENCODING_UTF8
};

cFONT Font16_UTF8 = {
    .font_name_EN = Font16EN,
    .font_name_CH = UTF_Font16CH,
    .font_name_CH_ASICC = UTF_Font16CH_ASICC,
    .Width_EN = font16_Width_EN,
    .Width_CH = font16_Width_CH,
    .Height = font16_Height,
    .size_EN = font16_size_EN,
    .size_CH = font16_size_CH,
    .encoding = FONT_ENCODING_UTF8
};

cFONT Font18_UTF8 = {
    .font_name_EN = Font18EN,
    .font_name_CH = UTF_Font18CH,
    .font_name_CH_ASICC = UTF_Font18CH_ASICC,
    .Width_EN = font18_Width_EN,
    .Width_CH = font18_Width_CH,
    .Height = font18_Height,
    .size_EN = font18_size_EN,
    .size_CH = font18_size_CH,
    .encoding = FONT_ENCODING_UTF8
};

cFONT Font24_UTF8 = {
    .font_name_EN = Font24EN,
    .font_name_CH = UTF_Font24CH,
    .font_name_CH_ASICC = UTF_Font24CH_ASICC,
    .Width_EN = font24_Width_EN,
    .Width_CH = font24_Width_CH,
    .Height = font24_Height,
    .size_EN = font24_size_EN,
    .size_CH = font24_size_CH,
    .encoding = FONT_ENCODING_UTF8
};

cFONT Font28_UTF8 = {
    .font_name_EN = Font28EN,
    .font_name_CH = UTF_Font28CH,
    .font_name_CH_ASICC = UTF_Font28CH_ASICC,
    .Width_EN = font28_Width_EN,
    .Width_CH = font28_Width_CH,
    .Height = font28_Height,
    .size_EN = font28_size_EN,
    .size_CH = font28_size_CH,
    .encoding = FONT_ENCODING_UTF8
};

cFONT Font36_UTF8 = {
    .font_name_EN = Font36EN,
    .font_name_CH = UTF_Font36CH,
    .font_name_CH_ASICC = UTF_Font36CH_ASICC,
    .Width_EN = font36_Width_EN,
    .Width_CH = font36_Width_CH,
    .Height = font36_Height,
    .size_EN = font36_size_EN,
    .size_CH = font36_size_CH,
    .encoding = FONT_ENCODING_UTF8
};

cFONT Font48_UTF8 = {
    .font_name_EN = Font48EN,
    .font_name_CH = UTF_Font48CH,
    .font_name_CH_ASICC = UTF_Font48CH_ASICC,
    .Width_EN = font48_Width_EN,
    .Width_CH = font48_Width_CH,
    .Height = font48_Height,
    .size_EN = font48_size_EN,
    .size_CH = font48_size_CH,
    .encoding = FONT_ENCODING_UTF8
};

// Definition in GB2312
cFONT Font12_GBK = {
    .font_name_EN = Font12EN,
    .font_name_CH = GBK_Font12CH,
    .font_name_CH_ASICC = GBK_Font12CH_ASICC,
    .Width_EN = font12_Width_EN,
    .Width_CH = font12_Width_CH,
    .Height = font12_Height,
    .size_EN = font12_size_EN,
    .size_CH = font12_size_CH,
    .encoding = FONT_ENCODING_GBK
};

cFONT Font16_GBK = {
    .font_name_EN = Font16EN,
    .font_name_CH = GBK_Font16CH,
    .font_name_CH_ASICC = GBK_Font16CH_ASICC,
    .Width_EN = font16_Width_EN,
    .Width_CH = font16_Width_CH,
    .Height = font16_Height,
    .size_EN = font16_size_EN,
    .size_CH = font16_size_CH,
    .encoding = FONT_ENCODING_GBK
};

cFONT Font18_GBK = {
    .font_name_EN = Font18EN,
    .font_name_CH = GBK_Font18CH,
    .font_name_CH_ASICC = GBK_Font18CH_ASICC,
    .Width_EN = font18_Width_EN,
    .Width_CH = font18_Width_CH,
    .Height = font18_Height,
    .size_EN = font18_size_EN,
    .size_CH = font18_size_CH,
    .encoding = FONT_ENCODING_GBK
};

cFONT Font24_GBK = {
    .font_name_EN = Font24EN,
    .font_name_CH = GBK_Font24CH,
    .font_name_CH_ASICC = GBK_Font24CH_ASICC,
    .Width_EN = font24_Width_EN,
    .Width_CH = font24_Width_CH,
    .Height = font24_Height,
    .size_EN = font24_size_EN,
    .size_CH = font24_size_CH,
    .encoding = FONT_ENCODING_GBK
};

cFONT Font28_GBK = {
    .font_name_EN = Font28EN,
    .font_name_CH = GBK_Font28CH,
    .font_name_CH_ASICC = GBK_Font28CH_ASICC,
    .Width_EN = font28_Width_EN,
    .Width_CH = font28_Width_CH,
    .Height = font28_Height,
    .size_EN = font28_size_EN,
    .size_CH = font28_size_CH,
    .encoding = FONT_ENCODING_GBK
};

cFONT Font36_GBK = {
    .font_name_EN = Font36EN,
    .font_name_CH = GBK_Font36CH,
    .font_name_CH_ASICC = GBK_Font36CH_ASICC,
    .Width_EN = font36_Width_EN,
    .Width_CH = font36_Width_CH,
    .Height = font36_Height,
    .size_EN = font36_size_EN,
    .size_CH = font36_size_CH,
    .encoding = FONT_ENCODING_GBK
};

cFONT Font48_GBK = {
    .font_name_EN = Font48EN,
    .font_name_CH = GBK_Font48CH,
    .font_name_CH_ASICC = GBK_Font48CH_ASICC,
    .Width_EN = font48_Width_EN,
    .Width_CH = font48_Width_CH,
    .Height = font48_Height,
    .size_EN = font48_size_EN,
    .size_CH = font48_size_CH,
    .encoding = FONT_ENCODING_GBK
};

// Pure English definition
sFONT Font12 = {
    .font_name = Font12EN,
    .Width = font12_Width_EN,
    .Height = font12_Height,
    .size = font12_size_EN
};

sFONT Font16 = {
    .font_name = Font16EN,
    .Width = font16_Width_EN,
    .Height = font16_Height,
    .size = font16_size_EN
};

sFONT Font18 = {
    .font_name = Font18EN,
    .Width = font18_Width_EN,
    .Height = font18_Height,
    .size = font18_size_EN
};

sFONT Font24 = {
    .font_name = Font24EN,
    .Width = font24_Width_EN,
    .Height = font24_Height,
    .size = font24_size_EN
};

sFONT Font28 = {
    .font_name = Font28EN,
    .Width = font28_Width_EN,
    .Height = font28_Height,
    .size = font28_size_EN
};

sFONT Font36 = {
    .font_name = Font36EN,
    .Width = font36_Width_EN,
    .Height = font36_Height,
    .size = font36_size_EN
};

sFONT Font48 = {
    .font_name = Font48EN,
    .Width = font48_Width_EN,
    .Height = font48_Height,
    .size = font48_size_EN
};

// A unified function for obtaining embedded font data
static bool get_embedded_font_data(cFONT* font, const char* file_type, const uint8_t** data_start, size_t* data_size) 
{
    const uint8_t* start = NULL;
    const uint8_t* end = NULL;
    
    // Select the corresponding embedded data based on the font size and type
    if (strcmp(file_type, "EN") == 0) {
        // ASCII font (shared by all encodings)
        if (font->size_EN == font12_size_EN) {
#ifdef CONFIG_FONT12_EMBEDDED
            start = font12EN_fon_start;
            end = font12EN_fon_end;
#endif
        } else if (font->size_EN == font16_size_EN) {
#ifdef CONFIG_FONT16_EMBEDDED
            start = font16EN_fon_start;
            end = font16EN_fon_end;
#endif
        } else if (font->size_EN == font18_size_EN) {
#ifdef CONFIG_FONT18_EMBEDDED
            start = font18EN_fon_start;
            end = font18EN_fon_end;
#endif
        } else if (font->size_EN == font24_size_EN) {
#ifdef CONFIG_FONT24_EMBEDDED
            start = font24EN_fon_start;
            end = font24EN_fon_end;
#endif
        } else if (font->size_EN == font28_size_EN) {
#ifdef CONFIG_FONT28_EMBEDDED
            start = font28EN_fon_start;
            end = font28EN_fon_end;
#endif
        } else if (font->size_EN == font36_size_EN) {
#ifdef CONFIG_FONT36_EMBEDDED
            start = font36EN_fon_start;
            end = font36EN_fon_end;
#endif
        } else if (font->size_EN == font48_size_EN) {
#ifdef CONFIG_FONT48_EMBEDDED
            start = font48EN_fon_start;
            end = font48EN_fon_end;
#endif
        }
        
    } else if (strcmp(file_type, "CH") == 0) {
        // Chinese script
        if (font->encoding == FONT_ENCODING_UTF8) {
            // UTF-8
            if (font->size_CH == font12_size_CH) {
#ifdef CONFIG_FONT12_EMBEDDED
                start = font12CH_utf_fon_start;
                end = font12CH_utf_fon_end;
#endif
            } else if (font->size_CH == font16_size_CH) {
#ifdef CONFIG_FONT16_EMBEDDED
                start = font16CH_utf_fon_start;
                end = font16CH_utf_fon_end;
#endif
            } else if (font->size_CH == font18_size_CH) {
#ifdef CONFIG_FONT18_EMBEDDED
                start = font18CH_utf_fon_start;
                end = font18CH_utf_fon_end;
#endif
            } else if (font->size_CH == font24_size_CH) {
#ifdef CONFIG_FONT24_EMBEDDED
                start = font24CH_utf_fon_start;
                end = font24CH_utf_fon_end;
#endif
            } else if (font->size_CH == font28_size_CH) {
#ifdef CONFIG_FONT28_EMBEDDED
                start = font28CH_utf_fon_start;
                end = font28CH_utf_fon_end;
#endif
            } else if (font->size_CH == font36_size_CH) {
#ifdef CONFIG_FONT36_EMBEDDED
                start = font36CH_utf_fon_start;
                end = font36CH_utf_fon_end;
#endif
            } else if (font->size_CH == font48_size_CH) {
#ifdef CONFIG_FONT48_EMBEDDED
                start = font48CH_utf_fon_start;
                end = font48CH_utf_fon_end;
#endif
            }
        } else {
            // GBK
            if (font->size_CH == font12_size_CH) {
#ifdef CONFIG_FONT12_EMBEDDED
                start = font12CH_gbk_fon_start;
                end = font12CH_gbk_fon_end;
#endif
            } else if (font->size_CH == font16_size_CH) {
#ifdef CONFIG_FONT16_EMBEDDED
                start = font16CH_gbk_fon_start;
                end = font16CH_gbk_fon_end;
#endif
            } else if (font->size_CH == font18_size_CH) {
#ifdef CONFIG_FONT18_EMBEDDED
                start = font18CH_gbk_fon_start;
                end = font18CH_gbk_fon_end;
#endif
            } else if (font->size_CH == font24_size_CH) {
#ifdef CONFIG_FONT24_EMBEDDED
                start = font24CH_gbk_fon_start;
                end = font24CH_gbk_fon_end;
#endif
            } else if (font->size_CH == font28_size_CH) {
#ifdef CONFIG_FONT28_EMBEDDED
                start = font28CH_gbk_fon_start;
                end = font28CH_gbk_fon_end;
#endif
            } else if (font->size_CH == font36_size_CH) {
#ifdef CONFIG_FONT36_EMBEDDED
                start = font36CH_gbk_fon_start;
                end = font36CH_gbk_fon_end;
#endif
            } else if (font->size_CH == font48_size_CH) {
#ifdef CONFIG_FONT48_EMBEDDED
                start = font48CH_gbk_fon_start;
                end = font48CH_gbk_fon_end;
#endif
            }
        }
        
    } else if (strcmp(file_type, "CH_ASICC") == 0) {
        // symbol font
        if (font->encoding == FONT_ENCODING_UTF8) {
            // UTF-8
            if (font->size_CH == font12_size_CH) {
#ifdef CONFIG_FONT12_EMBEDDED
                start = font12CH_ASICC_utf_fon_start;
                end = font12CH_ASICC_utf_fon_end;
#endif
            } else if (font->size_CH == font16_size_CH) {
#ifdef CONFIG_FONT16_EMBEDDED
                start = font16CH_ASICC_utf_fon_start;
                end = font16CH_ASICC_utf_fon_end;
#endif
            } else if (font->size_CH == font18_size_CH) {
#ifdef CONFIG_FONT18_EMBEDDED
                start = font18CH_ASICC_utf_fon_start;
                end = font18CH_ASICC_utf_fon_end;
#endif
            } else if (font->size_CH == font24_size_CH) {
#ifdef CONFIG_FONT24_EMBEDDED
                start = font24CH_ASICC_utf_fon_start;
                end = font24CH_ASICC_utf_fon_end;
#endif
            } else if (font->size_CH == font28_size_CH) {
#ifdef CONFIG_FONT28_EMBEDDED
                start = font28CH_ASICC_utf_fon_start;
                end = font28CH_ASICC_utf_fon_end;
#endif
            } else if (font->size_CH == font36_size_CH) {
#ifdef CONFIG_FONT36_EMBEDDED
                start = font36CH_ASICC_utf_fon_start;
                end = font36CH_ASICC_utf_fon_end;
#endif
            } else if (font->size_CH == font48_size_CH) {
#ifdef CONFIG_FONT48_EMBEDDED
                start = font48CH_ASICC_utf_fon_start;
                end = font48CH_ASICC_utf_fon_end;
#endif
            }
        } else {
            // GBK
            if (font->size_CH == font12_size_CH) {
#ifdef CONFIG_FONT12_EMBEDDED
                start = font12CH_ASICC_gbk_fon_start;
                end = font12CH_ASICC_gbk_fon_end;
#endif
            } else if (font->size_CH == font16_size_CH) {
#ifdef CONFIG_FONT16_EMBEDDED
                start = font16CH_ASICC_gbk_fon_start;
                end = font16CH_ASICC_gbk_fon_end;
#endif
            } else if (font->size_CH == font18_size_CH) {
#ifdef CONFIG_FONT18_EMBEDDED
                start = font18CH_ASICC_gbk_fon_start;
                end = font18CH_ASICC_gbk_fon_end;
#endif
            } else if (font->size_CH == font24_size_CH) {
#ifdef CONFIG_FONT24_EMBEDDED
                start = font24CH_ASICC_gbk_fon_start;
                end = font24CH_ASICC_gbk_fon_end;
#endif
            } else if (font->size_CH == font28_size_CH) {
#ifdef CONFIG_FONT28_EMBEDDED
                start = font28CH_ASICC_gbk_fon_start;
                end = font28CH_ASICC_gbk_fon_end;
#endif
            } else if (font->size_CH == font36_size_CH) {
#ifdef CONFIG_FONT36_EMBEDDED
                start = font36CH_ASICC_gbk_fon_start;
                end = font36CH_ASICC_gbk_fon_end;
#endif
            } else if (font->size_CH == font48_size_CH) {
#ifdef CONFIG_FONT48_EMBEDDED
                start = font48CH_ASICC_gbk_fon_start;
                end = font48CH_ASICC_gbk_fon_end;
#endif
            }
        }
    }
    if (start && end) {
        *data_start = start;
        *data_size = end - start;
        // ESP_LOGD(TAG, "Use the embedded font: type =%s, encoding =%s, size =%zu bytes", file_type, (font->encoding == FONT_ENCODING_UTF8) ? "UTF-8" : "GBK", (size_t)(end - start));
        return true;
    }
    // ESP_LOGD(TAG, "Embedded font not available: type =%s, encoding =%s", file_type, (font->encoding == FONT_ENCODING_UTF8) ? "UTF-8" : "GBK");
    return false;
}

// Embedded font support
int Get_Char_Font_Data(cFONT* font, const char* character, unsigned char* buffer)
{
    FILE* file = NULL;
    uint32_t font_offset = 0;
    int char_len = 1;
    
    // Determine the character encoding and length
    if (font->encoding == FONT_ENCODING_UTF8) {
        char_len = Get_UTF8_Char_Length((unsigned char)character[0]);
    } else { // GBK/GB2312
        char_len = ((unsigned char)character[0] < 0x80) ? 1 : 2;
    }
    
    // ASCII Character Processing (Half-width)
    if (char_len == 1 && (unsigned char)character[0] < 0x80) {
        if ((unsigned char)character[0] < 0x20) {
            // ESP_LOGW(TAG, "Unsupported ASCII control characters: 0x%02X", (unsigned char)character[0]);
            return -1;
        }
        
        font_offset = ((unsigned char)character[0] - 0x20) * font->size_EN;
        
        // Try using embedded data
        const uint8_t* embedded_data = NULL;
        size_t embedded_size = 0;
        
        if (get_embedded_font_data(font, "EN", &embedded_data, &embedded_size)) {
            if (font_offset + font->size_EN <= embedded_size) {
                memcpy(buffer, embedded_data + font_offset, font->size_EN);
                // ESP_LOGD(TAG, "Read embedded ASCII characters: '%c'(0x%02X), offset=%lu", character[0], (unsigned char)character[0], (unsigned long)font_offset);
                return font->size_EN;
            } else {
                // ESP_LOGE(TAG, "The embedded ASCII character offset is out of range");
            }
        }

#if defined(CONFIG_FONT_ENABLE_SDCARD) || defined(CONFIG_FONT_ENABLE_TFCARD)
        file = fopen(font->font_name_EN, "rb");
        if (!file) {
            ESP_LOGE(TAG, "The English font file cannot be opened: %s", font->font_name_EN);
            return -1;
        }
        
        fseek(file, font_offset, SEEK_SET);
        size_t read_size = fread(buffer, 1, font->size_EN, file);
        fclose(file);
        
        if (read_size != font->size_EN) {
            // ESP_LOGE(TAG, "Failed to read ASCII character data");
            return -1;
        }
        // ESP_LOGD(TAG, "Read the ASCII characters of the file: '%c'(0x%02X), offset=%lu", character[0], (unsigned char)character[0], (unsigned long)font_offset);
        return font->size_EN;
#else
        // ESP_LOGE(TAG, "The font embedding failed and file rollback was disabled");
        return -1;
#endif
    }
    const char* font_file = NULL;
    const char* file_type = NULL;
    
    if (font->encoding == FONT_ENCODING_UTF8) {
        // UTF-8
        int char_len_check = 0;
        uint32_t unicode = UTF8_To_Unicode(character, &char_len_check);
        
        if (unicode >= 0xFF01 && unicode <= 0xFF5E) {
            // Full-width ASCII characters
            font_offset = (unicode - 0xFF00) * font->size_CH;
            font_file = font->font_name_CH_ASICC;
            file_type = "CH_ASICC";
            // ESP_LOGD(TAG, "UTF-8 full-width ASCII: unicode=0x%04X", (unsigned int)unicode);
            
        } else if (unicode >= 0x4E00 && unicode <= 0x9FFF) {
            // Common Chinese Character Zone
            font_offset = (unicode - 0x4E00) * font->size_CH;
            font_file = font->font_name_CH;
            file_type = "CH";
            // ESP_LOGD(TAG, "UTF-8 Chinese characters: unicode=0x%04X", (unsigned int)unicode);
            
        } else {
            // ESP_LOGW(TAG, "UTF-8 characters are beyond the supported range: unicode=0x%04X", (unsigned int)unicode);
            extern uint16_t utf8_char_to_gb2312(const char* utf8_char, int* char_len);
            int char_len_tmp = 0;
            uint16_t gb_code = utf8_char_to_gb2312(character, &char_len_tmp);
            if (gb_code != 0) {
                unsigned char byte1 = (gb_code >> 8) & 0xFF;
                unsigned char byte2 = gb_code & 0xFF;
                uint32_t gb_code_offset = ((byte1 - 0xA1) * 94 + (byte2 - 0xA1));
                font_offset = gb_code_offset * font->size_CH;

                switch (font->size_CH) {
                    case font12_size_CH: font_file = GBK_Font12CH_ASICC; break;
                    case font16_size_CH: font_file = GBK_Font16CH_ASICC; break;
                    case font18_size_CH: font_file = GBK_Font18CH_ASICC; break;
                    case font24_size_CH: font_file = GBK_Font24CH_ASICC; break;
                    case font28_size_CH: font_file = GBK_Font28CH_ASICC; break;
                    case font36_size_CH: font_file = GBK_Font36CH_ASICC; break;
                    case font48_size_CH: font_file = GBK_Font48CH_ASICC; break;
                    default: font_file = font->font_name_CH_ASICC; break;
                }
                file_type = "CH_ASICC";

                const uint8_t* embedded_data = NULL;
                size_t embedded_size = 0;
                
                if (font->size_CH == font18_size_CH && 
                    get_embedded_font_data(&Font18_GBK, file_type, &embedded_data, &embedded_size)) {
                    if (font_offset + font->size_CH <= embedded_size) {
                        memcpy(buffer, embedded_data + font_offset, font->size_CH);
                        // ESP_LOGD(TAG, "Embedded special symbols: UTF-8->GB2312: 0x%04X, offset=%lu", gb_code, (unsigned long)font_offset);
                        return font->size_CH;
                    }
                }
                
#if defined(CONFIG_FONT_ENABLE_SDCARD) || defined(CONFIG_FONT_ENABLE_TFCARD)
                file = fopen(font_file, "rb");
                if (!file) {
                    ESP_LOGE(TAG, "The symbol font file cannot be opened: %s", font_file);
                    return -1;
                }
                fseek(file, font_offset, SEEK_SET);
                size_t read_size = fread(buffer, 1, font->size_CH, file);
                fclose(file);
                if (read_size != font->size_CH) {
                    // ESP_LOGE(TAG, "Failed to read the symbol font data");
                    return -1;
                }
                // ESP_LOGD(TAG, "Special symbols for documents: UTF-8->GB2312: 0x%04X, offset=%lu", gb_code, (unsigned long)font_offset);
                return font->size_CH;
#endif
            }
            return -1;
        }
        
    } else {
        // GBK/GB2312
        unsigned char byte1 = (unsigned char)character[0];
        unsigned char byte2 = (unsigned char)character[1];
        
        if (byte1 >= 0xA1 && byte1 <= 0xA9 && byte2 >= 0xA1 && byte2 <= 0xFE) {
            // Full-width ASCII and symbol areas
            uint32_t gb_code = ((byte1 - 0xA1) * 94 + (byte2 - 0xA1));
            font_offset = gb_code * font->size_CH;
            font_file = font->font_name_CH_ASICC;
            file_type = "CH_ASICC";
            // ESP_LOGD(TAG, "GBK full-width characters: 0x%02X%02X, code=%lu", byte1, byte2, (unsigned long)gb_code);
            
        } else if (byte1 >= 0xB0 && byte1 <= 0xF7 && byte2 >= 0xA1 && byte2 <= 0xFE) {
            // Chinese character area
            uint32_t gb_code = ((byte1 - 0xB0) * 94 + (byte2 - 0xA1));
            font_offset = gb_code * font->size_CH;
            font_file = font->font_name_CH;
            file_type = "CH";
            // ESP_LOGD(TAG, "Chinese character area: 0x%02X%02X, code=%lu", byte1, byte2, (unsigned long)gb_code);
            
        } else {
            // ESP_LOGW(TAG, "The GBK characters are beyond the valid range: 0x%02X%02X", byte1, byte2);
            return -1;
        }
    }
    
    // Try embedded data
    const uint8_t* embedded_data = NULL;
    size_t embedded_size = 0;
    
    if (get_embedded_font_data(font, file_type, &embedded_data, &embedded_size)) {
        if (font_offset + font->size_CH <= embedded_size) {
            memcpy(buffer, embedded_data + font_offset, font->size_CH);
            ESP_LOGD(TAG, "Embedded character reading successful: encoding =%s, offset=%lu, size=%d", (font->encoding == FONT_ENCODING_UTF8) ? "UTF-8" : "GBK", (unsigned long)font_offset, font->size_CH);
            return font->size_CH;
        }
    }
    
#if defined(CONFIG_FONT_ENABLE_SDCARD) || defined(CONFIG_FONT_ENABLE_TFCARD)
    file = fopen(font_file, "rb");
    if (!file) {
        ESP_LOGE(TAG, "The font file cannot be opened: %s", font_file);
        return -1;
    }
    
    fseek(file, font_offset, SEEK_SET);
    size_t read_size = fread(buffer, 1, font->size_CH, file);
    fclose(file);
    
    if (read_size != font->size_CH) {
        ESP_LOGE(TAG, "Failed to read character data");
        return -1;
    }
    
    // ESP_LOGD(TAG, "File character reading successful: encoding =%s, offset=%lu, size=%d", (font->encoding == FONT_ENCODING_UTF8) ? "UTF-8" : "GBK", (unsigned long)font_offset, font->size_CH);
    return font->size_CH;
#else
    // ESP_LOGE(TAG, "The font embedding failed and file rollback was disabled");
    return -1;
#endif
}

// ASCII font data acquisition function
static bool get_embedded_font_data_ASCII(sFONT* font, const uint8_t** data_start, size_t* data_size)
{
    const uint8_t* start = NULL;
    const uint8_t* end = NULL;

    if (!font || !data_start || !data_size) return false;

    if (font->size == font12_size_EN) {
#ifdef CONFIG_FONT12_EMBEDDED
        start = font12EN_fon_start;
        end   = font12EN_fon_end;
#endif
    } else if (font->size == font16_size_EN) {
#ifdef CONFIG_FONT16_EMBEDDED
        start = font16EN_fon_start;
        end   = font16EN_fon_end;
#endif
    } else if (font->size == font18_size_EN) {
#ifdef CONFIG_FONT18_EMBEDDED
        start = font18EN_fon_start;
        end   = font18EN_fon_end;
#endif
    } else if (font->size == font24_size_EN) {
#ifdef CONFIG_FONT24_EMBEDDED
        start = font24EN_fon_start;
        end   = font24EN_fon_end;
#endif
    } else if (font->size == font28_size_EN) {
#ifdef CONFIG_FONT28_EMBEDDED
        start = font28EN_fon_start;
        end   = font28EN_fon_end;
#endif
    } else if (font->size == font36_size_EN) {
#ifdef CONFIG_FONT36_EMBEDDED
        start = font36EN_fon_start;
        end   = font36EN_fon_end;
#endif
    } else if (font->size == font48_size_EN) {
#ifdef CONFIG_FONT48_EMBEDDED
        start = font48EN_fon_start;
        end   = font48EN_fon_end;
#endif
    } else {
        #ifdef CONFIG_FONT48_EMBEDDED
        if (font->size == font80_size_EN) {
            start = Font80EN_fon_start;
            end   = Font80EN_fon_end;
        } else if (font->size == font182_size_EN) {
            start = Font182EN_fon_start;
            end   = Font182EN_fon_end;
        }
        #endif
    }

    if (start && end && end > start) {
        *data_start = start;
        *data_size  = (size_t)(end - start);
        // ESP_LOGD(TAG, "Use embedded ASCII fonts: size=%zu bytes", *data_size);
        return true;
    }
    // ESP_LOGD(TAG, "The embedded ASCII font is unavailable: need size_EN=%u", (unsigned)font->size);
    return false;
}

// Obtain the font data of a single ASCII character
int Get_Char_Font_Data_ASCII(sFONT* font, const char* character, unsigned char* buffer)
{
    FILE* file = NULL;
    uint32_t font_offset = 0;
    unsigned char ch;
    const uint8_t* embedded_data = NULL;
    size_t embedded_size = 0;

    if (!font || !character || !buffer) {
        ESP_LOGE(TAG, "Get_Char_Font_Data_ASCII: parameter error");
        return -1;
    }

    ch = (unsigned char)character[0];
    if (ch < 0x20) {
        ESP_LOGW(TAG, "Unsupported ASCII control characters: 0x%02X", ch);
        return -1;
    }

    font_offset = (uint32_t)(ch - 0x20) * (uint32_t)font->size;
    if (get_embedded_font_data_ASCII(font, &embedded_data, &embedded_size)) {
        if ((size_t)font_offset + (size_t)font->size <= embedded_size) {
            memcpy(buffer, embedded_data + font_offset, font->size);
            // ESP_LOGD(TAG, "Read embedded ASCII characters: '%c'(0x%02X), offset=%u", ch, ch, (unsigned)font_offset);
            return (int)font->size;
        } else {
            // ESP_LOGW(TAG, "The embedded ASCII character offset is out of range: offset=%u need=%u avail=%u", (unsigned)font_offset, (unsigned)font->size, (unsigned)(embedded_size - font_offset));
        }
    } else {
        // ESP_LOGD(TAG, "The embedded ASCII font was not found. Try file rollback");
    }

#if defined(CONFIG_FONT_ENABLE_SDCARD) || defined(CONFIG_FONT_ENABLE_TFCARD)
    file = fopen(font->font_name, "rb");
    if (!file) {
        ESP_LOGE(TAG, "The English font file cannot be opened: %s", font->font_name);
        return -1;
    }
    if (fseek(file, (long)font_offset, SEEK_SET) != 0) {
        ESP_LOGE(TAG, "fseek failed: %s offset=%u", font->font_name, (unsigned)font_offset);
        fclose(file);
        return -1;
    }
    size_t read_size = fread(buffer, 1, font->size, file);
    fclose(file);
    if (read_size != (size_t)font->size) {
        ESP_LOGE(TAG, "Failed to read ASCII character data: read=%u expected=%u", (unsigned)read_size, (unsigned)font->size);
        return -1;
    }
    // ESP_LOGD(TAG, "Read ASCII characters from the file: '%c'(0x%02X), offset=%u", ch, ch, (unsigned)font_offset);
    return (int)font->size;
#else
    // ESP_LOGE(TAG, "The embedded font is unavailable and SD/TF card rollback is not enabled: %s", font->font_name);
    return -1;
#endif
}

// Obtain the UTF-8 character length
int Get_UTF8_Char_Length(unsigned char first_byte)
{
    if (first_byte < 0x80) return 1;      // ASCII
    if ((first_byte & 0xE0) == 0xC0) return 2; // 110xxxxx
    if ((first_byte & 0xF0) == 0xE0) return 3; // 1110xxxx
    if ((first_byte & 0xF8) == 0xF0) return 4; // 11110xxx
    return 1; // By default, it is processed as a single byte
}

// UTF-8 To Unicode
uint32_t UTF8_To_Unicode(const char* utf8_char, int* char_len)
{
    uint32_t unicode = 0;
    unsigned char* bytes = (unsigned char*)utf8_char;
    
    *char_len = Get_UTF8_Char_Length(bytes[0]);
    switch(*char_len) {
        case 1:
            unicode = bytes[0];
            break;
        case 2:
            unicode = ((bytes[0] & 0x1F) << 6) | (bytes[1] & 0x3F);
            break;
        case 3:
            unicode = ((bytes[0] & 0x0F) << 12) | ((bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F);
            break;
        case 4:
            unicode = ((bytes[0] & 0x07) << 18) | ((bytes[1] & 0x3F) << 12) | ((bytes[2] & 0x3F) << 6) | (bytes[3] & 0x3F);
            break;
    }
    
    return unicode;
}

// The computing center displays the location
uint16_t reassignCoordinates_EN(uint16_t x,const char *str,sFONT* Font)
{
  uint16_t x_or;
  uint16_t len = strlen(str);
  uint16_t str_len = Font->Width * len / 2;
  x_or = x - str_len;
  return x_or;
}

uint16_t reassignCoordinates_CH(uint16_t x, const char *str, cFONT* font)
{
    uint16_t x_or;
    uint16_t len = 0;
    uint16_t str_len = 0;
    uint16_t char_len = 0;
    const char* p = str;
    while (*p != '\0')
    {
        if (font->encoding == FONT_ENCODING_UTF8) {
            char_len = Get_UTF8_Char_Length((unsigned char)*p);
        } else {
            char_len = (*p < 0x80) ? 1 : 2;
        }
        len = len + char_len;
        p += char_len;
        if(char_len == 1) {
            str_len = str_len + font->Width_EN;
        } else {
            str_len = str_len + font->Width_CH;
        }
    }
    x_or = x - str_len/2;
    return x_or;
}

















