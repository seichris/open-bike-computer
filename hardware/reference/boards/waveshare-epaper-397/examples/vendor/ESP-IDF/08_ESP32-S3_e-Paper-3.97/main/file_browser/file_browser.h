#ifndef FILE_BROWSER_H
#define FILE_BROWSER_H

#include <stdint.h>
#include <stdbool.h>
#include "sdcard_bsp.h"


// A single file item cache structure
typedef struct {
    uint8_t* buffer;           // File item image cache
    file_entry_t entry;        // file information
    int item_index;            // Project Index
} file_item_buffer_t;

#ifdef __cplusplus
extern "C" {
#endif

// function declaration
void file_browser_task(void);
const char* get_file_type(const char* filename);
const char* detect_txt_encoding(const char* filepath);

// Display the relevant function declarations
void display_file_browser(const char* current_path, file_entry_t* entries, int num_entries, int current_selection, int page_number, int total_pages, int Refresh_mode);
void display_current_path(const char* path);
void format_path_for_display(const char* full_path, char* display_path, int display_size, int max_width);
void display_file_list(file_entry_t* entries, int num_entries, int current_selection);
void display_status_bar(int current_page, int total_pages, int total_items);
void display_loading(const char* message, int Refresh_mode);
bool is_chinese_filename(const char* filename);

// Function declarations related to the file system
int get_dir_file_count(const char* path);
int list_dir_page(const char* path, file_entry_t* entries, int offset, int limit);

// Turn the pages up and down
void Page_Down_browser(int current_selection, int Refresh_mode);
void Page_Up_browser(int current_selection, int Refresh_mode);

void Forced_refresh(void);
void Refresh_page(void);
int Sleep_wake(void);

void init_selection_buffers(void);
void render_file_item_base(file_entry_t entry, file_item_buffer_t* cache);
void extract_file_item_from_main(int item_index, file_item_buffer_t* cache);
void apply_selection_frame(file_item_buffer_t* cache, bool selected);
void update_file_item_to_main(file_item_buffer_t* cache);
void update_selection_efficiently(int current_selection, int Refresh_mode);
void free_selection_buffers(void);


#ifdef __cplusplus
}
#endif

#endif // FILE_BROWSER_H