#include <stdio.h>
#include <string.h>
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "sdcard_bsp.h"
#include "esp_log.h"
#include "esp_err.h"
#include "ff.h"        // FatFs API
#include <dirent.h>


static const char *TAG = "_sdcard";

#define SDMMC_D0_PIN    15
#define SDMMC_D1_PIN    7
#define SDMMC_D2_PIN    8
#define SDMMC_D3_PIN    18
#define SDMMC_CLK_PIN   16
#define SDMMC_CMD_PIN   17

#define SDlist "/sdcard" // Mount point

sdmmc_card_t *card_host = NULL;
QueueHandle_t sdcard_queuehandle = NULL;

// Comparison function: Directory first, name ascending
static int entry_cmp(const void *a, const void *b) {
    const file_entry_t *ea = (const file_entry_t *)a;
    const file_entry_t *eb = (const file_entry_t *)b;
    // The directory is placed at the front.
    if (ea->is_dir != eb->is_dir) {
        return eb->is_dir - ea->is_dir;
    }
    // Name in ascending order (case-insensitive)
    return strcasecmp(ea->name, eb->name);
}

// SD card initialization
void _sdcard_init(void)
{
    esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 5,
        .allocation_unit_size = 32 * 1024,  // Set it to 32KB to support larger capacity
    };

    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.max_freq_khz = SDMMC_FREQ_HIGHSPEED;

    sdmmc_slot_config_t slot_config = SDMMC_SLOT_CONFIG_DEFAULT();
    slot_config.width = 4;
    slot_config.clk = SDMMC_CLK_PIN;
    slot_config.cmd = SDMMC_CMD_PIN;
    slot_config.d0 = SDMMC_D0_PIN;
    slot_config.d1 = SDMMC_D1_PIN;
    slot_config.d2 = SDMMC_D2_PIN;
    slot_config.d3 = SDMMC_D3_PIN;

    esp_err_t ret = esp_vfs_fat_sdmmc_mount(SDlist, &host, &slot_config, &mount_config, &card_host);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SD card mount failed: %s", esp_err_to_name(ret));
        switch (ret) {
            case ESP_ERR_NO_MEM:
                ESP_LOGE(TAG, "Insufficient memory");
                break;
            case ESP_ERR_INVALID_STATE:
                ESP_LOGE(TAG, "The SD card driver is not initialized");
                break;
            case ESP_ERR_NOT_FOUND:
                ESP_LOGE(TAG, "The SD card was not found");
                break;
            case ESP_FAIL:
                ESP_LOGE(TAG, "Mounting failed. It might be due to a damaged file system");
                break;
            default:
                ESP_LOGE(TAG, "Unknown error");
        }
        
        return;
    }
    ESP_LOGI(TAG, "SD card mounted at %s", SDlist);
    if (card_host != NULL) {
        sdmmc_card_print_info(stdout, card_host);
    }
}

/**
 * @brief Read all files and directories in the specified directory (without recursion) and save them to the entries array
 * @param path      Directory path, such as "/pic"
 * @param entries   Output array
 * @param max_num   Maximum capacity of the array
 * @return The actual number of files/directories read
 */
int list_dir_once(const char* path, file_entry_t *entries, int max_num)
{
    DIR *dir = opendir(path);
    if (!dir) {
        ESP_LOGE("sdscan", "Failed to open directory: %s", path);
        return 0;
    }
    struct dirent *entry;
    int count = 0;
    while ((entry = readdir(dir)) != NULL && count < max_num) {
        // Skip . and ..
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        strncpy(entries[count].name, entry->d_name, MAX_NAME_LEN - 1);
        entries[count].name[MAX_NAME_LEN - 1] = '\0';
        entries[count].is_dir = (entry->d_type == DT_DIR);
        count++;
    }
    closedir(dir);

    // Sorting: Directory first, name in ascending order
    if (count > 1) {
        qsort(entries, count, sizeof(file_entry_t), entry_cmp);
    }
    return count;
}

void scan_files(const char* path)
{
    ESP_LOGE("scan_files","%s",path);
    DIR *dir = opendir(path);
    if (!dir) {
        ESP_LOGE("sdscan", "Failed to open directory: %s", path);
        return;
    }
    struct dirent *entry;
    char fullpath[300];
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (path[strlen(path) - 1] == '/')
            snprintf(fullpath, sizeof(fullpath), "%s%s", path, entry->d_name);
        else
            snprintf(fullpath, sizeof(fullpath), "%s/%s", path, entry->d_name);

        if (entry->d_type == DT_DIR) {
            ESP_LOGI("sdscan", "Directory: %s", fullpath);
            scan_files(fullpath);
        } else {
            ESP_LOGI("sdscan", "File: %s", fullpath);
            if (sdcard_queuehandle)
                xQueueSend(sdcard_queuehandle, fullpath, 1000);
        }
    }
    closedir(dir);
}

// Write documents
esp_err_t s_example_write_file(const char *path, char *data)
{
    esp_err_t err;
    if (card_host == NULL) return ESP_ERR_NOT_FOUND;
    err = sdmmc_get_status(card_host);
    if (err != ESP_OK) return err;

    FILE *f = fopen(path, "w");
    if (f == NULL) {
        ESP_LOGE(TAG, "Write Wrong path: %s", path);
        return ESP_ERR_NOT_FOUND;
    }
    fprintf(f, "%s", data);
    fclose(f);
    return ESP_OK;
}

// Read the file
esp_err_t s_example_read_file(const char *path, uint8_t *pxbuf, uint32_t *outLen)
{
    esp_err_t err;
    if (card_host == NULL) return ESP_ERR_NOT_FOUND;
    err = sdmmc_get_status(card_host);
    if (err != ESP_OK) return err;

    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        ESP_LOGE(TAG, "Read Wrong path: %s", path);
        return ESP_ERR_NOT_FOUND;
    }
    fseek(f, 0, SEEK_END);
    uint32_t unlen = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint32_t poutLen = fread((void *)pxbuf, 1, unlen, f);
    *outLen = poutLen;
    fclose(f);
    return ESP_OK;
}

// Read from the specified offset
uint32_t s_example_read_from_offset(const char *path, char *buffer, uint32_t len, uint32_t offset)
{
    esp_err_t err;
    if (card_host == NULL) {
        ESP_LOGE(TAG, "SD card not initialized (card == NULL)");
        return 0;
    }
    err = sdmmc_get_status(card_host);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SD card status check failed (card not present or unresponsive)");
        return 0;
    }
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        ESP_LOGE(TAG, "Failed to open file: %s", path);
        return 0;
    }
    fseek(f, offset, SEEK_SET);
    uint32_t bytesRead = fread((void *)buffer, 1, len, f);
    fclose(f);
    return bytesRead;
}

// Write from the specified offset
uint32_t s_example_wriet_from_offset(const char *path, char *buffer, uint32_t len, uint8_t mode)
{
    esp_err_t err;
    if (card_host == NULL) {
        ESP_LOGE(TAG, "SD card not initialized (card == NULL)");
        return 0;
    }
    err = sdmmc_get_status(card_host);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "SD card status check failed (card not present or unresponsive)");
        return 0;
    }
    FILE *f = NULL;
    if (mode == 0) {
        f = fopen(path, "w");
        if (f == NULL) {
            ESP_LOGE(TAG, "Failed to open file: %s", path);
            return 0;
        }
        fclose(f);
        return 0;
    } else {
        f = fopen(path, "ab");
        if (f == NULL) {
            ESP_LOGE(TAG, "Failed to open file: %s", path);
            return 0;
        }
        uint32_t bytesRead = fwrite((void *)buffer, 1, len, f);
        fclose(f);
        return bytesRead;
    }
}

// Get the total number of files in the directory
int get_dir_file_count(const char* path)
{
    DIR *dir = opendir(path);
    if (!dir) return 0;
    struct dirent *entry;
    int count = 0;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        count++;
    }
    closedir(dir);
    return count;
}


// Pagination to read directories
int list_dir_page(const char* path, file_entry_t* entries, int start_index, int page_size)
{
    DIR *dir = opendir(path);
    if (!dir) return 0;
    struct dirent *entry;
    int count = 0;
    int skip = 0;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (skip < start_index) {
            skip++;
            continue;
        }
        if (count >= page_size) break;
        strncpy(entries[count].name, entry->d_name, MAX_NAME_LEN - 1);
        entries[count].name[MAX_NAME_LEN - 1] = '\0';
        entries[count].is_dir = (entry->d_type == DT_DIR);
        count++;
    }
    closedir(dir);

    // Sorting: Directory first, name in ascending order
    if (count > 1) {
        qsort(entries, count, sizeof(file_entry_t), entry_cmp);
    }
    return count;
}

// Read the file from SD to the buffer (up to buf_size bytes)
bool sd_read_file_to_buffer(const char* path, uint8_t* buf, size_t buf_size)
{
    if (!path || !buf || buf_size == 0) return false;
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        ESP_LOGW("sdio", "The file cannot be opened for reading: %s", path);
        return false;
    }
    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    size_t to_read = (fsize > 0 && (size_t)fsize < buf_size) ? (size_t)fsize : buf_size;
    size_t r = fread(buf, 1, to_read, fp);
    if (r < buf_size) {
        memset(buf + r, 0xFF, buf_size - r);
    }
    fclose(fp);
    ESP_LOGI("sdio", "Read from SD %s -> %u bytes (buf_size=%u)", path, (unsigned)r, (unsigned)buf_size);
    return true;
}

// Write the buffer data to the SD file (overwrite)
bool sd_write_buffer_to_file(const char* path, const uint8_t* buf, size_t buf_size)
{
    if (!path || !buf || buf_size == 0) return false;
    FILE *fp = fopen(path, "wb");
    if (!fp) {
        ESP_LOGW("sdio", "The file cannot be opened for writing: %s", path);
        return false;
    }
    size_t w = fwrite(buf, 1, buf_size, fp);
    fclose(fp);
    ESP_LOGI("sdio", "Write to SD %s <- %u bytes", path, (unsigned)w);
    return w == buf_size;
}
