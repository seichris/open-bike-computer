#include "file_browser.h"
#include "esp_log.h"
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdcard_bsp.h"
#include "button_bsp.h"
#include "sdcard_bsp.h"
#include "dirent.h"
#include "page_audio.h"
#include "page_fiction.h"

#include "epaper_port.h"
#include "GUI_Paint.h"
#include "font.h"

#include "pcf85063_bsp.h"
#include "axp_prot.h"

// Icon position
#define audio           "/sdcard/GUI/audio.bmp"
#define folder          "/sdcard/GUI/folder.bmp"
#define picture         "/sdcard/GUI/picture.bmp"
#define rests           "/sdcard/GUI/rests.bmp"
#define text            "/sdcard/GUI/text.bmp"
#define BAT             "/sdcard/GUI/BAT.bmp"

// icon size
#define GUI_WIDTH       32
#define GUI_HEIGHT      32


// The default font size and font size are displayed
#define Directory_font   Font18_UTF8

// E-ink screen sleep time (S)
#define EPD_Sleep_Time   60
// Equipment shutdown time (minutes)
#define Unattended_Time  10



// Display relevant constants
#define SCREEN_WIDTH  480
#define SCREEN_HEIGHT 800
#define HEADER_HEIGHT 60    // The top path shows the height of the area
#define ITEM_HEIGHT   45    // The height of each file/directory entry
#define MARGIN_LEFT   10    // leftmargin
#define MARGIN_TOP    10    // top margin

// Define the data cache area of the e-ink screen
extern uint8_t *Image_Mono;
uint8_t *Image_Mono_fz;

extern SemaphoreHandle_t rtc_mutex;  

static const char *TAG = "file_browser";

#define MAX_Directory  5

// Save the MAX_Directory level directory, with the maximum MAX_NAME_LEN for each level directory name
static char Directory_path[MAX_Directory][MAX_NAME_LEN] = {"/sdcard"};
static char full_path[MAX_Directory * MAX_NAME_LEN];
static int num_selection[MAX_Directory] = {0}; // Selection index for each level of directory
static int page_index[MAX_Directory] = {0}; // The page numbers of each level of the table of contents

// Display time and battery level
static void display_time_bet_browser(Time_data rtc_time);
static void display_time_bet_browser_last(Time_data rtc_time);


// Determine the file type
const char* get_file_type(const char* filename)
{
    const char* ext = strrchr(filename, '.');
    if (!ext) return "unknown";
    if (strcasecmp(ext, ".txt") == 0) return "text";
    if (strcasecmp(ext, ".wav") == 0 || strcasecmp(ext, ".mp3") == 0) return "audio";
    if (strcasecmp(ext, ".jpg") == 0 || strcasecmp(ext, ".png") == 0 || strcasecmp(ext, ".bmp") == 0) return "image";
    return "unknown";
}



// Determine the encoding format of the txt file
const char* detect_txt_encoding(const char* filepath)
{
    FILE* fp = fopen(filepath, "rb");
    if (!fp) return "unknown1";
    unsigned char buf[4] = {0};
    size_t n = fread(buf, 1, 4, fp);
    fclose(fp);

    if (n >= 3 && buf[0] == 0xEF && buf[1] == 0xBB && buf[2] == 0xBF)
        return "UTF-8 BOM";
    if (n >= 2 && buf[0] == 0xFF && buf[1] == 0xFE)
        return "UTF-16 LE BOM";
    if (n >= 2 && buf[0] == 0xFE && buf[1] == 0xFF)
        return "UTF-16 BE BOM";

    // Check the characteristics of the content
    fp = fopen(filepath, "rb");
    if (!fp) return "unknown";
    int utf8_count = 0, gbk_count = 0, ascii_count = 0;
    int total = 0;
    int c;
    while ((c = fgetc(fp)) != EOF && total < 256) {
        total++;
        if (c < 0x80) {
            ascii_count++;
        } else if (c >= 0xC0 && c <= 0xF7) {
            // Check whether the subsequent bytes conform to UTF-8
            int next = fgetc(fp);
            if (next != EOF && (next & 0xC0) == 0x80) utf8_count++;
        } else if (c >= 0x81 && c <= 0xFE) {
            // GBK/GB2312 first bytes
            int next = fgetc(fp);
            if (next != EOF && next >= 0x40 && next <= 0xFE) gbk_count++;
        }
    }
    fclose(fp);

    if (utf8_count > gbk_count && utf8_count > 5) return "UTF-8";
    if (gbk_count > utf8_count && gbk_count > 5) return "GBK/GB2312";
    if (ascii_count > 0 && utf8_count == 0 && gbk_count == 0) return "ASCII/ANSI";
    return "unknown";
}


int get_page_size() {
    // Calculate the available height: total height - top area - bottom status bar
    int header_height = Directory_font.Height + 10 + MARGIN_TOP;  // The top path display area
    int status_height = Directory_font.Height * 2 + 20;          // The height of the bottom status bar
    int available_height = SCREEN_HEIGHT - header_height - status_height - MARGIN_TOP;
    
    // The height of each project
    int item_height = Directory_font.Height + 10;
    
    // Calculate the number of items that can be displayed
    int page_size = available_height / item_height;
    
    // Make sure to display at least three items and no more than a reasonable range
    if (page_size < 3) page_size = 3;
    if (page_size > 20) page_size = 20;  // Prevent abnormal situations
    
    return page_size;
}

// File browsing submenu
void file_browser_task(void)
{
    // Temporarily lower the log level
    esp_log_level_set("EPD_PAINT", ESP_LOG_WARN);
    esp_log_level_set("FONT", ESP_LOG_WARN);

    // Dynamically calculate the number of displays per page
    int page_size = get_page_size();
    if (page_size < 1) page_size = 5;

    // Allocate a large array with PSRAM to store all the files and directories in the current directory
    file_entry_t* entries = (file_entry_t*)heap_caps_malloc(page_size * sizeof(file_entry_t), MALLOC_CAP_SPIRAM);
    int Directory_count = 0; // Current directory depth
    int total_num = 0; // The total number of files in the current directory
    int num = 0;       // The number of current page files
    int button = -1;   // Key status
    bool first_display = true;  // The first display logo

    int time_count = 0;
    Time_data rtc_time = {0};
    int last_minutes = -1;

    // Auxiliary page memory application and processing
    if((Image_Mono_fz = (UBYTE *)heap_caps_malloc(EPD_SIZE_MONO,MALLOC_CAP_SPIRAM)) == NULL){
        ESP_LOGE(TAG,"Failed to apply for black memory...");
    }
    Paint_NewImage(Image_Mono_fz, SCREEN_HEIGHT, SCREEN_WIDTH, 270, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono_fz);
    Paint_Clear(WHITE);
    
    // Center the loading information
    Paint_DrawString_CN(10, 325, "该文件非TXT与音频文件", &Font24_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(10, 375, "也非文件夹", &Font24_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(10, 425, "无法打开，返回文件浏览页面", &Font24_UTF8, WHITE, BLACK);


    while (1)
    {
        // Display the loading interface
        display_loading("正在读取目录...", Partial_refresh);
        
        // Splicing the complete path
        full_path[0] = '\0';
        for (int i = 0; i <= Directory_count; ++i) {
            if (i == 0) {
                strcpy(full_path, Directory_path[0]);
            } else {
                if (full_path[strlen(full_path) - 1] != '/')
                    strcat(full_path, "/");
                strcat(full_path, Directory_path[i]);
            }
        }
        
        // Prevent unnecessary slashes
        while (strlen(full_path) > 1 && full_path[strlen(full_path) - 1] == '/')
            full_path[strlen(full_path) - 1] = '\0';
        
        ESP_LOGI("file", "current directory %s", full_path);

        // Get the total number of files in the current directory
        total_num = get_dir_file_count(full_path);
        
        // Calculate the total number of pages
        int total_pages = (total_num + page_size - 1) / page_size;
        if (total_pages == 0) total_pages = 1;

        // Read the current directory by pagination
        num = list_dir_page(full_path, entries, page_index[Directory_count] * page_size, page_size);

        // Display the file browser interface
        display_file_browser(full_path, entries, num, num_selection[Directory_count], page_index[Directory_count], total_pages, Partial_refresh);

        ESP_LOGI("file", "Page %d: Found %d entries in %s", page_index[Directory_count], num, full_path);

        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        last_minutes = rtc_time.minutes;
        
        // File/directory selection loop
        while (1)
        {
            button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
            if(button == -1) time_count++;

            if((time_count >= EPD_Sleep_Time)) {
                button = Sleep_wake();
            }

            if (button == 14) {
                // The next file/directory
                num_selection[Directory_count]++;
                if (num_selection[Directory_count] >= num) {
                    page_index[Directory_count]++;
                    if (page_index[Directory_count] * page_size >= total_num) 
                        page_index[Directory_count] = 0;
                    num = list_dir_page(full_path, entries, page_index[Directory_count] * page_size, page_size);
                    num_selection[Directory_count] = 0;
                    display_file_browser(full_path, entries, num, num_selection[Directory_count], page_index[Directory_count], total_pages, Partial_refresh);
                } else {
                    // Select to switch on the same page
                    Page_Down_browser(num_selection[Directory_count], Partial_refresh);
                }
                // ESP_LOGI("file", "%s%s", entries[num_selection[Directory_count]].name, entries[num_selection[Directory_count]].is_dir ? " [DIR]" : "");
                time_count = 0;
            } else if (button == 0) {
                // he previous file/directory
                num_selection[Directory_count]--;
                if (num_selection[Directory_count] < 0) {
                    page_index[Directory_count]--;
                    if (page_index[Directory_count] < 0) 
                        page_index[Directory_count] = total_pages - 1;
                    num = list_dir_page(full_path, entries, page_index[Directory_count] * page_size, page_size);
                    num_selection[Directory_count] = num - 1;
                    display_file_browser(full_path, entries, num, num_selection[Directory_count], page_index[Directory_count], total_pages, Partial_refresh);
                } else {
                    // Select to switch on the same page
                    Page_Up_browser(num_selection[Directory_count], Partial_refresh);
                }
                // ESP_LOGI("file", "%s%s", entries[num_selection[Directory_count]].name, entries[num_selection[Directory_count]].is_dir ? " [DIR]" : "");
                time_count = 0;
            } else if (button == 7) {
                // Enter the directory or open the file
                if (entries[num_selection[Directory_count]].is_dir && Directory_count < MAX_Directory - 1) {
                    strncpy(Directory_path[Directory_count + 1], entries[num_selection[Directory_count]].name, MAX_NAME_LEN - 1);
                    Directory_path[Directory_count + 1][MAX_NAME_LEN - 1] = '\0';
                    Directory_count++;
                    num_selection[Directory_count] = 0;
                    page_index[Directory_count] = 0;
                    break;
                } else {
                    const char* filename = entries[num_selection[Directory_count]].name;
                    char filepath[MAX_NAME_LEN * MAX_Directory + 2] = {0};
                    strcpy(filepath, full_path);
                    if (filepath[strlen(filepath) - 1] != '/')
                        strcat(filepath, "/");
                    strcat(filepath, filename);

                    if (strcasecmp(get_file_type(filename), "text") == 0) {
                        // ESP_LOGI("file", "try open: %s", filepath);
                        const char* encoding = detect_txt_encoding(filepath);
                        // ESP_LOGI("file", "open-file: %s, encoding: %s", filename, encoding);
                        page_fiction_open_file(filepath, encoding);
                    } else if (strcasecmp(get_file_type(filename), "audio") == 0) {
                        // ESP_LOGI("file", "open-file: %s", filename);
                        page_audio_play_file(filename);
                    } else {
                        // ESP_LOGI("file", "open-file: %s", filename);
                        EPD_Display_Partial(Image_Mono_fz,0,0,EPD_WIDTH,EPD_HEIGHT);
                        vTaskDelay(pdMS_TO_TICKS(1000));
                        
                    }
                    display_file_browser(full_path, entries, num, num_selection[Directory_count], page_index[Directory_count], total_pages, Partial_refresh);
                }
                time_count = 0;
            } else if (button == 12 ){
                ESP_LOGI("home", "Forced_refresh");
                Forced_refresh();
                time_count = 0;
            } else if (button == 8 || button == 22) {
                // Return 
                if (Directory_count > 0) {
                    Directory_path[Directory_count][0] = '\0';
                    num_selection[Directory_count] = 0;
                    page_index[Directory_count] = 0;
                    Directory_count--;
                    break;
                } else {
                    heap_caps_free(entries);
                    return;
                }
                time_count = 0;
            }

            xSemaphoreTake(rtc_mutex, portMAX_DELAY);
            rtc_time = PCF85063_GetTime();
            xSemaphoreGive(rtc_mutex);
            if ((rtc_time.minutes != last_minutes)  && (time_count <EPD_Sleep_Time)) {
                last_minutes = rtc_time.minutes;
                display_time_bet_browser_last(rtc_time);
                display_time_bet_browser(rtc_time);
                Refresh_page();
            }
        }
    }
}

//  Calculate the display width of the string
int calculate_display_width(const char* str) {
    int width = 0;
    int i = 0;
    
    while (str[i] != '\0') {
        unsigned char ch = (unsigned char)str[i];
        
        if (ch < 0x80) {
            width += Directory_font.Width_EN;
            i++;
        } else if ((ch & 0xE0) == 0xC0) {
            width += Directory_font.Width_CH;
            i += 2;
        } else if ((ch & 0xF0) == 0xE0) {
            width += Directory_font.Width_CH;
            i += 3;
        } else if ((ch & 0xF8) == 0xF0) {
            width += Directory_font.Width_CH;
            i += 4;
        } else {
            width += Directory_font.Width_EN;
            i++;
        }
    }
    
    return width;
}

// Truncate the string to the specified display width
void truncate_string_by_width(const char* source, char* dest, int dest_size, int max_width) {
    int current_width = 0;
    int i = 0;
    int dest_pos = 0;
    
    int ellipsis_width = Directory_font.Width_EN * 3; 
    int available_width = max_width - ellipsis_width; // Reserve space for ellipses
    
    while (source[i] != '\0' && dest_pos < dest_size - 4) { // Reserve "..." The space
        unsigned char ch = (unsigned char)source[i];
        int char_width = 0;
        int char_bytes = 1;
        
        if (ch < 0x80) {
            char_width = Directory_font.Width_EN;
            char_bytes = 1;
        } else if ((ch & 0xE0) == 0xC0) {
            char_width = Directory_font.Width_CH;
            char_bytes = 2;
        } else if ((ch & 0xF0) == 0xE0) {
            char_width = Directory_font.Width_CH;
            char_bytes = 3;
        } else if ((ch & 0xF8) == 0xF0) {
            char_width = Directory_font.Width_CH;
            char_bytes = 4;
        } else {
            char_width = Directory_font.Width_EN;
            char_bytes = 1;
        }
        
        // Check if it exceeds the available width limit
        if (current_width + char_width > available_width) {
            break;
        }
        
        // Copy characters
        for (int j = 0; j < char_bytes && source[i + j] != '\0' && dest_pos < dest_size - 4; j++) {
            dest[dest_pos++] = source[i + j];
        }
        
        current_width += char_width;
        i += char_bytes;
    }
    
    // If the original string is truncated, add an ellipsis
    if (source[i] != '\0') {
        dest[dest_pos++] = '.';
        dest[dest_pos++] = '.';
        dest[dest_pos++] = '.';
    }
    
    dest[dest_pos] = '\0';
}

// Display the file browser interface
void display_file_browser(const char* current_path, file_entry_t* entries, int num_entries, int current_selection, int page_number, int total_pages, int Refresh_mode)
{
    Paint_NewImage(Image_Mono, SCREEN_HEIGHT, SCREEN_WIDTH, 270, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);

    // Display the top path
    display_current_path(current_path);
    
    // Display file list
    display_file_list(entries, num_entries, current_selection);
    
    // Display the bottom status bar
    display_status_bar(page_number, total_pages, num_entries);
    
    // 刷新屏幕
    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(Image_Mono);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
    }
}

// Display the current path
void display_current_path(const char* path)
{
    // Draw the top divider line
    Paint_DrawLine(0, (Directory_font.Height + MARGIN_TOP ), SCREEN_WIDTH, (Directory_font.Height + MARGIN_TOP ), BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    
    int label_width = Directory_font.Width_CH * 5;
    
    // Calculate the available display width of the path (screen width - left margin - label width - right margin)
    int available_width = SCREEN_WIDTH - MARGIN_LEFT - label_width - 20;
    
    char display_path[200];
    format_path_for_display(path, display_path, sizeof(display_path), available_width);
    
    // Draw the path text
    Paint_DrawString_CN(MARGIN_LEFT, MARGIN_TOP-7, "当前位置:", &Directory_font, WHITE, BLACK);
    Paint_DrawString_CN(MARGIN_LEFT + label_width, MARGIN_TOP-7, display_path, &Directory_font, WHITE, BLACK);
}

// The formatted path is used for display
void format_path_for_display(const char* full_path, char* display_path, int display_size, int max_width)
{
    // Calculate the display width of the complete path
    int full_width = calculate_display_width(full_path);
    
    if (full_width <= max_width) {
        // The path is not long and is displayed directly
        strncpy(display_path, full_path, display_size - 1);
        display_path[display_size - 1] = '\0';
        return;
    }
    
    // The path is too long and needs to be truncated
    const char* last_slash = strrchr(full_path, '/');
    if (last_slash == NULL || last_slash == full_path) {
        truncate_string_by_width(full_path, display_path, display_size, max_width);
        return;
    }
    
    // Get the current directory name
    const char* current_dir = last_slash + 1;
    
    // Build "..." "/ Current Directory" format
    char temp_path[200];
    snprintf(temp_path, sizeof(temp_path), "../%s", current_dir);
    
    // Check "..." The display width of "/ Current directory"
    int temp_width = calculate_display_width(temp_path);
    
    if (temp_width <= max_width) {
        strncpy(display_path, temp_path, display_size - 1);
        display_path[display_size - 1] = '\0';
    } else {
        char prefix[] = "../";
        char suffix[] = "..";
        int prefix_width = calculate_display_width(prefix);
        int suffix_width = calculate_display_width(suffix);
        int available_for_dir = max_width - prefix_width - suffix_width;
        
        if (available_for_dir > 0) {
            char truncated_dir[100];
            truncate_string_by_width(current_dir, truncated_dir, sizeof(truncated_dir), available_for_dir);
            
            int len = strlen(truncated_dir);
            if (len >= 3 && strcmp(&truncated_dir[len-3], "...") == 0) {
                truncated_dir[len-3] = '\0';
            }
            
            snprintf(display_path, display_size, "../%s..", truncated_dir);
        } else {
            strncpy(display_path, "../..", display_size - 1);
            display_path[display_size - 1] = '\0';
        }
    }
}

// Display file list
void display_file_list(file_entry_t* entries, int num_entries, int current_selection)
{
    int start_y = (Directory_font.Height + 10 ) + MARGIN_TOP;
    int max_display = get_page_size();
    
    // Calculate the available display width of the file name
    int icon_width = GUI_WIDTH + 5; 
    int available_width = SCREEN_WIDTH - MARGIN_LEFT - icon_width - 20;
    
    for (int i = 0; i < num_entries && i < max_display; i++) {
        int y_pos = start_y + i * (Directory_font.Height + 10 );
        
        // Display file/directory ICONS
        if (entries[i].is_dir) {
            #if defined(CONFIG_IMG_SOURCE_EMBEDDED)
                Paint_ReadBmp(gImage_folder,MARGIN_LEFT,y_pos-1,32,32);
            #elif defined(CONFIG_IMG_SOURCE_TFCARD)
                GUI_ReadBmp(folder,MARGIN_LEFT,y_pos-1);
            #endif
        } else {
            const char* file_type = get_file_type(entries[i].name);
            if (strcmp(file_type, "text") == 0) {
                #if defined(CONFIG_IMG_SOURCE_EMBEDDED)
                    Paint_ReadBmp(gImage_text,MARGIN_LEFT,y_pos-1,32,32);
                #elif defined(CONFIG_IMG_SOURCE_TFCARD)
                    GUI_ReadBmp(text,MARGIN_LEFT,y_pos-1);
                #endif
            } else if (strcmp(file_type, "audio") == 0) {
                #if defined(CONFIG_IMG_SOURCE_EMBEDDED)
                    Paint_ReadBmp(gImage_audio,MARGIN_LEFT,y_pos-1,32,32);
                #elif defined(CONFIG_IMG_SOURCE_TFCARD)
                    GUI_ReadBmp(audio,MARGIN_LEFT,y_pos-1);
                #endif
            } else if (strcmp(file_type, "image") == 0) {
                #if defined(CONFIG_IMG_SOURCE_EMBEDDED)
                    Paint_ReadBmp(gImage_picture,MARGIN_LEFT,y_pos-1,32,32);
                #elif defined(CONFIG_IMG_SOURCE_TFCARD)
                    GUI_ReadBmp(picture,MARGIN_LEFT,y_pos-1);
                #endif
            } else {
                #if defined(CONFIG_IMG_SOURCE_EMBEDDED)
                    Paint_ReadBmp(gImage_rests,MARGIN_LEFT,y_pos-1,32,32);
                #elif defined(CONFIG_IMG_SOURCE_TFCARD)
                    GUI_ReadBmp(rests,MARGIN_LEFT,y_pos-1);
                #endif
            }
        }
        
        // Intelligently truncate file names based on display width
        char display_name[100]; 
        truncate_string_by_width(entries[i].name, display_name, sizeof(display_name), available_width);
        
        // Select the appropriate font based on the file name encoding
        if (is_chinese_filename(entries[i].name)) {
            Paint_DrawString_CN(MARGIN_LEFT + icon_width, y_pos, display_name, &Directory_font, WHITE, BLACK);
        } else {
            Paint_DrawString_EN(MARGIN_LEFT + icon_width, y_pos, display_name, &Font16, WHITE, BLACK);
        }

        // If it is the currently selected item, draw the selected background
        if (i == current_selection) {
            Paint_DrawRectangle(MARGIN_LEFT - 5, y_pos - 5, SCREEN_WIDTH - MARGIN_LEFT, y_pos + (Directory_font.Height + 10 ) - 5, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
        }
    }
}

// Display the bottom status bar
void display_status_bar(int current_page, int total_pages, int total_items)
{
    int status_y = SCREEN_HEIGHT - Directory_font.Height * 2;
    
    // Draw the bottom dividing line
    Paint_DrawLine(0, status_y - 10, SCREEN_WIDTH, status_y - 10, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    
    // Display page number information
    char page_info[50];
    snprintf(page_info, sizeof(page_info), "第%d/%d页", current_page + 1, total_pages);
    Paint_DrawString_CN(MARGIN_LEFT, status_y, page_info, &Directory_font, WHITE, BLACK);
    
    // Display the total number of files
    char count_info[50];
    snprintf(count_info, sizeof(count_info), "共%d项", total_items);
    Paint_DrawString_CN(SCREEN_WIDTH - 120, status_y, count_info, &Directory_font, WHITE, BLACK);
    
    // Display operation prompts
    Paint_DrawString_CN(MARGIN_LEFT, status_y + Directory_font.Height + 5, "↑↓:选择,单击确认:打开,双击确认:返回上级", &Font12_UTF8, WHITE, BLACK);

    // Display time and battery level
    char Time_str[16]={0};
    int BAT_Power;

    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    Time_data rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);
    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", rtc_time.hours, rtc_time.minutes);
    Paint_DrawString_EN(SCREEN_WIDTH - 120, SCREEN_HEIGHT - 5 - Font12.Height, Time_str, &Font12, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_BAT,SCREEN_WIDTH - 60, SCREEN_HEIGHT - 25,32,16);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_BAT_PATH,SCREEN_WIDTH - 60, SCREEN_HEIGHT - 25);
#endif
    BAT_Power = get_battery_power();
    // ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawRectangle(SCREEN_WIDTH - 55, SCREEN_HEIGHT - 20, SCREEN_WIDTH - 55 + BAT_Power, SCREEN_HEIGHT - 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(SCREEN_WIDTH - 55, SCREEN_HEIGHT - 20, SCREEN_WIDTH - 55 + BAT_Power, SCREEN_HEIGHT - 12, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
}

// Display time and battery level
static void display_time_bet_browser_last(Time_data rtc_time)
{
    char Time_str[16]={0};
    int BAT_Power;

    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", rtc_time.hours, rtc_time.minutes-1);
    Paint_DrawString_EN(SCREEN_WIDTH - 120, SCREEN_HEIGHT - 5 - Font12.Height, Time_str, &Font12, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_BAT,SCREEN_WIDTH - 60, SCREEN_HEIGHT - 25,32,16);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_BAT_PATH,SCREEN_WIDTH - 60, SCREEN_HEIGHT - 25);
#endif
    BAT_Power = get_battery_power();
    // ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawRectangle(SCREEN_WIDTH - 55, SCREEN_HEIGHT - 20, SCREEN_WIDTH - 55 + BAT_Power, SCREEN_HEIGHT - 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(SCREEN_WIDTH - 55, SCREEN_HEIGHT - 20, SCREEN_WIDTH - 55 + BAT_Power, SCREEN_HEIGHT - 12, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
}
static void display_time_bet_browser(Time_data rtc_time)
{
    char Time_str[16]={0};
    int BAT_Power;

    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", rtc_time.hours, rtc_time.minutes);
    Paint_DrawString_EN(SCREEN_WIDTH - 120, SCREEN_HEIGHT - 5 - Font12.Height, Time_str, &Font12, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_BAT,SCREEN_WIDTH - 60, SCREEN_HEIGHT - 25,32,16);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_BAT_PATH,SCREEN_WIDTH - 60, SCREEN_HEIGHT - 25);
#endif
    BAT_Power = get_battery_power();
    // ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawRectangle(SCREEN_WIDTH - 55, SCREEN_HEIGHT - 20, SCREEN_WIDTH - 55 + BAT_Power, SCREEN_HEIGHT - 12, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(SCREEN_WIDTH - 55, SCREEN_HEIGHT - 20, SCREEN_WIDTH - 55 + BAT_Power, SCREEN_HEIGHT - 12, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
}

// Determine whether the file name contains Chinese characters
bool is_chinese_filename(const char* filename)
{
    for (int i = 0; filename[i]; i++) {
        if ((unsigned char)filename[i] > 127) {
            return true;
        }
    }
    return false;
}

// Display the loading interface
void display_loading(const char* message, int Refresh_mode)
{
    Paint_NewImage(Image_Mono, SCREEN_HEIGHT, SCREEN_WIDTH, 270, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
    
    int text_x = (SCREEN_WIDTH - strlen(message) * 16) / 2;
    int text_y = SCREEN_HEIGHT / 2;
    
    Paint_DrawString_CN(text_x, text_y, message, &Font24_UTF8, BLACK, WHITE);
    
    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(Image_Mono);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
    }
}


// UUpper and lower selection processing
void Page_Down_browser(int current_selection, int Refresh_mode)
{
    int start_y = (Directory_font.Height + 10 ) + MARGIN_TOP;

    int y_pos_old = start_y + (current_selection - 1) * (Directory_font.Height + 10 );
    int y_pos_new = start_y + current_selection * (Directory_font.Height + 10 );
    
    Paint_DrawRectangle(MARGIN_LEFT - 5, y_pos_old - 5, SCREEN_WIDTH - MARGIN_LEFT, y_pos_old + (Directory_font.Height + 10 ) - 5, WHITE, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);

    Paint_DrawRectangle(MARGIN_LEFT - 5, y_pos_new - 5, SCREEN_WIDTH - MARGIN_LEFT, y_pos_new + (Directory_font.Height + 10 ) - 5, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(Image_Mono);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
    }
}
void Page_Up_browser(int current_selection, int Refresh_mode)
{
    int start_y = (Directory_font.Height + 10 ) + MARGIN_TOP;

    int y_pos_old = start_y + (current_selection + 1) * (Directory_font.Height + 10 );
    int y_pos_new = start_y + current_selection * (Directory_font.Height + 10 );
    
    Paint_DrawRectangle(MARGIN_LEFT - 5, y_pos_old - 5, SCREEN_WIDTH - MARGIN_LEFT, y_pos_old + (Directory_font.Height + 10 ) - 5, WHITE, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);

    Paint_DrawRectangle(MARGIN_LEFT - 5, y_pos_new - 5, SCREEN_WIDTH - MARGIN_LEFT, y_pos_new + (Directory_font.Height + 10 ) - 5, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(Image_Mono);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
    }
}

// E-paper refresh
void Forced_refresh(void)
{
    EPD_Display_Base(Image_Mono);
}
void Refresh_page(void)
{
    EPD_Display_Partial(Image_Mono,0,0,EPD_WIDTH,EPD_HEIGHT);
}

// Sleep-wake function
int Sleep_wake(void)
{
    int button = 0;
    int sleep_js = 0;
    Time_data rtc_time = {0};
    int last_minutes = -1;
    ESP_LOGI("home", "EPD_Sleep");
    EPD_Sleep();
    while(1)
    {
        button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        if (button == 12){
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            // Forced_refresh_audio(Image_Mono);
            break;
        } else if (button == 8 || button == 22 || button == 14 || button == 0 || button == 7){
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            Refresh_page();
            break;
        } 
        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        if(rtc_time.minutes != last_minutes) {
            last_minutes = rtc_time.minutes;
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            // display_time_last(rtc_time);
            Refresh_page();
            display_time_bet_browser(rtc_time);
            Refresh_page();
            ESP_LOGI("home", "EPD_Sleep");
            EPD_Sleep();
            sleep_js++;
            if(sleep_js > Unattended_Time){
                ESP_LOGI("home", "pwr_off");
                axp_pwr_off();
            }
        }
    }
    return button;
}
