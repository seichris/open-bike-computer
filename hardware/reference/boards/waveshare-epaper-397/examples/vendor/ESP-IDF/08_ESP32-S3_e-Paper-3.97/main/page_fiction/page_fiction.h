#ifndef PAGE_FICTION_H
#define PAGE_FICTION_H

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include "font.h"

#define MAX_LINE_LENGTH 256
#define LINES_PER_PAGE 20
#define MAX_FILEPATH_LEN 512

#define MAX_BOOKMARKS 6  // Save up to 6 bookmarks

typedef struct {
    size_t position;
    int page;
    float progress;           // progress percentage
    char description[64];     // Bookmark description
    char content_preview[128]; // Content Preview (the first few characters)
} bookmark_t;

typedef struct {
    char filepath[MAX_FILEPATH_LEN];
    char encoding[32];
    size_t current_position;
    int current_page;
    size_t file_size;
    bool is_open;
    bookmark_t bookmarks[MAX_BOOKMARKS];  // Bookmark array
    int bookmark_count;                   // The number of bookmarks
} fiction_context_t;


// Dual cache type
typedef enum {
    BUFFER_PREVIOUS = 0,  // Previous page cache
    BUFFER_CURRENT  = 1,  // Current page cache
    BUFFER_NEXT     = 2   // Next page cache
} page_buffer_type_t;

// Font size enumeration
typedef enum {
    FONT_SIZE_12 = 0,
    FONT_SIZE_16 = 1,
    FONT_SIZE_18 = 2,     // default font
    FONT_SIZE_24 = 3,
    FONT_SIZE_28 = 4,
    FONT_SIZE_36 = 5,
    FONT_SIZE_48 = 6,
    FONT_SIZE_MAX
} font_size_t;

// Page cache structure
typedef struct {
    uint8_t* buffer;           // Page image cache
    char content[2048];        // Page text content
    size_t file_position;      // The position of this page in the file
    int page_number;           // page number
    int lines_count;           // line number
    bool is_valid;             // Is the cache valid?
    bool is_rendering;         // Is it rendering?
} page_cache_t;

// The novel shows the context
typedef struct {
    // file information
    char filepath[256];
    char encoding[32];
    size_t file_size;
    bool is_open;
    
    // current state
    size_t current_position;
    int current_page;
    font_size_t current_font_size;
    
    // Three cache zones
    page_cache_t page_buffers[3];  // Previous page, current page, next page
    int current_buffer_index;      // The currently displayed cache index
    
    // display parameter
    int lines_per_page;
    int chars_per_line;
    cFONT* current_font;
    
    // Bookmarks and other information...
    int bookmark_count;
    struct {
        size_t position;
        int page;
        float progress;
        char description[64];
        char content_preview[128];
    } bookmarks[10];
} fiction_display_context_t;


#ifdef __cplusplus
extern "C" {
#endif


void page_fiction_open_file(const char* filepath, const char* encoding);
void page_fiction_task(void);
bool fiction_read_page(fiction_context_t* ctx, char lines[][MAX_LINE_LENGTH], int* line_count);
void fiction_save_progress(const fiction_context_t* ctx);
bool fiction_load_progress(fiction_context_t* ctx);
void fiction_close_file(fiction_context_t* ctx);

void init_fiction_display_buffers(void);
void free_fiction_display_buffers(void);
void switch_font_size(font_size_t font_size);
void render_page_to_buffer(page_cache_t* cache, const char* content, bool is_current);
void display_current_page(void);
void preload_next_page(void);
void preload_previous_page(void);
bool turn_to_next_page(void);
bool turn_to_previous_page(void);
void display_font_menu(font_size_t selected_font);
void page_fiction_display_task(void);
void preload_previous_page_task(void* pvParameters);
void preload_next_page_task(void* pvParameters);
void render_current_page_ui(page_cache_t* cache);
int count_characters(const char* str, const char* encoding);
void calculate_display_params(void);
int get_char_byte_length(const char* str, int pos, const char* encoding);
int copy_chars_by_count(const char* src, char* dst, int max_chars, const char* encoding);

void init_bookmark_display_buffers(void);
void free_bookmark_display_buffers(void);
void restore_bookmark_page(void);
void restore_current_page(void);
void display_bookmark_list_on_screen(fiction_context_t* ctx, int selected_index);
void display_bookmark_list_on_screen_Down(int selected_index, int Refresh_mode);
void display_bookmark_list_on_screen_Up(int selected_index, int Refresh_mode);
void display_bookmark_action_menu_on_screen(fiction_context_t* ctx, int bookmark_index, int option_selection);
void display_bookmark_action_menu_on_screen_Down(int option_selection, int Refresh_mode);
void display_bookmark_action_menu_on_screen_Up(int option_selection, int Refresh_mode);
void display_time_bet_fiction(uint8_t* buffer);
void display_loading_fiction(const char* message, int Refresh_mode);


int page_fiction_file(void);

#ifdef __cplusplus
}
#endif



#endif