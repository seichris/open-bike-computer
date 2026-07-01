/**
 * @file storage.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Storage definition and functions
 * @version 0.2.2
 * @date 2025-05
 */

#include "storage.hpp"
#include "driver/gpio.h"
#include "driver/sdspi_host.h"
#include "esp_log.h"
#include "esp_vfs_fat.h"
#include "freertos/task.h"
#include <SD.h>
#include <SPI.h>
#include <Wire.h>
#include <cmath>
#include <hal.hpp>
#include <iomanip>
#include <sstream>

#define SD_OCR_SDHC_CAP (1 << 30)

// extern const uint8_t SD_CS;
// extern const uint8_t SD_MISO;
// extern const uint8_t SD_MOSI;
// extern const uint8_t SD_CLK;

static const char *TAG = "Storage";

namespace {
std::string formatSize(uint64_t size) {
  static const char *suffixes[] = {"B", "KB", "MB", "GB", "TB"};
  int order = 0;
  double formatted_size = static_cast<double>(size);
  while (formatted_size >= 1024 &&
         order < sizeof(suffixes) / sizeof(suffixes[0]) - 1) {
    order++;
    formatted_size /= 1024;
  }
  std::ostringstream oss;
  oss << std::fixed << std::setprecision(2) << formatted_size << " "
      << suffixes[order];
  return oss.str();
}
} // namespace

/**
 * @brief Storage Class constructor
 */
Storage::Storage() : isSdLoaded(false), card(nullptr) {}

/**
 * @brief SD Card init with DMA using ESP-IDF
 */
esp_err_t Storage::initSD() {
  Serial.println("DEBUG: initSD() ENTRY");
#ifdef WAVESHARE_AMOLED_175
  Serial.println("DEBUG: Macro WAVESHARE_AMOLED_175 is DEFINED");
#else
  Serial.println("DEBUG: Macro WAVESHARE_AMOLED_175 is NOT defined");
#endif

#ifdef SPI_SHARED
  Serial.println("DEBUG: Macro SPI_SHARED is DEFINED");
#else
  Serial.println("DEBUG: Macro SPI_SHARED is NOT defined");
#endif

#ifdef WAVESHARE_AMOLED_175
  // Waveshare 1.75" AMOLED: Use DEDICATED HSPI bus to avoid conflict with
  // QSPI display. The default SPI (FSPI) shares resources with the display.
  // NOTE: Use HSPI constant, not SPI3_HOST (which fails with "out of range")
  // See WAVESHARE_HARDWARE.md.
  // Verified working pins: CS=41, MOSI=1, MISO=3, SCK=2

  Serial.println("Initializing SD Card (HSPI mode)...");
  Serial.printf("Pins: CS=%d, MOSI=%d, MISO=%d, SCK=%d\n", SD_CS, SD_MOSI,
                SD_MISO, SD_CLK);

  // Explicitly set CS as output and deselect before SPI init
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);

  // Create dedicated HSPI instance to isolate from QSPI display
  static SPIClass hspi(HSPI);
  hspi.begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS);

  if (!SD.begin(SD_CS, hspi, 4000000, "/sdcard")) {
    ESP_LOGE(TAG, "SD Card Mount Failed - check card insertion and format");
    isSdLoaded = false;
    return ESP_FAIL;
  }

  uint8_t cardType = SD.cardType();
  if (cardType == CARD_NONE) {
    ESP_LOGE(TAG, "No SD card detected");
    isSdLoaded = false;
    return ESP_FAIL;
  }

  const char *typeStr = "UNKNOWN";
  if (cardType == CARD_MMC)
    typeStr = "MMC";
  else if (cardType == CARD_SD)
    typeStr = "SD";
  else if (cardType == CARD_SDHC)
    typeStr = "SDHC";

  ESP_LOGI(TAG, "SD Card Type: %s, Size: %lluMB", typeStr,
           SD.cardSize() / (1024 * 1024));

  // Debug: List root directory
  Serial.println("Listing SD Card Root:");
  File root = SD.open("/");
  if (root) {
    File file = root.openNextFile();
    while (file) {
      if (file.isDirectory()) {
        Serial.printf("  DIR : %s\n", file.name());
      } else {
        Serial.printf("  FILE: %s (%d bytes)\n", file.name(), file.size());
      }
      file = root.openNextFile();
    }
    root.close();
  }

  isSdLoaded = true;
  return ESP_OK;

#elif defined(SPI_SHARED)
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH); // De-select SD card initially

  SPI.begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS);

  if (!SD.begin(SD_CS, SPI, 4000000, "/sdcard")) {
    ESP_LOGE(TAG, "SD Card Mount Failed");
    isSdLoaded = false;
    return ESP_FAIL;
  } else {
    ESP_LOGI(TAG, "SD Card Mounted");
    isSdLoaded = true;
    return ESP_OK;
  }

#else
  // ESP-IDF SPI mode for other boards
  esp_err_t ret;

  sdmmc_host_t host = SDSPI_HOST_DEFAULT();
#ifdef TDECK_ESP32S3
  host.slot = SPI2_HOST;
#endif
#ifdef ICENAV_BOARD
  host.slot = SPI2_HOST;
#endif
#ifdef ESP32S3_N16R8
  host.slot = SPI2_HOST;
#endif
#ifdef ESP32_N16R4
  host.slot = HSPI_HOST;
  host.command_timeout_ms = 1000;
#endif

  sdspi_device_config_t slot_config = SDSPI_DEVICE_CONFIG_DEFAULT();
  slot_config.gpio_cs = (gpio_num_t)SD_CS;
  slot_config.host_id = (spi_host_device_t)host.slot;

  host.command_timeout_ms = 5000;

  spi_bus_config_t bus_cfg = {.mosi_io_num = (gpio_num_t)SD_MOSI,
                              .miso_io_num = (gpio_num_t)SD_MISO,
                              .sclk_io_num = (gpio_num_t)SD_CLK,
                              .quadwp_io_num = -1,
                              .quadhd_io_num = -1,
                              .max_transfer_sz = 4096,
                              .flags = 0,
                              .intr_flags = 0};

  host.max_freq_khz = 4000;

  gpio_set_pull_mode((gpio_num_t)SD_MISO, GPIO_PULLUP_ONLY);
  gpio_set_pull_mode((gpio_num_t)SD_MOSI, GPIO_PULLUP_ONLY);
  gpio_set_pull_mode((gpio_num_t)SD_CLK, GPIO_PULLUP_ONLY);
  gpio_set_pull_mode((gpio_num_t)SD_CS, GPIO_PULLUP_ONLY);

  ret = spi_bus_initialize((spi_host_device_t)host.slot, &bus_cfg,
                           SPI_DMA_CH_AUTO);
  if (ret != ESP_OK) {
    ESP_LOGE(TAG, "Failed to initialize SPI bus: %s (0x%x)",
             esp_err_to_name(ret), ret);
    return ret;
  }

  ESP_LOGI(TAG, "Initializing SD card");
  vTaskDelay(pdMS_TO_TICKS(100));

  esp_vfs_fat_mount_config_t mount_config = {.format_if_mount_failed = false,
                                             .max_files = 5,
                                             .allocation_unit_size = 8 * 1024};

  ret = esp_vfs_fat_sdspi_mount("/sdcard", &host, &slot_config, &mount_config,
                                &card);
  if (ret != ESP_OK) {
    if (ret == ESP_FAIL) {
      ESP_LOGE(TAG, "Failed to mount filesystem.");
    } else {
      ESP_LOGE(TAG, "Failed to initialize the card (%s).",
               esp_err_to_name(ret));
    }
    return ret;
  } else {
    ESP_LOGI(TAG, "SD card initialized successfully");
    sdmmc_card_print_info(stdout, card);
    isSdLoaded = true;
    return ESP_OK;
  }
#endif
}

/**
 * @brief SPIFFS initialization
 *
 * @return esp_err_t Error code for SPIFFS setup
 */
#include <FFat.h>

/**
 * @brief Initialize FFat (used as fallback or primary storage)
 *
 * @return esp_err_t Error code
 */
esp_err_t Storage::initSPIFFS() {
  ESP_LOGI(TAG, "Initializing FFat as /sdcard");

  // Mount FFat at "/sdcard" so the rest of the application thinks it's
  // reading from SD Partition label "ffat" is standard for the data partition
  // even when using FFat
  if (!FFat.begin(true, "/sdcard", 20, "ffat")) {
    ESP_LOGE(TAG, "FFat Mount Failed");
    return ESP_FAIL;
  }

  size_t total = FFat.totalBytes();
  size_t used = FFat.usedBytes();
  ESP_LOGI(TAG, "FFat Mounted at /sdcard. Total: %d, Used: %d", total, used);

  // Debug: List files (flat, no recursion to avoid file handle exhaustion)
  File root = FFat.open("/");
  if (root) {
    File file = root.openNextFile();
    while (file) {
      if (file.isDirectory()) {
        ESP_LOGI(TAG, "  DIR : %s", file.name());
      } else {
        ESP_LOGI(TAG, "  FILE: %s (%d)", file.name(), file.size());
      }
      file.close();
      file = root.openNextFile();
    }
    root.close();
  }

  return ESP_OK;
}

/**
 * @brief Get SD card information
 *
 * @return SDCardInfo structure containing SD card information
 */
SDCardInfo Storage::getSDCardInfo() {
  SDCardInfo info;

#ifndef SPI_SHARED
  if (card != nullptr) {
    info.name = std::string(reinterpret_cast<const char *>(card->cid.name));
    info.capacity =
        formatSize((uint64_t)(card->csd.capacity) * card->csd.sector_size);
    info.sector_size = card->csd.sector_size;
    info.read_block_len = card->csd.read_block_len;
    info.card_type = (card->ocr && SD_OCR_SDHC_CAP) ? "SDHC/SDXC" : "SDSC";

    FATFS *fs;
    DWORD fre_clust, fre_sect, tot_sect;

    if (f_getfree("0:", &fre_clust, &fs) == FR_OK) {
      tot_sect = (fs->n_fatent - 2) * fs->csize;
      fre_sect = fre_clust * fs->csize;

      uint64_t total_space_bytes = tot_sect / 2;
      uint64_t free_space_bytes = fre_sect / 2;
      uint64_t used_space_bytes = total_space_bytes - free_space_bytes;

      info.total_space = formatSize(total_space_bytes);
      info.free_space = formatSize(free_space_bytes);
      info.used_space = formatSize(used_space_bytes);
    } else {
      ESP_LOGE(TAG, "Failed to get filesystem info");
      info.total_space = "0 B";
      info.free_space = "0 B";
      info.used_space = "0 B";
    }
  } else
    ESP_LOGE(TAG, "SD Card not initialized");
#else
  uint8_t cardType = SD.cardType();
  if (cardType == CARD_MMC)
    info.card_type = "MMC";
  else if (cardType == CARD_SD)
    info.card_type = "SDSC";
  else if (cardType == CARD_SDHC)
    info.card_type = "SDHC";
  else
    info.card_type = "UNKNOWN";

  info.total_space = formatSize(SD.cardSize());
  info.free_space = formatSize((SD.totalBytes() - SD.usedBytes()));
  info.used_space = formatSize(SD.usedBytes());
#endif

  return info;
}

/**
 * @brief Get SD status
 *
 * @return true if SD card is loaded, false otherwise
 */
bool Storage::getSdLoaded() const { return isSdLoaded; }

/**
 * @brief Open a file on the SD card
 *
 * @param path Path to the file
 * @param mode Mode in which to open the file
 * @return FILE* Pointer to the opened file
 */
FILE *Storage::open(const char *path, const char *mode) {
#ifdef WAVESHARE_AMOLED_175
  // Reconfigure SPI bus before SD access - QSPI display operations may have
  // altered SPI state. This ensures the SD card SPI is properly configured.
  SPI.begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS);
#endif
  return fopen(path, mode);
}

/**
 * @brief Close a file on the SD card
 *
 * @param file Pointer to the file
 * @return int 0 on success, EOF on error
 */
int Storage::close(FILE *file) { return fclose(file); }

/**
 * @brief Get the size of a file on the SD card
 *
 * @param path Path to the file
 * @return size_t Size of the file in bytes
 */
size_t Storage::size(const char *path) {
  struct stat st;
  if (stat(path, &st) == 0)
    return st.st_size;
  return 0;
}

/**
 * @brief Read a specified number of bytes from a file into a buffer
 *
 * @param file Pointer to the file
 * @param buffer Buffer to read the bytes into
 * @param size Number of bytes to read
 * @return size_t Number of bytes actually read
 */
size_t Storage::read(FILE *file, uint8_t *buffer, size_t size) {
  if (!file)
    return 0;
  return fread(buffer, 1, size, file);
}

/**
 * @brief Read a specified number of chars from a file into a buffer
 *
 * @param file Pointer to the file
 * @param buffer Buffer to read the chars into
 * @param size Number of bytes to read
 * @return size_t Number of chars actually read
 */
size_t Storage::read(FILE *file, char *buffer, size_t size) {
  if (!file)
    return 0;
  return fread(buffer, 1, size, file);
}

/**
 * @brief Write a specified number of bytes from a buffer to a file
 *
 * @param file Pointer to the file
 * @param buffer Buffer containing the bytes to write
 * @param size Number of bytes to write
 * @return size_t Number of bytes actually written
 */
size_t Storage::write(FILE *file, const uint8_t *buffer, size_t size) {
  if (!file)
    return 0;
  return fwrite(buffer, 1, size, file);
}

/**
 * @brief Write a specified number of chars from a buffer to a file
 *
 * @param file Pointer to the file
 * @param buffer Buffer containing the chars to write
 * @param size Number of chars to write
 * @return size_t Number of bytes actually written
 */
size_t Storage::write(FILE *file, const char *buffer, size_t size) {
  if (!file)
    return 0;
  return fwrite(buffer, 1, size, file);
}

/**
 * @brief Check if a file exists on the SD card
 *
 * @param path Path to the file
 * @return true if the file exists, false otherwise
 */
bool Storage::exists(const char *path) {
  struct stat st;
  return stat(path, &st) == 0;
}

/**
 * @brief Create a directory on the SD card
 *
 * @param path Path to the directory
 * @return true if the directory was created successfully, false otherwise
 */
bool Storage::mkdir(const char *path) { return ::mkdir(path, 0777) == 0; }

/**
 * @brief Remove a file from the SD card
 *
 * @param path Path to the file
 * @return true if the file was removed successfully, false otherwise
 */
bool Storage::remove(const char *path) { return ::remove(path) == 0; }

/**
 * @brief Remove a directory from the SD card
 *
 * @param path Path to the directory
 * @return true if the directory was removed successfully, false otherwise
 */
bool Storage::rmdir(const char *path) { return ::rmdir(path) == 0; }

/**
 * @brief Seek to a specific position in a file
 *
 * @param file Pointer to the file
 * @param offset Number of bytes to offset from whence
 * @param whence Position from where offset is added
 *               (SEEK_SET, SEEK_CUR, SEEK_END)
 * @return int 0 on success, non-zero on error
 */
int Storage::seek(FILE *file, long offset, int whence) {
  if (!file)
    return -1;
  return fseek(file, offset, whence);
}

/**
 * @brief Write a string to a file without a newline
 *
 * @param file Pointer to the file
 * @param str String to write
 * @return int Number of characters written, negative on error
 */
int Storage::print(FILE *file, const char *str) {
  if (!file)
    return -1;
  return fprintf(file, "%s", str);
}

/**
 * @brief Write a string to a file with a newline
 *
 * @param file Pointer to the file
 * @param str String to write
 * @return int Number of characters written, negative on error
 */
int Storage::println(FILE *file, const char *str) {
  if (!file)
    return -1;
  return fprintf(file, "%s\n", str);
}

/**
 * @brief Get the number of bytes available to read from the file
 *
 * @param file Pointer to the file
 * @return size_t Number of bytes available to read
 */
size_t Storage::fileAvailable(FILE *file) {
  if (!file)
    return 0;
  long current_pos = ftell(file);
  fseek(file, 0, SEEK_END);
  long end_pos = ftell(file);
  fseek(file, current_pos, SEEK_SET);
  return end_pos - current_pos;
}
