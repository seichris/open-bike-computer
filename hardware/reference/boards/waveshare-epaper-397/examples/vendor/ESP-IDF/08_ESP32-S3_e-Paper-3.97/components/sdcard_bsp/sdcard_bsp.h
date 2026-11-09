#ifndef SDCARD_BSP_H
#define SDCARD_BSP_H
#include "driver/sdmmc_host.h"
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MAX_ENTRY_NUM 100      // Maximum number of files/directories
#define MAX_NAME_LEN  255     // The maximum length of a single file/directory name

// The image cache address before power failure
#define CLOCK_PARTIAL_PATH      "/sdcard/GUI/clock_partial.bin"

typedef struct {
    char name[MAX_NAME_LEN];
    bool is_dir;              // true= Directory, false= file
} file_entry_t;

extern QueueHandle_t sdcard_queuehandle;
extern sdmmc_card_t *card_host;
void _sdcard_init(void);
int list_dir_once(const char* path, file_entry_t *entries, int max_num);
void scan_files(const char* path);
void _scan_directory(const char *path);
uint32_t s_example_read_from_offset(const char *path, char *buffer, uint32_t len, uint32_t offset);
uint32_t s_example_wriet_from_offset(const char *path, char *buffer, uint32_t len, uint8_t mode);
int get_dir_file_count(const char* path);
int list_dir_page(const char* path, file_entry_t* entries, int start_index, int page_size);

bool sd_read_file_to_buffer(const char* path, uint8_t* buf, size_t buf_size);
bool sd_write_buffer_to_file(const char* path, const uint8_t* buf, size_t buf_size);


#ifdef __cplusplus
}
#endif

#endif