#include "page_fiction.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_system.h"
#include "esp_log.h"
#include "button_bsp.h"
#include "sdcard_bsp.h"
#include <string.h>
#include <stdlib.h>
#include "dirent.h"

#include "epaper_port.h"
#include "GUI_BMPfile.h"
#include "GUI_Paint.h"
#include "pcf85063_bsp.h"
#include "axp_prot.h"

#include <nvs.h>
#include <nvs_flash.h>

// Add a screen size definition
#define SCREEN_WIDTH  480
#define SCREEN_HEIGHT 800
// The maximum number of characters per page
#define MAX_PAGE_CONTENT 2048

#define Default_font FONT_SIZE_18  // default font

// E-ink screen sleep time (S)
#define EPD_Sleep_Time   60
// Equipment shutdown time (minutes)
#define Unattended_Time  10

// Icon position
#define file            "/sdcard/GUI/file.bmp"
#define rests           "/sdcard/GUI/rests.bmp"
// icon size
#define GUI_WIDTH       32
#define GUI_HEIGHT      32

#define HEADER_HEIGHT 65    // The top path shows the height of the area
#define ITEM_HEIGHT   45    // The height of each file/directory entry
#define MARGIN_LEFT   10    // leftmargin
#define MARGIN_TOP    10    // top margin

extern SemaphoreHandle_t rtc_mutex;   // Protect RTC
extern bool wifi_enable;                       // Is the wifi turned on?

static const char *TAG = "page_fiction";

// Add external variables and function declarations
extern uint8_t *Image_Mono;  // External image buffer
extern int wait_key_event_and_return_code(uint32_t timeout);  // Key detection function

uint8_t *Image_Fiction;


// Global context
static fiction_context_t g_fiction_ctx = {0};
static fiction_display_context_t g_display_ctx = {0};

// File system/font access mutex to prevent assertions caused by simultaneous fopen of multiple tasks
static SemaphoreHandle_t fs_access_mutex = NULL;

// font table
static cFONT* utf8_font_table[FONT_SIZE_MAX] = {
    &Font12_UTF8,  // FONT_SIZE_12
    &Font16_UTF8,  // FONT_SIZE_16 
    &Font18_UTF8,  // FONT_SIZE_18
    &Font24_UTF8,  // FONT_SIZE_24
    &Font28_UTF8,  // FONT_SIZE_28
    &Font36_UTF8,  // FONT_SIZE_36
    &Font48_UTF8,  // FONT_SIZE_48
};

static cFONT* gbk_font_table[FONT_SIZE_MAX] = {
    &Font12_GBK,   // FONT_SIZE_12
    &Font16_GBK,   // FONT_SIZE_16 
    &Font18_GBK,   // FONT_SIZE_18
    &Font24_GBK,   // FONT_SIZE_24
    &Font28_GBK,   // FONT_SIZE_28
    &Font36_GBK,   // FONT_SIZE_36
    &Font48_GBK,   // FONT_SIZE_48
};

static const char* font_names[FONT_SIZE_MAX] = {
    "12号字体", "16号字体", "18号字体", "24号字体", "28号字体", "36号字体", "48号字体"
};

static const char* font_names_1[FONT_SIZE_MAX] = {
    "12号", "16号", "18号", "24号", "28号", "36号", "48号"
};


static uint8_t* bookmark_display_buffer = NULL;  // Bookmark display cache
static uint8_t* bookmark_preview_buffer = NULL;  // Bookmark preview cache
static uint8_t* page_backup_buffer = NULL;       // Page backup cache

// Novel cache area
char lines_char[25][256] = {0};
static bool lines_char_bool = 0;

// Add a function declaration for calculating display parameters
void calculate_display_params(void);
extern bool is_chinese_filename(const char* filename);

// NVS namespace and key names
#define NVS_NS_FICTION "fiction_cfg"
#define NVS_KEY_FONTIDX "font_idx"

// Save the font index to NVS (font is the font_size_t enumeration)
esp_err_t save_font_size_to_nvs(font_size_t font)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS_FICTION, NVS_READWRITE, &h);
    if (err != ESP_OK) {
        ESP_LOGE("fiction", "nvs_open(write) failed: %s", esp_err_to_name(err));
        return err;
    }
    // It uses int32 storage and has good compatibility
    int32_t v = (int32_t)font;
    err = nvs_set_i32(h, NVS_KEY_FONTIDX, v);
    if (err != ESP_OK) {
        ESP_LOGE("fiction", "nvs_set_i32 failed: %s", esp_err_to_name(err));
        nvs_close(h);
        return err;
    }
    err = nvs_commit(h);
    if (err != ESP_OK) {
        ESP_LOGE("fiction", "nvs_commit failed: %s", esp_err_to_name(err));
    } else {
        ESP_LOGI("fiction", "saved font idx to NVS: %d",(int)v);
    }
    nvs_close(h);
    return err;
}

// Read the font index from NVS, successfully return ESP_OK and write the result to font_out
esp_err_t load_font_size_from_nvs(font_size_t *font_out)
{
    if (!font_out) return ESP_ERR_INVALID_ARG;
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS_FICTION, NVS_READONLY, &h);
    if (err != ESP_OK) {
        ESP_LOGW("fiction", "nvs_open(read) failed: %s", esp_err_to_name(err));
        return err;
    }
    int32_t v = 0;
    err = nvs_get_i32(h, NVS_KEY_FONTIDX, &v);
    nvs_close(h);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI("fiction", "no saved font idx in NVS");
        return ESP_ERR_NOT_FOUND;
    } else if (err != ESP_OK) {
        ESP_LOGE("fiction", "nvs_get_i32 failed: %s", esp_err_to_name(err));
        return err;
    }
    if (v < 0 || v >= FONT_SIZE_MAX) {
        ESP_LOGW("fiction", "saved font idx out of range: %d, reset to default",(int)v);
        *font_out = FONT_SIZE_18; 
    } else {
        *font_out = (font_size_t)v;
    }
    ESP_LOGI("fiction", "loaded font idx from NVS: %d",(int)v);
    return ESP_OK;
}


// Simple GBK to UTF-8 conversion (only for common Chinese characters)
void simple_gbk_to_utf8(const char* gbk_str, char* utf8_str, int max_len)
{
    strncpy(utf8_str, gbk_str, max_len - 1);
    utf8_str[max_len - 1] = '\0';
}

// Get a preview of the content at the current location
void fiction_get_content_preview(fiction_context_t* ctx, char* preview, int max_len)
{
    FILE* fp = fopen(ctx->filepath, "rb");
    if (!fp) {
        strncpy(preview, "无法获取内容", max_len - 1);
        preview[max_len - 1] = '\0';
        return;
    }
    fseek(fp, ctx->current_position, SEEK_SET);
    
    char buffer[256];
    char temp_preview[256] = {0};
    int total_len = 0;
    
    // Read a few lines as a preview
    for (int lines = 0; lines < 3 && total_len < sizeof(temp_preview) - 1; lines++) {
        if (fgets(buffer, sizeof(buffer), fp)) {
            char* newline = strchr(buffer, '\n');
            if (newline) *newline = '\0';
            if (strlen(buffer) == 0) {
                lines--; 
                continue;
            }
            
            int remaining = sizeof(temp_preview) - 1 - total_len;
            if (remaining > 0) {
                if (total_len > 0) {
                    strncat(temp_preview, " ", remaining);
                    total_len++;
                    remaining--;
                }
                strncat(temp_preview, buffer, remaining);
                total_len += strlen(buffer) < remaining ? strlen(buffer) : remaining;
            }
        } else {
            break;
        }
    }
    
    fclose(fp);
    
    if (strcmp(ctx->encoding, "GBK/GB2312") == 0) {
        simple_gbk_to_utf8(temp_preview, preview, max_len);
    } else {
        strncpy(preview, temp_preview, max_len - 1);
        preview[max_len - 1] = '\0';
    }
    
    if (strlen(preview) >= max_len - 4) {
        strcpy(preview + max_len - 4, "...");
    }
}

// Create a bookmark directory
void create_bookmark_directory()
{
    char bookmark_dir[] = "/sdcard/bookmarks";
    
    // Check if the directory exists
    DIR* dir = opendir(bookmark_dir);
    if (dir) {
        closedir(dir);
        ESP_LOGI(TAG, "Bookmark directory exists: %s", bookmark_dir);
        return;
    }
    
    // The directory does not exist. Try to create it
    ESP_LOGI(TAG, "Creating bookmark directory: %s", bookmark_dir);
    char temp_file[300];
    snprintf(temp_file, sizeof(temp_file), "%s/.keep", bookmark_dir);
    FILE* fp = fopen(temp_file, "w");
    if (fp) {
        fprintf(fp, "bookmark directory marker\n");
        fclose(fp);
        ESP_LOGI(TAG, "Created bookmark directory successfully");
    } else {
        ESP_LOGE(TAG, "Failed to create bookmark directory");
    }
}

// Get the path of the bookmark file
void get_bookmark_filepath(const char* txt_filepath, char* bookmark_filepath, int max_len)
{
    const char* filename = strrchr(txt_filepath, '/');
    if (filename) {
        filename++; 
    } else {
        filename = txt_filepath;
    }
    
    // Create the bookmark file path: /sdcard/bookmarks/ filene.bookmarks
    snprintf(bookmark_filepath, max_len, "/sdcard/bookmarks/%s.bookmarks", filename);
}

// Save the bookmarks to the unified directory
void fiction_save_bookmarks(const fiction_context_t* ctx)
{
    create_bookmark_directory();
    
    char bookmark_file[MAX_FILEPATH_LEN + 32];
    get_bookmark_filepath(ctx->filepath, bookmark_file, sizeof(bookmark_file));
    
    FILE* fp = fopen(bookmark_file, "w");
    if (fp) {
        fprintf(fp, "# Bookmarks for: %s\n", ctx->filepath);
        fprintf(fp, "%d\n", ctx->bookmark_count);
        
        for (int i = 0; i < ctx->bookmark_count; i++) {
            fprintf(fp, "%zu %d %.2f %s %s\n", 
                    ctx->bookmarks[i].position, 
                    ctx->bookmarks[i].page,
                    ctx->bookmarks[i].progress,
                    ctx->bookmarks[i].description,
                    ctx->bookmarks[i].content_preview);
        }
        fclose(fp);
        ESP_LOGI(TAG, "Bookmarks saved to: %s (%d bookmarks)", bookmark_file, ctx->bookmark_count);
    } else {
        ESP_LOGE(TAG, "Failed to save bookmarks to: %s", bookmark_file);
    }
}

// Load bookmarks from the unified directory
void fiction_load_bookmarks(fiction_context_t* ctx)
{
    char bookmark_file[MAX_FILEPATH_LEN + 32];
    get_bookmark_filepath(ctx->filepath, bookmark_file, sizeof(bookmark_file));
    
    FILE* fp = fopen(bookmark_file, "r");
    if (fp) {
        char line[256];
        // Skip the comment line
        if (fgets(line, sizeof(line), fp) && line[0] == '#') {
        } else {
            fseek(fp, 0, SEEK_SET);
        }
        
        if (fscanf(fp, "%d\n", &ctx->bookmark_count) == 1) {
            if (ctx->bookmark_count > MAX_BOOKMARKS) ctx->bookmark_count = MAX_BOOKMARKS;
            
            for (int i = 0; i < ctx->bookmark_count; i++) {
                if (fscanf(fp, "%zu %d %f %63s %127[^\n]\n", 
                          &ctx->bookmarks[i].position, 
                          &ctx->bookmarks[i].page,
                          &ctx->bookmarks[i].progress,
                          ctx->bookmarks[i].description,
                          ctx->bookmarks[i].content_preview) != 5) {
                    ctx->bookmark_count = i;
                    break;
                }
            }
        }
        fclose(fp);
        ESP_LOGI(TAG, "Bookmarks loaded from: %s (%d bookmarks)", bookmark_file, ctx->bookmark_count);
    } else {
        ctx->bookmark_count = 0;
        ESP_LOGI(TAG, "No bookmark file found: %s", bookmark_file);
    }
}

// Modify progress save (Enhanced Debugging version)
void fiction_save_progress(const fiction_context_t* ctx)
{
    if (!ctx->is_open) {
        ESP_LOGW(TAG, "Cannot save progress: file not open");
        return;
    }
    
    // Make sure the directory exists
    create_bookmark_directory();
    
    // Extract the file name
    const char* filename = strrchr(ctx->filepath, '/');
    if (filename) {
        filename++;
    } else {
        filename = ctx->filepath;
    }
    
    char progress_file[MAX_FILEPATH_LEN + 32];
    snprintf(progress_file, sizeof(progress_file), "/sdcard/bookmarks/%s.progress", filename);
    
    ESP_LOGI(TAG, "Saving progress to: %s", progress_file);
    ESP_LOGI(TAG, "Progress data: pos=%zu, page=%d", ctx->current_position, ctx->current_page);
    
    FILE* fp = fopen(progress_file, "w");
    if (fp) {
        fprintf(fp, "# Progress for: %s\n", ctx->filepath);
        fprintf(fp, "%zu\n%d\n", ctx->current_position, ctx->current_page);
        fclose(fp);
        ESP_LOGI(TAG, "Progress saved successfully");
    } else {
        ESP_LOGE(TAG, "Failed to save progress file: %s", progress_file);
    }
}

// Progress loading
bool fiction_load_progress(fiction_context_t* ctx)
{
    create_bookmark_directory();
    const char* filename = strrchr(ctx->filepath, '/');
    if (filename) {
        filename++;
    } else {
        filename = ctx->filepath;
    }
    
    char progress_file[MAX_FILEPATH_LEN + 32];
    snprintf(progress_file, sizeof(progress_file), "/sdcard/bookmarks/%s.progress", filename);
    
    ESP_LOGI(TAG, "Trying to load progress from: %s", progress_file);
    
    FILE* fp = fopen(progress_file, "r");
    if (fp) {
        ESP_LOGI(TAG, "Progress file opened successfully");
        
        char line[256];
        if (fgets(line, sizeof(line), fp)) {
            ESP_LOGI(TAG, "First line: %s", line);
            if (line[0] != '#') {
                fseek(fp, 0, SEEK_SET);
            }
        }
        
        size_t pos;
        int page;
        if (fscanf(fp, "%zu\n%d\n", &pos, &page) == 2) {
            ctx->current_position = pos;
            ctx->current_page = page;
            fclose(fp);
            ESP_LOGI(TAG, "Progress loaded successfully: pos=%zu, page=%d", pos, page);
            return true;
        } else {
            ESP_LOGE(TAG, "Failed to parse progress file");
        }
        fclose(fp);
    } else {
        ESP_LOGI(TAG, "Progress file not found: %s", progress_file);
    }

    ctx->current_position = 0;
    ctx->current_page = 0;
    ESP_LOGI(TAG, "Starting from beginning: pos=0, page=0");
    return false;
}

// add bookmark
void fiction_add_bookmark(fiction_context_t* ctx)
{
    if (ctx->bookmark_count >= MAX_BOOKMARKS) {
        ESP_LOGW(TAG, "Maximum bookmarks reached, replacing oldest");
        // Delete the oldest bookmark and add a new one
        for (int i = 0; i < MAX_BOOKMARKS - 1; i++) {
            ctx->bookmarks[i] = ctx->bookmarks[i + 1];
        }
        ctx->bookmark_count = MAX_BOOKMARKS - 1;
    }
    
    // Percentage of calculation progress
    float progress = (float)ctx->current_position * 100.0f / ctx->file_size;
    
    // Get content preview
    char preview[128];
    fiction_get_content_preview(ctx, preview, sizeof(preview));
    
    // Add the current position as a bookmark
    ctx->bookmarks[ctx->bookmark_count].position = ctx->current_position;
    ctx->bookmarks[ctx->bookmark_count].page = ctx->current_page;
    ctx->bookmarks[ctx->bookmark_count].progress = progress;
    snprintf(ctx->bookmarks[ctx->bookmark_count].description, 64, "第%d页", ctx->current_page + 1);
    strncpy(ctx->bookmarks[ctx->bookmark_count].content_preview, preview, 127);
    ctx->bookmarks[ctx->bookmark_count].content_preview[127] = '\0';
    
    ctx->bookmark_count++;
    fiction_save_bookmarks(ctx);
    ESP_LOGI(TAG, "Bookmark added at page %d (%.1f%%): %s",  ctx->current_page + 1, progress, preview);
}

// Display the bookmark operation options
void fiction_show_bookmark_options(fiction_context_t* ctx, int bookmark_index, int option_selection)
{
    ESP_LOGI(TAG, "=== Bookmark operation ===");
    ESP_LOGI(TAG, "Select the bookmark: Bookmark %d (%.1f%%, page %d)", bookmark_index + 1, ctx->bookmarks[bookmark_index].progress, ctx->bookmarks[bookmark_index].page + 1);
    
    ESP_LOGI(TAG, "%s 1. Jump to this sign", (option_selection == 0) ? ">" : " ");
    ESP_LOGI(TAG, "%s 2. Delete this signature", (option_selection == 1) ? ">" : " ");
    ESP_LOGI(TAG, "%s 3. Return to the bookmark list", (option_selection == 2) ? ">" : " ");
    ESP_LOGI(TAG, "Use the up/down key to select, the confirm key to execute, and the cancel key to return");
}

// Display bookmark list
void fiction_show_bookmarks(fiction_context_t* ctx, int selected_index)
{
    if (ctx->bookmark_count == 0) {
        ESP_LOGI(TAG, "No bookmarks for now");
        return;
    }
    
    ESP_LOGI(TAG, "=== Bookmark list (%d) ===", ctx->bookmark_count);
    for (int i = 0; i < ctx->bookmark_count; i++) {
        const char* marker = (i == selected_index) ? ">" : " ";
        
        char safe_preview[32];
        strncpy(safe_preview, ctx->bookmarks[i].content_preview, sizeof(safe_preview) - 1);
        safe_preview[sizeof(safe_preview) - 1] = '\0';
        
        ESP_LOGI(TAG, "%s %d: Bookmark %d (%.1f%%, page %d)", marker, i + 1, i + 1, ctx->bookmarks[i].progress, ctx->bookmarks[i].page + 1);
    }
    ESP_LOGI(TAG, "Use the up/down keys to select, the confirm key to operate, and the cancel key to exit");
}


// Delete bookmarks
void fiction_delete_bookmark(fiction_context_t* ctx, int bookmark_index)
{
    if (bookmark_index < 0 || bookmark_index >= ctx->bookmark_count) {
        ESP_LOGE(TAG, "Invalid bookmark index: %d", bookmark_index);
        return;
    }
    
    ESP_LOGI(TAG, "Delete bookmark: %s (page %d)", ctx->bookmarks[bookmark_index].content_preview, ctx->bookmarks[bookmark_index].page + 1);
    
    // Move the subsequent bookmarks forward to cover them
    for (int i = bookmark_index; i < ctx->bookmark_count - 1; i++) {
        ctx->bookmarks[i] = ctx->bookmarks[i + 1];
    }
    
    ctx->bookmark_count--;
    fiction_save_bookmarks(ctx);
    ESP_LOGI(TAG, "The bookmarks have been deleted. There are still %d bookmarks left", ctx->bookmark_count);
}

// Jump to Bookmarks
bool fiction_jump_to_bookmark(fiction_context_t* ctx, int bookmark_index)
{
    if (bookmark_index < 0 || bookmark_index >= ctx->bookmark_count) {
        ESP_LOGE(TAG, "Invalid bookmark index: %d", bookmark_index);
        return false;
    }
    
    ctx->current_position = ctx->bookmarks[bookmark_index].position;
    ctx->current_page = ctx->bookmarks[bookmark_index].page;
    
    ESP_LOGI(TAG, "Jump to bookmark %d: %.1f%%, page %d", bookmark_index + 1, ctx->bookmarks[bookmark_index].progress, ctx->current_page + 1);
    ESP_LOGI(TAG, "Content: %s", ctx->bookmarks[bookmark_index].content_preview);
    return true;
}

// Read a page of content
bool fiction_read_page(fiction_context_t* ctx, char lines[][MAX_LINE_LENGTH], int* line_count)
{
    if (!ctx->is_open) return false;
    
    FILE* fp = fopen(ctx->filepath, "rb");
    if (!fp) {
        ESP_LOGE(TAG, "Failed to open file: %s", ctx->filepath);
        return false;
    }
    
    // Locate to the current position
    fseek(fp, ctx->current_position, SEEK_SET);
    
    *line_count = 0;
    char buffer[MAX_LINE_LENGTH * 2];
    
    while (*line_count < LINES_PER_PAGE && fgets(buffer, sizeof(buffer), fp)) {
        if (strcmp(ctx->encoding, "GBK/GB2312") == 0) {
            strncpy(lines[*line_count], buffer, MAX_LINE_LENGTH - 1);
        } else if (strstr(ctx->encoding, "UTF-8")) {
            strncpy(lines[*line_count], buffer, MAX_LINE_LENGTH - 1);
        } else {
            strncpy(lines[*line_count], buffer, MAX_LINE_LENGTH - 1);
        }
        
        lines[*line_count][MAX_LINE_LENGTH - 1] = '\0';
        
        char* newline = strchr(lines[*line_count], '\n');
        if (newline) *newline = '\0';
        
        if (strlen(lines[*line_count]) > 0) {
            (*line_count)++;
        }
    }
    ctx->current_position = ftell(fp);
    fclose(fp);
    
    return (*line_count > 0);
}

// closed file
void fiction_close_file(fiction_context_t* ctx)
{
    if (ctx->is_open) {
        fiction_save_progress(ctx);
        ctx->is_open = false;
        ESP_LOGI(TAG, "Fiction file closed");
    }
}

// Open the novel file
void page_fiction_open_file(const char* filepath, const char* encoding)
{
    const char* detected_encoding = encoding;
    if (is_chinese_filename(filepath)) {
        detected_encoding = "GBK/GB2312";
    }

    if (g_fiction_ctx.is_open) {
        fiction_close_file(&g_fiction_ctx);
    }
    
    // Initialize the context
    memset(&g_fiction_ctx, 0, sizeof(g_fiction_ctx));
    strncpy(g_fiction_ctx.filepath, filepath, MAX_FILEPATH_LEN - 1);
    // strncpy(g_fiction_ctx.encoding, encoding, sizeof(g_fiction_ctx.encoding) - 1);
    strncpy(g_fiction_ctx.encoding, detected_encoding, sizeof(g_fiction_ctx.encoding) - 1);
    ESP_LOGI(TAG, "File encoding set to: %s", g_fiction_ctx.encoding);
    
    // Get the file size
    FILE* fp = fopen(filepath, "rb");
    if (!fp) {
        ESP_LOGE(TAG, "Failed to open file: %s", filepath);
        return;
    }
    fseek(fp, 0, SEEK_END);
    g_fiction_ctx.file_size = ftell(fp);
    fclose(fp);
    
    g_fiction_ctx.is_open = true;
    
    // Load the reading progress
    fiction_load_progress(&g_fiction_ctx);
    fiction_load_bookmarks(&g_fiction_ctx);
    
    ESP_LOGI(TAG, "Fiction opened: %s, encoding: %s, size: %zu bytes", filepath, encoding, g_fiction_ctx.file_size);
    
    // Start the novel reading task
    page_fiction_task();
}


// Obtain the corresponding font based on the code
cFONT* get_font_by_encoding(font_size_t font_size, const char* encoding) {
    if (font_size >= FONT_SIZE_MAX) return &Font16_UTF8;
    
    if (strstr(encoding, "GBK") || strstr(encoding, "GB2312")) {
        ESP_LOGI(TAG, "Using GBK font: %s", font_names[font_size]);
        return gbk_font_table[font_size];
    } else {
        ESP_LOGI(TAG, "Using UTF-8 font: %s", font_names[font_size]);
        return utf8_font_table[font_size];
    }
}

void Forced_refresh_fiction(const uint8_t* button)
{
    EPD_Display_Base(button);
}
void Forced_Refresh_page_fiction(const uint8_t* button)
{
    EPD_Display_Partial(button,0,0,EPD_WIDTH,EPD_HEIGHT);
}
static int Sleep_wake_fiction(const bool font_menu_mode, const bool bookmark_mode, const bool bookmark_action_mode)
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
            break;
        } else if (button == 8 || button == 22 || button == 14 || button == 0 || button == 7 || button == 15 || button == 1){
            // 初始化
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            if (!font_menu_mode && !bookmark_mode && !bookmark_action_mode) {
                Forced_Refresh_page_fiction(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer);
                ESP_LOGI(TAG, "Time/battery updated in reading mode");
            } else if (bookmark_mode && !bookmark_action_mode) {
                // display_time_bet_fiction(bookmark_display_buffer);
                Forced_Refresh_page_fiction(bookmark_display_buffer);
                ESP_LOGI(TAG, "Time/battery updated in bookmark mode");
            } else if (bookmark_action_mode) {
                // display_time_bet_fiction(bookmark_preview_buffer);
                Forced_Refresh_page_fiction(bookmark_preview_buffer);
                ESP_LOGI(TAG, "Time/battery updated in bookmark action mode");
            }
            break;
        } 
        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        if(rtc_time.minutes != last_minutes) {
            last_minutes = rtc_time.minutes;
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            if (!font_menu_mode && !bookmark_mode && !bookmark_action_mode) {
                Forced_Refresh_page_fiction(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer);
                display_time_bet_fiction(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer);
                Forced_Refresh_page_fiction(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer);
                ESP_LOGI(TAG, "Time/battery updated in reading mode");
            } else if (bookmark_mode && !bookmark_action_mode) {
                Forced_Refresh_page_fiction(bookmark_display_buffer);
                Paint_SelectImage(bookmark_display_buffer);
                display_time_bet_fiction(bookmark_display_buffer);
                Forced_Refresh_page_fiction(bookmark_display_buffer);
                ESP_LOGI(TAG, "Time/battery updated in bookmark mode");
            } else if (bookmark_action_mode) {
                Forced_Refresh_page_fiction(bookmark_preview_buffer);
                Paint_SelectImage(bookmark_preview_buffer);
                display_time_bet_fiction(bookmark_preview_buffer);
                Forced_Refresh_page_fiction(bookmark_preview_buffer);
                ESP_LOGI(TAG, "Time/battery updated in bookmark action mode");
            }
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


// The main task is to read novels
void page_fiction_task(void)
{
    if (!g_fiction_ctx.is_open) {
        ESP_LOGE(TAG, "No fiction file opened");
        return;
    }

    // Initialize the display system
    init_fiction_display_buffers();
    init_bookmark_display_buffers();

    display_loading_fiction("小说加载中...",Partial_refresh);
    
    // Set the display context
    strncpy(g_display_ctx.filepath, g_fiction_ctx.filepath, sizeof(g_display_ctx.filepath) - 1);
    strncpy(g_display_ctx.encoding, g_fiction_ctx.encoding, sizeof(g_display_ctx.encoding) - 1);
    g_display_ctx.file_size = g_fiction_ctx.file_size;
    g_display_ctx.current_position = g_fiction_ctx.current_position;
    g_display_ctx.current_page = g_fiction_ctx.current_page;
    g_display_ctx.is_open = true;
    
    int button = -1;
    bool font_menu_mode = false;
    font_size_t font_menu_selection = g_display_ctx.current_font_size;
    bool bookmark_mode = false;
    bool bookmark_action_mode = false;
    int bookmark_selection = 0;
    int option_selection = 0;

    int time_count = 0;
    Time_data rtc_time = {0};
    int last_minutes = -1;
    
    // Display the first page
    display_current_page();
    
    ESP_LOGI(TAG, "Fiction display started with bookmark support");

    rtc_time = PCF85063_GetTime();
    last_minutes = rtc_time.minutes;
    
    while (1) {
        button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
        if(button == -1) time_count++;
        if(time_count >= EPD_Sleep_Time) {
            button = Sleep_wake_fiction(font_menu_mode,bookmark_mode,bookmark_action_mode);
        }
        if (font_menu_mode) {
            // Font selection mode
            switch (button) {
                case 14: // The next font
                    {
                        int temp = (int)font_menu_selection + 1;
                        if (temp >= FONT_SIZE_MAX) {
                            temp = 0;
                        }
                        font_menu_selection = (font_size_t)temp;
                    }
                    display_font_menu(font_menu_selection);
                    time_count = 0;
                    break;
                    
                case 0: // The previous font
                    {
                        int temp = (int)font_menu_selection - 1;
                        if (temp < 0) {
                            temp = FONT_SIZE_MAX - 1;
                        }
                        font_menu_selection = (font_size_t)temp;
                    }
                    display_font_menu(font_menu_selection);
                    time_count = 0;
                    break;
                    
                case 7: // Apply style font size
                    switch_font_size(font_menu_selection);
                    font_menu_mode = false;
                    display_current_page();
                    ESP_LOGI(TAG, "Font applied: %s", font_names[font_menu_selection]);
                    time_count = 0;
                    break;
                    
                case 8: // 取消
                case 22:
                    font_menu_mode = false;
                    display_current_page();
                    time_count = 0;
                    break;
            }
        } else if (bookmark_action_mode) {
            // Bookmark operation mode
            switch (button) {
                case 14: // The next option
                    option_selection++;
                    if (option_selection > 2) option_selection = 0;
                    display_bookmark_action_menu_on_screen_Down(option_selection, Partial_refresh);
                    time_count = 0;
                    break;
                    
                case 0: // Previous option
                    option_selection--;
                    if (option_selection < 0) option_selection = 2;
                    display_bookmark_action_menu_on_screen_Up(option_selection, Partial_refresh);
                    time_count = 0;
                    break;
                    
                case 7: // Perform the selection operation
                    switch (option_selection) {
                        case 0: // Jump to Bookmarks
                            if (fiction_jump_to_bookmark(&g_fiction_ctx, bookmark_selection)) {
                                g_display_ctx.current_position = g_fiction_ctx.current_position;
                                g_display_ctx.current_page = g_fiction_ctx.current_page;
                                for (int i = 0; i < 3; i++) {
                                    g_display_ctx.page_buffers[i].is_valid = false;
                                }
                                display_current_page();
                            }
                            bookmark_action_mode = false;
                            bookmark_mode = false;
                            break;
                            
                        case 1: // Delete bookmarks
                            fiction_delete_bookmark(&g_fiction_ctx, bookmark_selection);
                            if (g_fiction_ctx.bookmark_count == 0) {
                                restore_current_page();
                                bookmark_action_mode = false;
                                bookmark_mode = false;
                            } else {
                                if (bookmark_selection >= g_fiction_ctx.bookmark_count) {
                                    bookmark_selection = g_fiction_ctx.bookmark_count - 1;
                                }
                                display_loading_fiction("书签加载中...",Partial_refresh);
                                display_bookmark_list_on_screen(&g_fiction_ctx, bookmark_selection);
                                bookmark_action_mode = false;
                            }
                            break;
                            
                        case 2: // Return to the bookmark list
                            restore_bookmark_page();
                            bookmark_action_mode = false;
                            break;
                    }
                    time_count = 0;
                    break;
                    
                case 8: // cancel
                case 22:
                    restore_bookmark_page();
                    bookmark_action_mode = false;
                    time_count = 0;
                    break;

                case 12:
                    Forced_refresh_fiction(bookmark_preview_buffer);
                    time_count = 0;
                    break;
            }
        } else if (bookmark_mode) {
            // Bookmark selection mode
            switch (button) {
                case 14:
                    if (g_fiction_ctx.bookmark_count > 0) {
                        bookmark_selection++;
                        if (bookmark_selection >= g_fiction_ctx.bookmark_count) {
                            bookmark_selection = 0;
                        }
                        display_bookmark_list_on_screen_Down(bookmark_selection, Partial_refresh);
                    }
                    time_count = 0;
                    break;
                    
                case 0:
                    if (g_fiction_ctx.bookmark_count > 0) {
                        bookmark_selection--;
                        if (bookmark_selection < 0) {
                            bookmark_selection = g_fiction_ctx.bookmark_count - 1;
                        }
                        display_bookmark_list_on_screen_Up(bookmark_selection, Partial_refresh);
                    }
                    time_count = 0;
                    break;
                    
                case 7:
                    if (g_fiction_ctx.bookmark_count > 0) {
                        option_selection = 0;
                        display_loading_fiction("书签预览加载中...",Partial_refresh);
                        display_bookmark_action_menu_on_screen(&g_fiction_ctx, bookmark_selection, option_selection);
                        bookmark_action_mode = true;
                    }
                    time_count = 0;
                    break;
                    
                case 8: // Add a bookmark (in bookmark mode)
                    g_fiction_ctx.current_position = g_display_ctx.current_position;
                    g_fiction_ctx.current_page = g_display_ctx.current_page;
                    fiction_add_bookmark(&g_fiction_ctx);

                    bookmark_selection = g_fiction_ctx.bookmark_count - 1;
                    display_loading_fiction("书签加载中...",Partial_refresh);
                    display_bookmark_list_on_screen(&g_fiction_ctx, bookmark_selection);
                    time_count = 0;
                    break;
                    
                case 22: // Exit bookmark mode
                    restore_current_page();
                    bookmark_mode = false;
                    time_count = 0;
                    break;

                case 12:
                    Forced_refresh_fiction(bookmark_display_buffer);
                    time_count = 0;
                    break;
            }
        } else {
            // Normal reading mode
            switch (button) {
                case 14: // next page
                    if (turn_to_next_page()) {
                        g_fiction_ctx.current_position = g_display_ctx.current_position;
                        g_fiction_ctx.current_page = g_display_ctx.current_page;
                        fiction_save_progress(&g_fiction_ctx);
                    }
                    time_count = 0;
                    break;
                    
                case 0: // previous page
                    if (turn_to_previous_page()) {
                        g_fiction_ctx.current_position = g_display_ctx.current_position;
                        g_fiction_ctx.current_page = g_display_ctx.current_page;
                        fiction_save_progress(&g_fiction_ctx);
                    }
                    time_count = 0;
                    break;
                    
                case 15: // Double-click DOWN - Font Settings
                    font_menu_selection = g_display_ctx.current_font_size;
                    display_font_menu(font_menu_selection);
                    font_menu_mode = true;
                    time_count = 0;
                    break;
                    
                case 1: // Double-click on - Font Settings (Standby)
                    font_menu_selection = g_display_ctx.current_font_size;
                    display_font_menu(font_menu_selection);
                    font_menu_mode = true;
                    time_count = 0;
                    break;
                    
                case 7: // Bookmark function
                    if (g_fiction_ctx.bookmark_count > 0) {
                        bookmark_selection = 0;
                        display_loading_fiction("书签加载中...",Partial_refresh);
                        display_bookmark_list_on_screen(&g_fiction_ctx, bookmark_selection);
                        bookmark_mode = true;
                    } else {
                        display_loading_fiction("书签加载中...",Partial_refresh);
                        display_bookmark_list_on_screen(&g_fiction_ctx, 0);
                        bookmark_mode = true;
                    }
                    time_count = 0;
                    break;

                case 8: // add bookmark
                    g_fiction_ctx.current_position = g_display_ctx.current_position;
                    g_fiction_ctx.current_page = g_display_ctx.current_page;
                    fiction_add_bookmark(&g_fiction_ctx);
                    display_current_page();
                    time_count = 0;
                    break;

                case 22: // quit
                    g_fiction_ctx.current_position = g_display_ctx.current_position;
                    g_fiction_ctx.current_page = g_display_ctx.current_page;
                    fiction_close_file(&g_fiction_ctx);
                    free_fiction_display_buffers();
                    free_bookmark_display_buffers();
                    ESP_LOGI(TAG, "Fiction reading closed");
                    time_count = 0;
                    return;
                
                case 12:
                    Forced_refresh_fiction(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer);
                    time_count = 0;
                    break;
                    
                default:
                    break;
            }
        }

        rtc_time = PCF85063_GetTime();
        if ((rtc_time.minutes != last_minutes) && (time_count < EPD_Sleep_Time)) {
            last_minutes = rtc_time.minutes;
            if (!font_menu_mode && !bookmark_mode && !bookmark_action_mode) {
                display_time_bet_fiction(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer);
                Forced_Refresh_page_fiction(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer);
                ESP_LOGI(TAG, "Time/battery updated in reading mode");
            } else if (bookmark_mode && !bookmark_action_mode) {
                Paint_SelectImage(bookmark_display_buffer);
                display_time_bet_fiction(bookmark_display_buffer);
                Forced_Refresh_page_fiction(bookmark_display_buffer);
                ESP_LOGI(TAG, "Time/battery updated in bookmark mode");
            } else if (bookmark_action_mode) {
                Paint_SelectImage(bookmark_preview_buffer);
                display_time_bet_fiction(bookmark_preview_buffer);
                Forced_Refresh_page_fiction(bookmark_preview_buffer);
                ESP_LOGI(TAG, "Time/battery updated in bookmark action mode");
            }
        }
    }
    
    free_fiction_display_buffers();
    free_bookmark_display_buffers();
    fiction_close_file(&g_fiction_ctx);
}

// Chinese character detection function
bool is_chinese_filename(const char* filename) {
    if (!filename) return false;
    
    for (int i = 0; filename[i] != '\0'; i++) {
        unsigned char ch = (unsigned char)filename[i];
        if (ch >= 0x80) {
            return true;
        }
    }
    return false;
}

// Release the display cache
void free_fiction_display_buffers(void) {
    // Release the mutex
    if (fs_access_mutex) {
        vSemaphoreDelete(fs_access_mutex);
        fs_access_mutex = NULL;
        ESP_LOGI(TAG, "fs_access_mutex deleted");
    }

    heap_caps_free(page_backup_buffer);
    page_backup_buffer = NULL;
    for (int i = 0; i < 3; i++) {
        if (g_display_ctx.page_buffers[i].buffer) {
            heap_caps_free(g_display_ctx.page_buffers[i].buffer);
            g_display_ctx.page_buffers[i].buffer = NULL;
            g_display_ctx.page_buffers[i].is_valid = false;
            g_display_ctx.page_buffers[i].is_rendering = false;
        }
    }
    ESP_LOGI(TAG, "Fiction display buffers freed");
}

// Initialize the display cache area
void init_fiction_display_buffers(void) {
    size_t page_buffer_size = (SCREEN_WIDTH * SCREEN_HEIGHT) / 8;
    page_backup_buffer = (uint8_t*)heap_caps_malloc(page_buffer_size, MALLOC_CAP_SPIRAM);
    if (!page_backup_buffer) {
        ESP_LOGE(TAG, "Failed to allocate page buffer ");
        return;
    }

    for (int i = 0; i < 3; i++) {
        g_display_ctx.page_buffers[i].buffer = (uint8_t*)heap_caps_malloc(page_buffer_size, MALLOC_CAP_SPIRAM);
        if (!g_display_ctx.page_buffers[i].buffer) {
            ESP_LOGE(TAG, "Failed to allocate page buffer %d", i);
            return;
        }
        memset(g_display_ctx.page_buffers[i].buffer, 0xFF, page_buffer_size);
        g_display_ctx.page_buffers[i].is_valid = false;
        g_display_ctx.page_buffers[i].is_rendering = false;
    }

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    if (err != ESP_OK) {
        ESP_LOGE("fiction", "NVS init failed: %s", esp_err_to_name(err));
    }

    // Load the saved font index (if any)
    font_size_t saved_font = Default_font;
    if (load_font_size_from_nvs(&saved_font) == ESP_OK) {
        ESP_LOGI("fiction", "apply saved font size %d", saved_font);
        switch_font_size(saved_font);
    } else {
        ESP_LOGI("fiction", "no saved font, keep default");
    }
        
    // Set the default font
    g_display_ctx.current_font_size = saved_font;
    g_display_ctx.current_font = get_font_by_encoding(saved_font, g_display_ctx.encoding);
    g_display_ctx.current_buffer_index = BUFFER_CURRENT;
    
    calculate_display_params();
    
    ESP_LOGI(TAG, "Fiction display buffers initialized: %d bytes per page", (int)page_buffer_size);
}

// Count the number of characters (distinguish between Chinese and English)
int count_characters(const char* text, const char* encoding) {
    int char_count = 0;
    const char* p = text;
    
    while (*p != '\0') {
        int char_len = 1;
        
        if (strstr(encoding, "UTF8") || strstr(encoding, "utf8")) {
            char_len = Get_UTF8_Char_Length((unsigned char)*p);
        } else {
            char_len = (*p < 0x80) ? 1 : 2;
        }
        
        char_count++;
        p += char_len;
    }
    
    return char_count;
}

// Calculate the display parameter function
void calculate_display_params(void) {
    g_display_ctx.current_font = get_font_by_encoding(g_display_ctx.current_font_size, g_display_ctx.encoding);
    cFONT* font = g_display_ctx.current_font;
    
    int start_y = 70;
    int footer_space = 30;
    int line_height = font->Height + 6;
    int content_height = SCREEN_HEIGHT - start_y - footer_space;
    
    g_display_ctx.lines_per_page = content_height / line_height;
    
    int left_margin = 20;
    int right_margin = 10;
    int available_width = SCREEN_WIDTH - left_margin - right_margin;
    
    int ch_char_width = font->Width_CH;
    int max_chars_by_width = available_width / ch_char_width;
    
    if (strstr(g_display_ctx.encoding, "GBK") || strstr(g_display_ctx.encoding, "GB2312")) {
        g_display_ctx.chars_per_line = max_chars_by_width + 2;
    } else {
        g_display_ctx.chars_per_line = max_chars_by_width + 1;
    }
    
    int absolute_max = (available_width * 110) / (ch_char_width * 100);
    if (g_display_ctx.chars_per_line > absolute_max) {
        g_display_ctx.chars_per_line = absolute_max;
    }
    
    ESP_LOGI(TAG, "Display params optimized:");
    ESP_LOGI(TAG, "  Available width: %d px, char width: %d px", available_width, ch_char_width);
    ESP_LOGI(TAG, "  Result: %d lines × %d chars (max_by_width=%d, absolute_max=%d)", g_display_ctx.lines_per_page, g_display_ctx.chars_per_line, max_chars_by_width, absolute_max);
}

// Switch font size
void switch_font_size(font_size_t font_size) {
    if (font_size >= FONT_SIZE_MAX) return;
    
    g_display_ctx.current_font_size = font_size;
    // Select the corresponding font based on the current encoding
    g_display_ctx.current_font = get_font_by_encoding(font_size, g_display_ctx.encoding);
    
    // Recalculate the display parameters
    calculate_display_params();

    for (int i = 0; i < 3; i++) {
        g_display_ctx.page_buffers[i].is_valid = false;
    }
    
    // Save the selection to NVS
    esp_err_t err = save_font_size_to_nvs(font_size);
    if (err != ESP_OK) {
        ESP_LOGW("fiction", "save font idx failed: %s", esp_err_to_name(err));
    }
    
    ESP_LOGI(TAG, "Font switched to: %s (%s encoding)", font_names[font_size], g_display_ctx.encoding);
}

// Calculate the byte length of the character
int get_char_byte_length(const char* str, int pos, const char* encoding) {
    if (strstr(encoding, "GBK") || strstr(encoding, "GB2312")) {
        unsigned char ch = (unsigned char)str[pos];
        if (ch >= 0xA1 && ch <= 0xFE) {
            return 2; 
        } else {
            return 1;
        }
    } else {
        unsigned char ch = (unsigned char)str[pos];
        if (ch < 0x80) {
            return 1;
        } else if ((ch & 0xE0) == 0xC0) {
            return 2; 
        } else if ((ch & 0xF0) == 0xE0) {
            return 3; 
        } else if ((ch & 0xF8) == 0xF0) {
            return 4; 
        }
        return 1;
    }
}

// Extract the string by the number of characters
int copy_chars_by_count(const char* source, char* dest, int target_chars, const char* encoding) {
    int copied_chars = 0;
    int bytes_copied = 0;
    const char* p = source;
    
    while (*p != '\0' && copied_chars < target_chars && bytes_copied < 510) { 
        int char_len = 1;
        
        if (strstr(encoding, "UTF8") || strstr(encoding, "utf8")) {
            char_len = Get_UTF8_Char_Length((unsigned char)*p);
        } else {
            char_len = (*p < 0x80) ? 1 : 2;
        }
        
        if (bytes_copied + char_len >= 510) {
            ESP_LOGW(TAG, "Buffer boundary reached at char %d", copied_chars);
            break;
        }
        
        for (int i = 0; i < char_len && *(p + i) != '\0'; i++) {
            dest[bytes_copied++] = *(p + i);
        }
        
        copied_chars++;
        p += char_len;
        
        ESP_LOGV(TAG, "Copied char %d: len=%d bytes, total_chars=%d, total_bytes=%d", copied_chars, char_len, copied_chars, bytes_copied);
    }
    
    dest[bytes_copied] = '\0';
    ESP_LOGI(TAG, "copy_chars_by_count: target=%d, actual_chars=%d, bytes=%d", target_chars, copied_chars, bytes_copied);
    return bytes_copied;
}


// File reading
bool read_page_from_file(size_t start_position, char* content, int max_len, size_t* end_position) {
    FILE* fp = fopen(g_display_ctx.filepath, "rb");
    if (!fp) {
        ESP_LOGE(TAG, "Failed to open file: %s", g_display_ctx.filepath);
        return false;
    }
    
    fseek(fp, start_position, SEEK_SET);
    
    int content_pos = 0;
    int line_count = 0;
    
    content[0] = '\0';
    int target_lines = g_display_ctx.lines_per_page;
    
    ESP_LOGI(TAG, "Reading page: target %d lines, max_len=%d bytes", target_lines, max_len);

    const int LINE_BUF_BYTES = sizeof(lines_char[0]); 
    int columns_count = 0;
    int line_count_char_len = 0; 
    const bool is_utf8 = strstr(g_display_ctx.encoding, "UTF") != NULL;
    int ch;

    while (line_count < target_lines) {
        ch = fgetc(fp);
        if (ch == EOF) break;
        unsigned char uc = (unsigned char)ch;
        if (uc == '\r') continue;
        if (uc == '\n') {
            if (columns_count < LINE_BUF_BYTES) lines_char[line_count][columns_count] = '\0';
            else lines_char[line_count][LINE_BUF_BYTES - 1] = '\0';
            
            content_pos = content_pos + columns_count;
            columns_count = 0;
            line_count_char_len = 0;
            line_count++;
            continue;
        }

        int char_len = 1;
        int char_pixel = g_display_ctx.current_font->Width_EN;
        unsigned char tmp[4];
        tmp[0] = uc;

        if (is_utf8) {
            if (uc < 0x80) { char_len = 1; char_pixel = g_display_ctx.current_font->Width_EN; }
            else if ((uc & 0xE0) == 0xC0) { char_len = 2; char_pixel = g_display_ctx.current_font->Width_CH; }
            else if ((uc & 0xF0) == 0xE0) { char_len = 3; char_pixel = g_display_ctx.current_font->Width_CH; }
            else if ((uc & 0xF8) == 0xF0) { char_len = 4; char_pixel = g_display_ctx.current_font->Width_CH; }
            for (int i = 1; i < char_len; i++) {
                int nb = fgetc(fp);
                if (nb == EOF) { char_len = i; break; }
                tmp[i] = (unsigned char)nb;
            }
        } else {
            if (uc < 0x80) { char_len = 1; char_pixel = g_display_ctx.current_font->Width_EN; }
            else {
                char_len = 2; char_pixel = g_display_ctx.current_font->Width_CH;
                int nb = fgetc(fp);
                if (nb == EOF) { char_len = 1; }
                else tmp[1] = (unsigned char)nb;
            }
        }

        if (columns_count + char_len >= LINE_BUF_BYTES - 1) {
            for (int i = char_len - 1; i >= 0; i--) ungetc(tmp[i], fp);
            if (columns_count < LINE_BUF_BYTES) lines_char[line_count][columns_count] = '\0';
            else lines_char[line_count][LINE_BUF_BYTES - 1] = '\0';
            content_pos = content_pos + columns_count;
            columns_count = 0;
            line_count_char_len = 0;
            line_count++;
            continue;
        }

        if (line_count_char_len + char_pixel > (SCREEN_WIDTH - 20)) {
            for (int i = char_len - 1; i >= 0; i--) ungetc(tmp[i], fp);
            if (columns_count < LINE_BUF_BYTES) lines_char[line_count][columns_count] = '\0';
            else lines_char[line_count][LINE_BUF_BYTES - 1] = '\0';
            content_pos = content_pos + columns_count;
            columns_count = 0;
            line_count_char_len = 0;
            line_count++;
            continue;
        }

        for (int i = 0; i < char_len; i++) {
            lines_char[line_count][columns_count++] = tmp[i];
        }
        line_count_char_len += char_pixel;
    }

    if (columns_count > 0 && line_count < target_lines) {
        if (columns_count < LINE_BUF_BYTES) lines_char[line_count][columns_count] = '\0';
        else lines_char[line_count][LINE_BUF_BYTES - 1] = '\0';
        line_count++;
    }

    long ft = ftell(fp);
    if (ft < 0) {
        ESP_LOGW(TAG, "ftell failed, using start_position as end_position");
        *end_position = start_position;
    } else {
        *end_position = (size_t)ft;
    }
    fclose(fp);
    
    float fill_rate = (float)line_count / target_lines * 100.0f;
    ESP_LOGI(TAG, "Page read result: %d/%d lines (%.1f%%), %d bytes", line_count, target_lines, fill_rate, content_pos);

    return (line_count > 0);
}

// Render canvas
void render_page_to_buffer(page_cache_t* cache, const char* content, bool is_current) {
    if (!cache || !cache->buffer || cache->is_rendering) return;
    
    cache->is_rendering = true;
    Paint_NewImage(cache->buffer, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SelectImage(cache->buffer);
    Paint_Clear(WHITE);
    
    cFONT* font = get_font_by_encoding(g_display_ctx.current_font_size, g_display_ctx.encoding);
    
    if (is_current) {
        char title[100];
        snprintf(title, sizeof(title), "第%d页 - %s", cache->page_number + 1, font_names[g_display_ctx.current_font_size]);
        Paint_DrawString_CN(20, 10, title, &Font16_UTF8, WHITE, BLACK);
        
        char encoding_info[50];
        snprintf(encoding_info, sizeof(encoding_info), "编码: %s", g_display_ctx.encoding);
        Paint_DrawString_CN(20, 35, encoding_info, &Font12_UTF8, WHITE, BLACK);
        
        if (g_display_ctx.file_size > 0) {
            float progress = (float)cache->file_position / g_display_ctx.file_size;
            int progress_width = (int)((SCREEN_WIDTH - 40) * progress);
            Paint_DrawRectangle(20, 60, 20 + progress_width, 65, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
            Paint_DrawRectangle(20, 60, SCREEN_WIDTH - 20, 65, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
        }
    }

    int start_y = 70;
    int line_height = font->Height + 6;
    int footer_space = 30;
    int content_height = SCREEN_HEIGHT - start_y - footer_space;
    int max_lines = content_height / line_height;
    int max_content_y = start_y + max_lines * line_height;
    
    ESP_LOGI(TAG, "Layout: start_y=%d, line_height=%d, footer_space=%d, max_lines=%d, max_content_y=%d", start_y, line_height, footer_space, max_lines, max_content_y);
    
    const char* p = content;
    const char* line_start = content;

    int target_lines = g_display_ctx.lines_per_page;
    for (size_t i = 0; i < target_lines; i++)
    {
        Paint_DrawString_CN(10, start_y + i*line_height, lines_char[i], font, WHITE, BLACK);
    }
    
    if (is_current) {
        char footer[100];
        snprintf(footer, sizeof(footer), "↑↓翻页,双击↑↓字体,双击Boot:退出");
        Paint_DrawString_CN(20, SCREEN_HEIGHT - 25, footer, &Font12_UTF8, WHITE, BLACK);
        
        display_time_bet_fiction(cache->buffer);
    }
    
    cache->lines_count = max_lines;
    cache->is_valid = true;
    cache->is_rendering = false;
    
    // ESP_LOGI(TAG, "Page rendered successfully: %d lines displayed", rendered_lines);
}

// Display time and battery level
void display_time_bet_fiction(uint8_t* buffer)
{
    Paint_SelectImage(buffer);
    char Time_str[16]={0};
    int BAT_Power;

    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    Time_data rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);
    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", rtc_time.hours, rtc_time.minutes);
    Paint_DrawString_EN(SCREEN_WIDTH - 120, SCREEN_HEIGHT - 25, Time_str, &Font12, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    Paint_ReadBmp(gImage_BAT,SCREEN_WIDTH - 60, SCREEN_HEIGHT - 23,32,16);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    GUI_ReadBmp(BMP_BAT_PATH,SCREEN_WIDTH - 60, SCREEN_HEIGHT - 23);
#endif
    
    BAT_Power = get_battery_power();
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawRectangle(SCREEN_WIDTH - 55, SCREEN_HEIGHT - 18, SCREEN_WIDTH - 75, SCREEN_HEIGHT - 10, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(SCREEN_WIDTH - 55, SCREEN_HEIGHT - 18, SCREEN_WIDTH - 55 + BAT_Power, SCREEN_HEIGHT - 10, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
}

// Preload the next page
void preload_next_page(void) {
    // if (fs_access_mutex) xSemaphoreTake(fs_access_mutex, pdMS_TO_TICKS(5000));
    if (fs_access_mutex) xSemaphoreTake(fs_access_mutex, portMAX_DELAY);

    page_cache_t* next_cache = &g_display_ctx.page_buffers[BUFFER_NEXT];
    page_cache_t* current_cache = &g_display_ctx.page_buffers[BUFFER_CURRENT];

    if (next_cache->is_valid || next_cache->is_rendering) {
        if (fs_access_mutex) xSemaphoreGive(fs_access_mutex);
        return;
    }

    size_t start_pos = current_cache->file_position;
    size_t end_pos;

    ESP_LOGI(TAG, "Preloading next page from position %zu", start_pos);

    if (read_page_from_file(start_pos, next_cache->content, sizeof(next_cache->content), &end_pos)) {
        next_cache->file_position = end_pos;
        next_cache->page_number = current_cache->page_number + 1;
        render_page_to_buffer(next_cache, next_cache->content, false);
        ESP_LOGI(TAG, "Next page preloaded successfully: page %d, pos %zu->%zu", next_cache->page_number, start_pos, end_pos);
    } else {
        ESP_LOGW(TAG, "Failed to preload next page (possibly end of file)");
    }

    if (fs_access_mutex) xSemaphoreGive(fs_access_mutex);
}

// Preload the previous page
void preload_previous_page(void) {
    page_cache_t* prev_cache = &g_display_ctx.page_buffers[BUFFER_PREVIOUS];
    page_cache_t* current_cache = &g_display_ctx.page_buffers[BUFFER_CURRENT];
    
    if (prev_cache->is_valid || prev_cache->is_rendering || current_cache->page_number <= 0) {
        return;
    }
    
    size_t estimated_page_size = g_display_ctx.lines_per_page * g_display_ctx.chars_per_line;
    size_t start_pos = (current_cache->file_position > estimated_page_size) ? 
                       current_cache->file_position - estimated_page_size : 0;
    size_t end_pos;
    
    ESP_LOGI(TAG, "Preloading previous page from estimated position %zu", start_pos);
    
    if (read_page_from_file(start_pos, prev_cache->content, sizeof(prev_cache->content), &end_pos)) {
        prev_cache->file_position = start_pos;
        prev_cache->page_number = current_cache->page_number - 1;
        
        render_page_to_buffer(prev_cache, prev_cache->content, false);
        
        ESP_LOGI(TAG, "Previous page preloaded successfully: page %d", prev_cache->page_number);
    } else {
        ESP_LOGW(TAG, "Failed to preload previous page");
    }
}

// Display the current page
void display_current_page(void) {
    // if (fs_access_mutex) xSemaphoreTake(fs_access_mutex, pdMS_TO_TICKS(5000));
    if (fs_access_mutex) xSemaphoreTake(fs_access_mutex, portMAX_DELAY);

    page_cache_t* current_cache = &g_display_ctx.page_buffers[BUFFER_CURRENT];
    if (!current_cache->is_valid) {
        size_t end_pos;
        if (read_page_from_file(g_display_ctx.current_position, current_cache->content, sizeof(current_cache->content), &end_pos)) {
            current_cache->file_position = end_pos;
            current_cache->page_number = g_display_ctx.current_page;
            render_page_to_buffer(current_cache, current_cache->content, true);
        }
    } else {
        render_page_to_buffer(current_cache, current_cache->content, true);
    }

    EPD_Display_Partial(current_cache->buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);

    if (fs_access_mutex) xSemaphoreGive(fs_access_mutex);

    preload_next_page();
    preload_previous_page();
}

// Turn to the next page
bool turn_to_next_page(void) {
    // if (fs_access_mutex) xSemaphoreTake(fs_access_mutex, pdMS_TO_TICKS(5000));
    if (fs_access_mutex) xSemaphoreTake(fs_access_mutex, portMAX_DELAY);

    page_cache_t* next_cache = &g_display_ctx.page_buffers[BUFFER_NEXT];
    if (!next_cache->is_valid) {
        ESP_LOGW(TAG, "Next page not preloaded, loading now...");
        size_t start_pos = g_display_ctx.page_buffers[BUFFER_CURRENT].file_position;
        size_t end_pos;
        if (!read_page_from_file(start_pos, next_cache->content, sizeof(next_cache->content), &end_pos)) {
            ESP_LOGE(TAG, "Failed to load next page");
            if (fs_access_mutex) xSemaphoreGive(fs_access_mutex);
            return false;
        }
        next_cache->file_position = end_pos;
        next_cache->page_number = g_display_ctx.current_page + 1;
        render_page_to_buffer(next_cache, next_cache->content, false);
    } else {
        ESP_LOGI(TAG, "Using preloaded next page (fast switch)");
    }

    // Cache exchange
    uint8_t* temp_buffer = g_display_ctx.page_buffers[BUFFER_PREVIOUS].buffer;
    char temp_content[sizeof(g_display_ctx.page_buffers[0].content)];
    strcpy(temp_content, g_display_ctx.page_buffers[BUFFER_PREVIOUS].content);
    g_display_ctx.page_buffers[BUFFER_PREVIOUS] = g_display_ctx.page_buffers[BUFFER_CURRENT];
    g_display_ctx.page_buffers[BUFFER_CURRENT] = g_display_ctx.page_buffers[BUFFER_NEXT];
    g_display_ctx.page_buffers[BUFFER_NEXT].buffer = temp_buffer;
    strcpy(g_display_ctx.page_buffers[BUFFER_NEXT].content, temp_content);
    g_display_ctx.page_buffers[BUFFER_NEXT].is_valid = false;
    g_display_ctx.page_buffers[BUFFER_NEXT].is_rendering = false;
    g_display_ctx.current_page = g_display_ctx.page_buffers[BUFFER_CURRENT].page_number;
    g_display_ctx.current_position = g_display_ctx.page_buffers[BUFFER_CURRENT].file_position;

    // UI + Display
    render_current_page_ui(&g_display_ctx.page_buffers[BUFFER_CURRENT]);
    EPD_Display_Partial(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);

    if (fs_access_mutex) xSemaphoreGive(fs_access_mutex);

    // Preload the next page in the background
    xTaskCreate(preload_next_page_task, "preload_next", 10*1024, NULL, 5, NULL);

    ESP_LOGI(TAG, "Fast page turn to: %d", g_display_ctx.current_page);
    return true;
}

// Turn to the previous page
bool turn_to_previous_page(void) {
    if (g_display_ctx.current_page <= 0) {
        ESP_LOGW(TAG, "Already at first page");
        return false;
    }
    
    page_cache_t* prev_cache = &g_display_ctx.page_buffers[BUFFER_PREVIOUS];
    
    if (!prev_cache->is_valid) {
        ESP_LOGW(TAG, "Previous page not preloaded, loading now...");
        size_t estimated_page_size = g_display_ctx.lines_per_page * g_display_ctx.chars_per_line;
        size_t start_pos = (g_display_ctx.current_position > estimated_page_size) ? g_display_ctx.current_position - estimated_page_size : 0;
        size_t end_pos;
        
        if (!read_page_from_file(start_pos, prev_cache->content, sizeof(prev_cache->content), &end_pos)) {
            ESP_LOGE(TAG, "Failed to load previous page");
            return false;
        }
        
        prev_cache->file_position = start_pos;
        prev_cache->page_number = g_display_ctx.current_page - 1;
        render_page_to_buffer(prev_cache, prev_cache->content, false);
    } else {
        ESP_LOGI(TAG, "Using preloaded previous page (fast switch)");
    }
    
    uint8_t* temp_buffer = g_display_ctx.page_buffers[BUFFER_NEXT].buffer;
    char temp_content[sizeof(g_display_ctx.page_buffers[0].content)];
    strcpy(temp_content, g_display_ctx.page_buffers[BUFFER_NEXT].content);
    
    // Backward scrolling cache
    g_display_ctx.page_buffers[BUFFER_NEXT] = g_display_ctx.page_buffers[BUFFER_CURRENT];
    g_display_ctx.page_buffers[BUFFER_CURRENT] = g_display_ctx.page_buffers[BUFFER_PREVIOUS];
    
    // Previous page cache
    g_display_ctx.page_buffers[BUFFER_PREVIOUS].buffer = temp_buffer;
    strcpy(g_display_ctx.page_buffers[BUFFER_PREVIOUS].content, temp_content);
    g_display_ctx.page_buffers[BUFFER_PREVIOUS].is_valid = false;
    g_display_ctx.page_buffers[BUFFER_PREVIOUS].is_rendering = false;
    
    // Update the context
    g_display_ctx.current_page = g_display_ctx.page_buffers[BUFFER_CURRENT].page_number;
    g_display_ctx.current_position = g_display_ctx.page_buffers[BUFFER_CURRENT].file_position;
    
    // Only add UI elements
    render_current_page_ui(&g_display_ctx.page_buffers[BUFFER_CURRENT]);
    
    // Display immediately
    EPD_Display_Partial(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    
    // The previous page was preloaded in the background
    xTaskCreate(preload_previous_page_task, "preload_prev", 10*1024, NULL, 5, NULL);
    
    ESP_LOGI(TAG, "Fast page turn to: %d", g_display_ctx.current_page);
    return true;
}

// UI rendering
void render_current_page_ui(page_cache_t* cache) {
    if (!cache || !cache->buffer) return;
    
    Paint_SelectImage(cache->buffer);
    
    cFONT* font = get_font_by_encoding(g_display_ctx.current_font_size, g_display_ctx.encoding);
    Paint_DrawRectangle(0, 0, SCREEN_WIDTH, 70, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    
    // Draw the title bar
    char title[100];
    snprintf(title, sizeof(title), "第%d页 - %s", cache->page_number + 1, font_names[g_display_ctx.current_font_size]);
    Paint_DrawString_CN(20, 10, title, &Font16_UTF8, WHITE, BLACK);
    
    // Display coding information
    char encoding_info[50];
    snprintf(encoding_info, sizeof(encoding_info), "编码: %s", g_display_ctx.encoding);
    Paint_DrawString_CN(20, 35, encoding_info, &Font12_UTF8, WHITE, BLACK);
    
    if (g_display_ctx.file_size > 0) {
        float progress = (float)cache->file_position / g_display_ctx.file_size;
        int progress_width = (int)((SCREEN_WIDTH - 40) * progress); // 480-40=440
        Paint_DrawRectangle(20, 60, 20 + progress_width, 65, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
        Paint_DrawRectangle(20, 60, SCREEN_WIDTH - 20, 65, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
    }
    
    // Clear and draw the footer
    Paint_DrawRectangle(0, SCREEN_HEIGHT - 25, SCREEN_WIDTH, SCREEN_HEIGHT, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    char footer[100];
    snprintf(footer, sizeof(footer), "↑↓翻页,双击↑↓:字体,双击Boot:退出");
    Paint_DrawString_CN(20, SCREEN_HEIGHT - 25, footer, &Font12_UTF8, WHITE, BLACK);

    // Time and battery power
    display_time_bet_fiction(cache->buffer);
}

// Background preload task
void preload_next_page_task(void* pvParameters) {
    vTaskDelay(pdMS_TO_TICKS(100));
    preload_next_page();
    vTaskDelete(NULL);
}

void preload_previous_page_task(void* pvParameters) {
    vTaskDelay(pdMS_TO_TICKS(100));
    preload_previous_page();
    vTaskDelete(NULL);
}

// Font menu display
void display_font_menu(font_size_t selected_font) {
    Paint_NewImage(Image_Mono, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SelectImage(Image_Mono);
    Paint_Clear(WHITE);
    
    Paint_DrawString_CN(20, 20, "字体设置", &Font24_UTF8, BLACK, WHITE);
    Paint_DrawLine(20, 60, SCREEN_WIDTH - 20, 60, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    
    char encoding_info[50];
    snprintf(encoding_info, sizeof(encoding_info), "编码: %s", g_display_ctx.encoding);
    Paint_DrawString_CN(20, 70, encoding_info, &Font16_UTF8, BLACK, WHITE);
    
    int start_y = 120;
    int item_height = 50;
    int y_pos = start_y;
    
    for (int i = 0; i < FONT_SIZE_MAX; i++) {
        cFONT* demo_font = get_font_by_encoding((font_size_t)i, "UTF");
        Paint_DrawString_CN(60, y_pos, font_names_1[i], demo_font, BLACK, WHITE);
        
        // Sample text
        Paint_DrawString_CN(200, y_pos, "示例Abc123", demo_font, WHITE, BLACK);
        
        if (i == (int)selected_font) {
            Paint_DrawRectangle(15, y_pos - 5, SCREEN_WIDTH - 15, y_pos + demo_font->Height + 5, BLACK, DOT_PIXEL_1X1, DRAW_FILL_EMPTY);
            Paint_DrawString_CN(25, y_pos, ">", demo_font, BLACK, WHITE);
        }

        y_pos = y_pos + demo_font->Height + 10;
        if (y_pos > SCREEN_HEIGHT - 80) break;
    }
    
    Paint_DrawString_CN(20, SCREEN_HEIGHT - 40, "↑↓选择,单击确认:应用,双击确认:返回", &Font12_UTF8, WHITE, BLACK);
    
    EPD_Display_Partial(Image_Mono, 0, 0, EPD_WIDTH, EPD_HEIGHT);
}






// Bookmark e-paper display
// Initialize the bookmark display
void init_bookmark_display_buffers(void) {
    size_t buffer_size = (SCREEN_WIDTH * SCREEN_HEIGHT) / 8;
    
    // Allocate bookmark display cache
    if (!bookmark_display_buffer) {
        bookmark_display_buffer = (uint8_t*)heap_caps_malloc(buffer_size, MALLOC_CAP_SPIRAM);
        if (!bookmark_display_buffer) {
            ESP_LOGE(TAG, "Failed to allocate bookmark display buffer");
            return;
        }
    }

    // Allocate the bookmark preview cache
    if (!bookmark_preview_buffer) {
        bookmark_preview_buffer = (uint8_t*)heap_caps_malloc(buffer_size, MALLOC_CAP_SPIRAM);
        if (!bookmark_preview_buffer) {
            ESP_LOGE(TAG, "Failed to allocate bookmark display buffer");
            return;
        }
    }    
    ESP_LOGI(TAG, "Bookmark display buffers initialized: %d bytes each", (int)buffer_size);
}

// Release the bookmark display cache
void free_bookmark_display_buffers(void) {
    if (bookmark_display_buffer) {
        heap_caps_free(bookmark_display_buffer);
        bookmark_display_buffer = NULL;
    }

    if (bookmark_preview_buffer) {
        heap_caps_free(bookmark_preview_buffer);
        bookmark_preview_buffer = NULL;
    }
    ESP_LOGI(TAG, "Bookmark display buffers freed");
}

// Restore the bookmark display page
void restore_bookmark_page(void) {
    // Display the content of the backup directly
    EPD_Display_Partial(bookmark_display_buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    ESP_LOGI(TAG, "Current page restored from backup");
}

// Restore the current page content
void restore_current_page(void) {
    // Display the content of the backup directly
    EPD_Display_Partial(g_display_ctx.page_buffers[BUFFER_CURRENT].buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    ESP_LOGI(TAG, "Current page restored from backup");
}

// Extract the string for preview display
void safe_truncate_for_preview(const char* src, char* dst, int max_chars, const char* encoding) {
    int src_pos = 0;
    int dst_pos = 0;
    int char_count = 0;
    int src_len = strlen(src);
    
    const int max_dst_size = 79 - 3;
    
    while (src_pos < src_len && char_count < max_chars && dst_pos < max_dst_size) {
        int char_bytes = get_char_byte_length(src, src_pos, encoding);
        if (dst_pos + char_bytes > max_dst_size) {
            ESP_LOGI(TAG, "Preview truncated at char %d due to buffer limit", char_count);
            break;
        }
        if (src_pos + char_bytes > src_len) {
            ESP_LOGW(TAG, "Source string boundary exceeded, stopping at char %d", char_count);
            break;
        }
        for (int i = 0; i < char_bytes; i++) {
            dst[dst_pos++] = src[src_pos++];
        }
        char_count++;
    }
    
    if (src_pos < src_len && dst_pos <= max_dst_size) {
        strcpy(dst + dst_pos, "...");
        dst_pos += 3;
    }
    
    dst[dst_pos] = '\0';
    
    ESP_LOGI(TAG, "Preview: %d chars, %d bytes from %d source bytes (encoding: %s)", 
             char_count, dst_pos, src_len, encoding);
}

// Preview processing of the content in the bookmark list display
void display_bookmark_list_on_screen(fiction_context_t* ctx, int selected_index) {
    if (!bookmark_display_buffer) {
        ESP_LOGE(TAG, "Bookmark display buffer not initialized");
        return;
    }
    
    // Set the bookmark display cache
    Paint_NewImage(bookmark_display_buffer, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SelectImage(bookmark_display_buffer);
    Paint_Clear(WHITE);
    
    // title bar
    Paint_DrawString_CN(20, 20, "书签管理", &Font24_UTF8, WHITE, BLACK);
    Paint_DrawLine(20, 60, SCREEN_WIDTH - 20, 60, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    
    // Display bookmark statistics information
    char stats_info[100];
    snprintf(stats_info, sizeof(stats_info), "共有 %d 个书签", ctx->bookmark_count);
    Paint_DrawString_CN(20, 70, stats_info, &Font16_UTF8, WHITE, BLACK);
    
    if (ctx->bookmark_count == 0) {
        // A prompt when there are no bookmarks
        int center_y = SCREEN_HEIGHT / 2;
        Paint_DrawString_CN(60, center_y - 60, "还没有添加任何书签", &Font18_UTF8, WHITE, BLACK);
        Paint_DrawString_CN(60, center_y - 20, "在阅读时按 8 键可添加当前位置为书签", &Font16_UTF8, WHITE, BLACK);
        Paint_DrawString_CN(60, center_y + 20, "书签可以帮助您快速回到感兴趣的位置", &Font16_UTF8, WHITE, BLACK);
    } else {
        // Display the bookmark list
        int list_start_y = 100; 
        int item_height = 100;
        int available_height = SCREEN_HEIGHT - list_start_y - 80;
        int visible_items = available_height / item_height;
        
        ESP_LOGI(TAG, "Bookmark layout: start_y=%d, item_height=%d, visible_items=%d, total=%d", list_start_y, item_height, visible_items, ctx->bookmark_count);
        
        // Calculate the rolling offset
        int scroll_offset = 0;
        if (selected_index >= visible_items) {
            scroll_offset = selected_index - visible_items + 1;
        }
        
        // Display bookmark items
        for (int i = 0; i < ctx->bookmark_count && i < visible_items; i++) {
            int actual_index = i + scroll_offset;
            if (actual_index >= ctx->bookmark_count) break;
            
            int item_y = list_start_y + i * item_height;
            
            // Selected item background
            if (actual_index == selected_index) {
                Paint_DrawRectangle(15, item_y+2, SCREEN_WIDTH - 15, item_y + item_height + 2, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
                Paint_DrawString_CN(25, item_y + 5, ">", &Font18_UTF8, WHITE, BLACK);
            }
            
            // Bookmark serial number and basic information
            char bookmark_title[100];
            snprintf(bookmark_title, sizeof(bookmark_title), "书签 %d: 第 %d 页", actual_index + 1, ctx->bookmarks[actual_index].page + 1);
            Paint_DrawString_CN(55, item_y + 5, bookmark_title, &Font18_UTF8, WHITE, BLACK);
            
            // Progress information
            char progress_info[50];
            snprintf(progress_info, sizeof(progress_info), "阅读进度: %.1f%%", 
                     ctx->bookmarks[actual_index].progress);
            Paint_DrawString_CN(55, item_y + 8 + Font18_UTF8.Height, progress_info, &Font16_UTF8, WHITE, BLACK);
            
            // Content Preview
            char preview[80];
            int max_preview_chars;
            if (strstr(g_display_ctx.encoding, "GBK") || strstr(g_display_ctx.encoding, "GB2312")) {
                max_preview_chars = 15;
            } else {
                max_preview_chars = 12;
            }
            
            safe_truncate_for_preview(ctx->bookmarks[actual_index].content_preview, preview, max_preview_chars, g_display_ctx.encoding);
            if (strstr(g_display_ctx.encoding, "GBK") || strstr(g_display_ctx.encoding, "GB2312")) {
                Paint_DrawString_CN(55, item_y + 11 + Font18_GBK.Height + Font16_GBK.Height, preview, &Font12_GBK, WHITE, BLACK);
            } else {
                Paint_DrawString_CN(55, item_y + 11 + Font18_UTF8.Height + Font16_UTF8.Height, preview, &Font12_UTF8, WHITE, BLACK);
            }
            
            ESP_LOGI(TAG, "Bookmark %d: y=%d, preview=[%s]", actual_index + 1, item_y, preview);
            if (i < visible_items - 1 && actual_index < ctx->bookmark_count - 1) {
                Paint_DrawLine(30, item_y + item_height - 5, SCREEN_WIDTH - 30, item_y + item_height - 5, BLACK, DOT_PIXEL_1X1, LINE_STYLE_DOTTED);
            }
        }
        
        if (ctx->bookmark_count > visible_items) {
            char scroll_info[30];
            snprintf(scroll_info, sizeof(scroll_info), "%d/%d", selected_index + 1, ctx->bookmark_count);
            Paint_DrawString_CN(SCREEN_WIDTH - 80, SCREEN_HEIGHT - 60, scroll_info, &Font16_UTF8, WHITE, BLACK);
        }
    }
    
    // OI (operating instructions)
    Paint_DrawLine(20, SCREEN_HEIGHT - Font16_UTF8.Height * 2 - 25, SCREEN_WIDTH - 20, SCREEN_HEIGHT - Font16_UTF8.Height * 2 - 25, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    
    if (ctx->bookmark_count > 0) {
        Paint_DrawString_CN(20, SCREEN_HEIGHT - Font16_UTF8.Height * 2 - 20, "↑↓选择书签,确认:操作菜单", &Font16_UTF8, WHITE, BLACK);
        Paint_DrawString_CN(20, SCREEN_HEIGHT - Font16_UTF8.Height * 1 - 15, "双击确认:添加书签,双击Boot:返回", &Font12_UTF8, WHITE, BLACK);
    } else {
        Paint_DrawString_CN(20, SCREEN_HEIGHT - Font16_UTF8.Height * 2 - 20, "双击确认:添加书签", &Font16_UTF8, WHITE, BLACK);
        Paint_DrawString_CN(20, SCREEN_HEIGHT - Font16_UTF8.Height * 1 - 15, "双击Boot:返回阅读", &Font16_UTF8, WHITE, BLACK);
    }

    // Time and battery power
    display_time_bet_fiction(bookmark_display_buffer);
    
    // Display on the screen
    EPD_Display_Partial(bookmark_display_buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    ESP_LOGI(TAG, "Full-screen bookmark list displayed: %d bookmarks, selected: %d", ctx->bookmark_count, selected_index);
}

// Select up and down from the bookmark list
void display_bookmark_list_on_screen_Down(int selected_index, int Refresh_mode)
{
    if (!bookmark_display_buffer) {
        ESP_LOGE(TAG, "Bookmark display buffer not initialized");
        return;
    }
    
    Paint_SelectImage(bookmark_display_buffer);
    
    int list_start_y = 100; 
    int item_height = 100; 
    
    int selection_old = selected_index - 1;
    if (selection_old < 0) {
        selection_old = g_fiction_ctx.bookmark_count - 1;
    }

    int y_pos_old = list_start_y + selection_old * item_height;
    int y_pos_new = list_start_y + selected_index * item_height;

    // Clear the old selected mark
    Paint_DrawRectangle(15, y_pos_old + 2, SCREEN_WIDTH - 15, y_pos_old + item_height + 2, WHITE, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(25, y_pos_old + 5, "  ", &Font18_UTF8, WHITE, BLACK);

    // Draw a new selected mark
    Paint_DrawRectangle(15, y_pos_new + 2, SCREEN_WIDTH - 15, y_pos_new + item_height + 2, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(25, y_pos_new + 5, ">", &Font18_UTF8, WHITE, BLACK);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(bookmark_display_buffer);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(bookmark_display_buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    }
    
    ESP_LOGI(TAG, "Bookmark selection moved down: %d -> %d", selection_old, selected_index);
}

void display_bookmark_list_on_screen_Up(int selected_index, int Refresh_mode)
{
    if (!bookmark_display_buffer) {
        ESP_LOGE(TAG, "Bookmark display buffer not initialized");
        return;
    }
    Paint_SelectImage(bookmark_display_buffer);
    
    int list_start_y = 100; 
    int item_height = 100;
    
    int selection_old = selected_index + 1;
    if (selection_old >= g_fiction_ctx.bookmark_count) {
        selection_old = 0;
    }

    int y_pos_old = list_start_y + selection_old * item_height;
    int y_pos_new = list_start_y + selected_index * item_height;

    // Clear the old selected mark
    Paint_DrawRectangle(15, y_pos_old + 2, SCREEN_WIDTH - 15, y_pos_old + item_height + 2, WHITE, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(25, y_pos_old + 5, "  ", &Font18_UTF8, WHITE, BLACK);

    // Draw a new selected mark
    Paint_DrawRectangle(15, y_pos_new + 2, SCREEN_WIDTH - 15, y_pos_new + item_height + 2, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(25, y_pos_new + 5, ">", &Font18_UTF8, WHITE, BLACK);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(bookmark_display_buffer);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(bookmark_display_buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    }
    
    ESP_LOGI(TAG, "Bookmark selection moved up: %d -> %d", selection_old, selected_index);
}


// The bookmark operation menu is displayed
void display_bookmark_action_menu_on_screen(fiction_context_t* ctx, int bookmark_index, int option_selection) {
    if (!bookmark_preview_buffer) {
        ESP_LOGE(TAG, "Bookmark display buffer not initialized");
        return;
    }
    
    Paint_NewImage(bookmark_preview_buffer, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SelectImage(bookmark_preview_buffer);
    Paint_Clear(WHITE);
    
    Paint_DrawString_CN(10, 20, "书签操作", &Font24_UTF8, WHITE, BLACK);
    Paint_DrawLine(10, 20 + Font24_UTF8.Height+5, SCREEN_WIDTH - 10, 20 + Font24_UTF8.Height+5, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    
    int info_start_y = 80;
    
    char bookmark_title[100];
    snprintf(bookmark_title, sizeof(bookmark_title), "书签 %d", bookmark_index + 1);
    Paint_DrawString_CN(10, info_start_y, bookmark_title, &Font18_UTF8, WHITE, BLACK);
    
    char page_info[50];
    snprintf(page_info, sizeof(page_info), "位置: 第 %d 页", ctx->bookmarks[bookmark_index].page + 1);
    Paint_DrawString_CN(10, info_start_y + Font18_UTF8.Height + 5, page_info, &Font18_UTF8, WHITE, BLACK);
    
    char progress_info[50];
    snprintf(progress_info, sizeof(progress_info), "进度: %.1f%%", ctx->bookmarks[bookmark_index].progress);
    Paint_DrawString_CN(10, info_start_y + Font18_UTF8.Height * 2 + 10, progress_info, &Font18_UTF8, WHITE, BLACK);
    
    // Content Preview
    Paint_DrawString_CN(10, info_start_y + Font18_UTF8.Height * 3 + 15, "内容预览:", &Font16_UTF8, WHITE, BLACK);

    char preview[128];
    strncpy(preview, ctx->bookmarks[bookmark_index].content_preview, sizeof(preview) - 1);
    preview[sizeof(preview) - 1] = '\0';
    
    int chars_per_line;
    if (strstr(g_display_ctx.encoding, "GBK") || strstr(g_display_ctx.encoding, "GB2312")) {
        chars_per_line = (SCREEN_WIDTH-20) / Font16_GBK.Width_CH;  
    } else {
        chars_per_line = (SCREEN_WIDTH-20) / Font16_UTF8.Width_CH;
    }
    
    int preview_y = info_start_y + Font18_UTF8.Height * 3 + 20 + Font16_UTF8.Height;
    int preview_len = strlen(preview);
    int pos = 0;
    int line_count = 0;
    
    // Display preview content
    while (pos < preview_len && line_count < 3 && preview_y < SCREEN_HEIGHT - 250) {
        char line[60];
        int chars_copied = copy_chars_by_count(preview + pos, line, chars_per_line, g_display_ctx.encoding);
        if (chars_copied > 0) {
            if (strstr(g_display_ctx.encoding, "GBK") || strstr(g_display_ctx.encoding, "GB2312")) {
                Paint_DrawString_CN(10, preview_y, line, &Font16_GBK, WHITE, BLACK);
            } else {
                Paint_DrawString_CN(10, preview_y, line, &Font16_UTF8, WHITE, BLACK);
            }
            preview_y += Font16_UTF8.Height + 5;
            pos += chars_copied;
            line_count++;
        } else {
            break;
        }
    }
    
    // Operation options
    int options_start_y = SCREEN_HEIGHT - 240;
    Paint_DrawLine(20, options_start_y - 20, SCREEN_WIDTH - 20, options_start_y - 20, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    
    Paint_DrawString_CN(20, options_start_y - 15, "选择操作:", &Font18_UTF8, WHITE, BLACK);
    
    const char* options[] = {"跳转到此书签", "删除此书签", "返回书签列表"};
    int option_height = Font18_UTF8.Height+10; 
    
    for (int i = 0; i < 3; i++) {
        int option_y = options_start_y + Font18_UTF8.Height + i * option_height-10;

        char option_text[50];
        snprintf(option_text, sizeof(option_text), "%d. %s", i + 1, options[i]);
        Paint_DrawString_CN(55, option_y+5, option_text, &Font18_UTF8, WHITE, BLACK);
    }
    // Selected item mark
    Paint_DrawRectangle(15, (options_start_y + Font18_UTF8.Height + option_selection * option_height-10), SCREEN_WIDTH - 15, (options_start_y + Font18_UTF8.Height + option_selection * option_height-10) + option_height, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(25, (options_start_y + Font18_UTF8.Height + option_selection * option_height-10)+5, ">", &Font18_UTF8, BLACK, WHITE);
    
    Paint_DrawLine(10, SCREEN_HEIGHT - 70, SCREEN_WIDTH - 10, SCREEN_HEIGHT - 70, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);
    Paint_DrawString_CN(10, SCREEN_HEIGHT - 65, "↑↓选择,确认:执行", &Font16_UTF8, WHITE, BLACK);
    Paint_DrawString_CN(10, SCREEN_HEIGHT - 32, "双击确认/Boot:返回书签列表", &Font16_UTF8, WHITE, BLACK);

    display_time_bet_fiction(bookmark_preview_buffer);

    EPD_Display_Partial(bookmark_preview_buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    ESP_LOGI(TAG, "Full-screen bookmark action menu displayed: bookmark %d, option %d", bookmark_index, option_selection);
}


// Select functions up and down in the bookmark operation menu
void display_bookmark_action_menu_on_screen_Down(int option_selection, int Refresh_mode)
{
    if (!bookmark_preview_buffer) {
        ESP_LOGE(TAG, "Bookmark preview buffer not initialized");
        return;
    }
    
    Paint_SelectImage(bookmark_preview_buffer);
    
    int options_start_y = SCREEN_HEIGHT - 240;
    int option_height = Font18_UTF8.Height + 10;
    
    int selection_old = option_selection - 1;
    if (selection_old < 0) {
        selection_old = 2;
    }
    
    int y_pos_old = options_start_y + Font18_UTF8.Height + selection_old * option_height - 10;
    int y_pos_new = options_start_y + Font18_UTF8.Height + option_selection * option_height - 10;

    Paint_DrawRectangle(15, y_pos_old, SCREEN_WIDTH - 15, y_pos_old + option_height, WHITE, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(25, y_pos_old + 5, "  ", &Font18_UTF8, WHITE, BLACK);

    Paint_DrawRectangle(15, y_pos_new, SCREEN_WIDTH - 15, y_pos_new + option_height, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(25, y_pos_new + 5, ">", &Font18_UTF8, BLACK, WHITE);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(bookmark_preview_buffer);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(bookmark_preview_buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    }
    
    ESP_LOGI(TAG, "Bookmark action selection moved down: %d -> %d", selection_old, option_selection);
}

void display_bookmark_action_menu_on_screen_Up(int option_selection, int Refresh_mode)
{
    if (!bookmark_preview_buffer) {
        ESP_LOGE(TAG, "Bookmark preview buffer not initialized");
        return;
    }
    
    Paint_SelectImage(bookmark_preview_buffer);
    
    int options_start_y = SCREEN_HEIGHT - 240;
    int option_height = Font18_UTF8.Height + 10;
    
    int selection_old = option_selection + 1;
    if (selection_old > 2) {
        selection_old = 0;
    }
    
    int y_pos_old = options_start_y + Font18_UTF8.Height + selection_old * option_height - 10;
    int y_pos_new = options_start_y + Font18_UTF8.Height + option_selection * option_height - 10;

    Paint_DrawRectangle(15, y_pos_old, SCREEN_WIDTH - 15, y_pos_old + option_height, WHITE, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(25, y_pos_old + 5, "  ", &Font18_UTF8, WHITE, BLACK);

    Paint_DrawRectangle(15, y_pos_new, SCREEN_WIDTH - 15, y_pos_new + option_height, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    Paint_DrawString_CN(25, y_pos_new + 5, ">", &Font18_UTF8, BLACK, WHITE);

    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(bookmark_preview_buffer);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(bookmark_preview_buffer, 0, 0, EPD_WIDTH, EPD_HEIGHT);
    }
    
    ESP_LOGI(TAG, "Bookmark action selection moved up: %d -> %d", selection_old, option_selection);
}

// Display the loading interface
void display_loading_fiction(const char* message, int Refresh_mode)
{
    // Check the input parameters
    if (!message) {
        ESP_LOGE(TAG, "Loading message is NULL");
        return;
    }
    
    if (!page_backup_buffer) {
        ESP_LOGE(TAG, "page_backup_buffer buffer is NULL");
        return;
    }

    Paint_NewImage(page_backup_buffer, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(page_backup_buffer);
    Paint_Clear(WHITE);
    
    cFONT* font = &Font24_UTF8;
    
    int message_len = strlen(message);
    if (message_len > 100) {
        ESP_LOGW(TAG, "Loading message too long: %d chars", message_len);
        message_len = 100;
    }

    int estimated_width = message_len * (font->Width_CH / 2);
    int text_x = (SCREEN_WIDTH - estimated_width) / 2;
    int text_y = (SCREEN_HEIGHT - font->Height) / 2;
    
    if (text_x < 10) text_x = 10;
    if (text_x > SCREEN_WIDTH - 50) text_x = SCREEN_WIDTH - 50;
    if (text_y < 10) text_y = 10;
    if (text_y > SCREEN_HEIGHT - font->Height - 10) text_y = SCREEN_HEIGHT - font->Height - 10;

    char safe_message[101];
    strncpy(safe_message, message, 100);
    safe_message[100] = '\0';
    
    Paint_DrawString_CN(text_x, text_y, safe_message, font, BLACK, WHITE);
    
    if (Refresh_mode == Global_refresh) {
        EPD_Display_Base(page_backup_buffer);
    } else if(Refresh_mode == Partial_refresh){
        EPD_Display_Partial(page_backup_buffer,0,0,EPD_WIDTH,EPD_HEIGHT);
    }
}



static void Forced_refresh_fiction(uint8_t *EDP_buffer)
{
    EPD_Display_Base(EDP_buffer);
}
static void Refresh_page_fiction(uint8_t *EDP_buffer)
{
    EPD_Display_Partial(EDP_buffer,0,0,EPD_WIDTH,EPD_HEIGHT);
}
static void display_fiction_time_last(Time_data rtc_time)
{
    char Time_str[20]={0};
    int hours = rtc_time.hours;
    int minutes = rtc_time.minutes-1;

    if(minutes < 0){
        minutes = 59;
        hours = rtc_time.hours - 1;
        if(hours < 0 )
            hours = 23;
    }

    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", hours, minutes);
    Paint_DrawString_EN(20, 11, Time_str, &Font16, WHITE, BLACK);

    // EPD_Display_Partial(Image_Fiction,0,0,EPD_WIDTH,EPD_HEIGHT);
}
static void display_fiction_time(Time_data rtc_time)
{
    char Time_str[16]={0};
    int BAT_Power;
    char BAT_Power_str[16]={0};

    snprintf(Time_str, sizeof(Time_str), "%02d:%02d", rtc_time.hours, rtc_time.minutes);
    Paint_DrawString_EN(20, 11, Time_str, &Font16, WHITE, BLACK);
#if defined(CONFIG_IMG_SOURCE_EMBEDDED)
    if (wifi_enable) Paint_ReadBmp(gImage_WIFI, 326, 8, 32, 32);
    Paint_ReadBmp(gImage_BAT, 370, 17, 32, 16);
#elif defined(CONFIG_IMG_SOURCE_TFCARD)
    if (wifi_enable) GUI_ReadBmp(BMP_WIFI_PATH, 326, 8);
    GUI_ReadBmp(BMP_BAT_PATH, 370, 17);
#endif
    BAT_Power = get_battery_power();
    ESP_LOGI("BAT_Power", "BAT_Power = %d%%",BAT_Power);
    snprintf(BAT_Power_str, sizeof(BAT_Power_str), "%d%%", BAT_Power);
    if(BAT_Power == -1) BAT_Power = 20;
    else BAT_Power = BAT_Power * 20 / 100;
    Paint_DrawString_EN(411, 11, BAT_Power_str, &Font16, WHITE, BLACK);
    Paint_DrawRectangle(375, 22, 395, 30, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawRectangle(375, 22, 375+BAT_Power, 30, BLACK, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    Paint_DrawLine(2, 54, EPD_HEIGHT-2, 54, BLACK, DOT_PIXEL_2X2, LINE_STYLE_SOLID);
    // EPD_Display_Partial(Image_Fiction,0,0,EPD_WIDTH,EPD_HEIGHT);
}

// calculate display width
static int calculate_display_width(const char* str)
{
    int width = 0;
    const char* p = str;
    
    while (*p) {
        if ((*p & 0x80) == 0) {
            width += 9;
            p++;
        } else {
            width += 18;
            if ((*p & 0xE0) == 0xC0) p += 2;
            else if ((*p & 0xF0) == 0xE0) p += 3;
            else if ((*p & 0xF8) == 0xF0) p += 4;
            else p++;
        }
    }
    return width;
}
// Truncate the file name to fit the display width
static void truncate_filename_for_display(const char* filename, char* display_name, int max_len, int max_width)
{
    int filename_width = calculate_display_width(filename);
    
    if (filename_width <= max_width) {
        strncpy(display_name, filename, max_len - 1);
        display_name[max_len - 1] = '\0';
    } else {
        const char* ext = strrchr(filename, '.');
        int ext_len = ext ? strlen(ext) : 0;
        int available_len = max_len - ext_len - 4; 
        
        strncpy(display_name, filename, available_len);
        display_name[available_len] = '\0';
        strcat(display_name, "...");
        if (ext) strcat(display_name, ext);
    }
}
// Update the selected items (only partially refresh the selected box)
static void update_fiction_selection(int new_selected)
{
    static int last_selected = 0;
    
    if (last_selected == new_selected) return;
    
    int y_start = HEADER_HEIGHT;
    int item_height = Font18_UTF8.Height + 10;
    
    if (last_selected >= 0) {
        int old_y = y_start + last_selected * item_height;
        Paint_DrawRectangle(5, old_y - 5, 475, old_y + Font18_UTF8.Height + 5, WHITE, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    }
    
    int new_y = y_start + new_selected * item_height;
    Paint_DrawRectangle(5, new_y - 5, 475, new_y + Font18_UTF8.Height + 5, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
    
    last_selected = new_selected;
    
    // 局部刷新
    Refresh_page_fiction(Image_Fiction);
}

// Truncate the string to the specified display width
static void truncate_string_by_width(const char* source, char* dest, int dest_size, int max_width, cFONT *Font) {
    int current_width = 0;
    int i = 0;
    int dest_pos = 0;
    
    int ellipsis_width = Font->Width_EN * 3;
    int available_width = max_width - ellipsis_width;
    
    while (source[i] != '\0' && dest_pos < dest_size - 4) {
        unsigned char ch = (unsigned char)source[i];
        int char_width = 0;
        int char_bytes = 1;
        
        if (ch < 0x80) {
            char_width = Font->Width_EN;
            char_bytes = 1;
        } else if ((ch & 0xE0) == 0xC0) {
            char_width = Font->Width_CH;
            char_bytes = 2;
        } else if ((ch & 0xF0) == 0xE0) {
            char_width = Font->Width_CH;
            char_bytes = 3;
        } else if ((ch & 0xF8) == 0xF0) {
            char_width = Font->Width_CH;
            char_bytes = 4;
        } else {
            char_width = Font->Width_EN;
            char_bytes = 1;
        }
        if (current_width + char_width > available_width) {
            break;
        }

        for (int j = 0; j < char_bytes && source[i + j] != '\0' && dest_pos < dest_size - 4; j++) {
            dest[dest_pos++] = source[i + j];
        }
        
        current_width += char_width;
        i += char_bytes;
    }
    
    if (source[i] != '\0') {
        dest[dest_pos++] = '.';
        dest[dest_pos++] = '.';
        dest[dest_pos++] = '.';
    }
    
    dest[dest_pos] = '\0';
}
// Calculate the number of files displayed per page in the file list
static int get_fiction_page_size(void)
{
    int header_height = HEADER_HEIGHT;    
    int status_height = Font16.Height * 2; 
    int available_height = EPD_WIDTH - header_height - status_height-10;
    
    int item_height = Font18_UTF8.Height + 10;
    
    int page_size = available_height / item_height;
    
    return page_size;
}

// Determine the file type
static const char* get_file_type(const char* filename)
{
    const char* ext = strrchr(filename, '.');
    if (!ext) return "unknown";
    if (strcasecmp(ext, ".txt") == 0) return "text";
    if (strcasecmp(ext, ".wav") == 0 || strcasecmp(ext, ".mp3") == 0) return "audio";
    if (strcasecmp(ext, ".jpg") == 0 || strcasecmp(ext, ".png") == 0 || strcasecmp(ext, ".bmp") == 0) return "image";
    return "unknown";
}

// Display file list
static void display_fiction_file_list(file_entry_t* entries, int num_entries, int current_selection, int page_index, int total_pages)
{
    Paint_DrawRectangle(5, 58, 475, 789, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    int start_y = HEADER_HEIGHT;
    int max_display = get_fiction_page_size();

    int icon_width = GUI_WIDTH + 5;
    int available_width = 480 - 10 - icon_width - 20;

    for (int i = 0; i < num_entries && i < max_display; i++) {
        int y_pos = start_y + i * (Font18_UTF8.Height + 10 );
        
        const char* file_type = get_file_type(entries[i].name);
        if (strcmp(file_type, "text") == 0) {
            #if defined(CONFIG_IMG_SOURCE_EMBEDDED)
                Paint_ReadBmp(gImage_text,10,y_pos-1,32,32);
            #elif defined(CONFIG_IMG_SOURCE_TFCARD)
                GUI_ReadBmp(BMP_TEXT_PATH,10,y_pos-1);
            #endif
        } else {
            #if defined(CONFIG_IMG_SOURCE_EMBEDDED)
                Paint_ReadBmp(gImage_rests,10,y_pos-1,32,32);
            #elif defined(CONFIG_IMG_SOURCE_TFCARD)
                GUI_ReadBmp(BMP_RESTS_PATH,10,y_pos-1);
            #endif
        }
        
        char display_name[100]; 
        truncate_string_by_width(entries[i].name, display_name, sizeof(display_name), available_width, &Font18_UTF8);
        
        if (is_chinese_filename(entries[i].name)) {
            Paint_DrawString_CN(10 + icon_width, y_pos, display_name, &Font18_UTF8, WHITE, BLACK);
        } else {
            Paint_DrawString_EN(10 + icon_width, y_pos, display_name, &Font16, WHITE, BLACK);
        }

        if (i == current_selection) {
            Paint_DrawRectangle(5, y_pos - 5, 475, y_pos + Font18_UTF8.Height + 5, BLACK, DOT_PIXEL_2X2, DRAW_FILL_EMPTY);
        }
    }
    
    int status_y = EPD_WIDTH - (Font12_UTF8.Height*2+15);
    Paint_DrawLine(10, status_y - 5, EPD_HEIGHT - 10, status_y - 5, BLACK, DOT_PIXEL_1X1, LINE_STYLE_SOLID);

    char page_info[50];
    snprintf(page_info, sizeof(page_info), "第%d/%d页 共%d个文件", page_index + 1, total_pages, num_entries);
    Paint_DrawString_CN(10, EPD_WIDTH-(Font12_UTF8.Height*2 + 10), page_info, &Font12_UTF8, WHITE, BLACK);
    
    Paint_DrawString_CN(10, EPD_WIDTH - (Font12_UTF8.Height + 5), "↑↓选择,单击确认:打开,双击确认:返回上级", &Font12_UTF8, WHITE, BLACK);

    EPD_Display_Partial(Image_Fiction, 0, 0, EPD_WIDTH, EPD_HEIGHT);
}



// Determine the encoding format of the txt file
static const char* detect_txt_encoding(const char* filepath)
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
            int next = fgetc(fp);
            if (next != EOF && (next & 0xC0) == 0x80) utf8_count++;
        } else if (c >= 0x81 && c <= 0xFE) {
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

// The file selection menu displayed in pagination
int page_fiction_file(void)
{
    if((Image_Fiction = (UBYTE *)heap_caps_malloc(EPD_SIZE_MONO,MALLOC_CAP_SPIRAM)) == NULL) 
    {
        ESP_LOGE(TAG,"Failed to apply for black memory...");
        // return ESP_FAIL;
    }
    Paint_NewImage(Image_Fiction, EPD_WIDTH, EPD_HEIGHT, 270, WHITE);
    Paint_SetScale(2);
    Paint_SelectImage(Image_Fiction);
    Paint_Clear(WHITE);

    // Calculate pagination parameters
    int page_size = get_fiction_page_size(); 
    if (page_size < 1) page_size = 5;

    // Allocate a large array with PSRAM to store all the files and directories in the current directory
    file_entry_t* entries = (file_entry_t*)heap_caps_malloc(page_size * sizeof(file_entry_t), MALLOC_CAP_SPIRAM);
    if (!entries) {
        ESP_LOGE(TAG, "The memory allocation for the file list failed");
        return -1;
    }
    int total_num = 0; 
    int num = 0; 
    int num_selection = 0;
    int page_index = 0;
    bool first_display = true; 

    Paint_DrawRectangle(5, 58, 475, 789, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);
    uint16_t x_or = reassignCoordinates_CH(240, " 正在读取文件目录... ", &Font24_UTF8);
    Paint_DrawString_CN(x_or, 410, " 正在读取文件目录... ", &Font24_UTF8, BLACK, WHITE);
    Refresh_page_fiction(Image_Fiction);
    Paint_DrawRectangle(5, 58, 475, 789, WHITE, DOT_PIXEL_1X1, DRAW_FILL_FULL);

    total_num = get_dir_file_count("/sdcard/fiction");
    int total_pages = (total_num + page_size - 1) / page_size;
    if (total_pages == 0) total_pages = 1;

    num = list_dir_page("/sdcard/fiction", entries, page_index * page_size, page_size);

    
    int button;
    int time_count = 0;
    xSemaphoreTake(rtc_mutex, portMAX_DELAY);
    Time_data rtc_time = PCF85063_GetTime();
    xSemaphoreGive(rtc_mutex);
    int last_minutes = -1;
    last_minutes = rtc_time.minutes;
    display_fiction_time(rtc_time);

    display_fiction_file_list(entries, num, num_selection, page_index, total_pages);


    while (1) {
        button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000)); 
        if(button == -1) time_count++;

        if((time_count >= EPD_Sleep_Time)) {
            ESP_LOGI("home", "EPD_Sleep");
            EPD_Sleep();
            int sleep_js = 0;
            while(1)
            {
                button = wait_key_event_and_return_code(pdMS_TO_TICKS(1000));
                if (button == 12){
                    ESP_LOGI("home", "EPD_Init");
                    EPD_Init();
                    // Forced_refresh_fiction(Image_Fiction);
                    time_count = 0;
                    break;
                } else if (button == 8 || button == 22 || button == 14 || button == 0 || button == 7){
                    ESP_LOGI("home", "EPD_Init");
                    EPD_Init();
                    Refresh_page_fiction(Image_Fiction);
                    time_count = 0;
                    break;
                }
                xSemaphoreTake(rtc_mutex, portMAX_DELAY);
                rtc_time = PCF85063_GetTime();
                xSemaphoreGive(rtc_mutex);
                if(rtc_time.minutes != last_minutes) {
                    last_minutes = rtc_time.minutes;
                    ESP_LOGI("home", "EPD_Init");
                    EPD_Init();
                    // display_fiction_time_last(rtc_time);
                    Refresh_page_fiction(Image_Fiction);
                    display_fiction_time(rtc_time);
                    Refresh_page_fiction(Image_Fiction);
                    ESP_LOGI("home", "EPD_Sleep");
                    EPD_Sleep();
                    sleep_js++;
                    if(sleep_js > Unattended_Time){
                        ESP_LOGI("home", "pwr_off");
                        axp_pwr_off();
                    }
                }
            }
        }

        if (button == 14) {
            time_count = 0;
            num_selection++;          
            if (num_selection >= page_size || num_selection >= total_num) {
                ESP_LOGI("num", "Turn to the next page");
                page_index++;
                if(page_index * page_size >= total_num)  page_index = 0;
                num = list_dir_page("/sdcard/fiction", entries, page_index * page_size, page_size);
                num_selection = 0;
                display_fiction_file_list(entries, num, num_selection, page_index, total_pages);    
            } else {
                update_fiction_selection(num_selection);
            }
            
        } else if (button == 0) {
            time_count = 0;
            num_selection--;
            if (num_selection < 0) {
                ESP_LOGI("num", "Turn to the previous page");
                page_index--;
                if(page_index < 0)  page_index = total_pages -1;
                num = list_dir_page("/sdcard/fiction", entries, page_index * page_size, page_size);
                num_selection = num-1;
                display_fiction_file_list(entries, num, num_selection, page_index, total_pages);
            } else {
                update_fiction_selection(num_selection);
            }
            
        } else if (button == 7) { 
            ESP_LOGI("num", "The selected file is %s", entries[num_selection].name);
            if (strcasecmp(get_file_type(entries[num_selection].name), "text") == 0) {
                char filepath[300];
                snprintf(filepath, sizeof(filepath), "/sdcard/fiction/%s", entries[num_selection].name);
                ESP_LOGI("file", "try open: %s", filepath);
                const char* encoding = detect_txt_encoding(filepath);
                ESP_LOGI("file", "open-file: %s, encoding: %s", entries[num_selection].name, encoding);
                page_fiction_open_file(filepath, encoding);
            } 
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            Paint_SelectImage(Image_Fiction);
            Refresh_page_fiction(Image_Fiction);
            time_count = 0;
        } else if (button == 8 || button == 22) {
            heap_caps_free(entries);
            heap_caps_free(Image_Fiction);
            return -1;
        } else if (button == 12) {
            ESP_LOGI("home", "EPD_Init");
            EPD_Init();
            Forced_refresh_fiction(Image_Fiction);
            time_count = 0;
        }

        xSemaphoreTake(rtc_mutex, portMAX_DELAY);
        rtc_time = PCF85063_GetTime();
        xSemaphoreGive(rtc_mutex);
        if(rtc_time.minutes != last_minutes) {
            last_minutes = rtc_time.minutes;
            display_fiction_time(rtc_time);
            Refresh_page_fiction(Image_Fiction);
        }
    }
    heap_caps_free(entries);
    heap_caps_free(Image_Fiction);
}

