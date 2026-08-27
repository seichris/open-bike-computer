/**
 * @file storage.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Storage definition and functions
 * @version 0.2.2
 * @date 2025-05
 */

#include "storage.hpp"
#include "sd_mount_retry_policy.hpp"
#include "storage_mount_policy.hpp"
#include "../power_management/power_management.hpp"
#include "driver/gpio.h"
#include "driver/sdspi_host.h"
#include "esp_log.h"
#include "esp_vfs_fat.h"
#include "freertos/task.h"
#include <SD.h>
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include <SD_MMC.h>
#endif
#include <FFat.h>
#include <SPI.h>
#include <Wire.h>
#include <cmath>
#include <hal.hpp>
#include <iomanip>
#include <sstream>

#define SD_OCR_SDHC_CAP (1 << 30)

static const char *TAG = "Storage";

namespace {
#ifndef WAVESHARE_SDMMC_FREQ_KHZ
#define WAVESHARE_SDMMC_FREQ_KHZ SDMMC_FREQ_DEFAULT
#endif

using ride_diagnostics::transfer_policy::StoragePreparation;

bool mountedDirectoryAvailable(const char *root) {
  struct stat mounted = {};
  return root != nullptr && ::stat(root, &mounted) == 0 &&
         S_ISDIR(mounted.st_mode);
}

bool writableProbeSucceeded(const char *root) {
  char probePath[128] = {};
  snprintf(probePath, sizeof(probePath), "%s/.bicino-diag-probe", root);
  FILE *probe = fopen(probePath, "wb");
  if (probe == nullptr)
    return false;
  const uint8_t marker = 1;
  const bool wrote =
      fwrite(&marker, 1, sizeof(marker), probe) == sizeof(marker);
  const bool flushed = wrote && fflush(probe) == 0;
  // fclose() closes the stream even when its implicit flush reports failure,
  // so remove the probe in every opened-file path. A failed remove is itself
  // evidence that the backend cannot complete the export lifecycle safely.
  const bool closed = fclose(probe) == 0;
  const bool removed = unlink(probePath) == 0;
  return wrote && flushed && closed && removed;
}

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) ||          \
    defined(SPI_SHARED)
uint8_t removableCardType() {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  return SD_MMC.cardType();
#else
  return SD.cardType();
#endif
}

File openRemovableRoot() {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  return SD_MMC.open("/");
#else
  return SD.open("/");
#endif
}

uint64_t removableCardSize() {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  return SD_MMC.cardSize();
#else
  return SD.cardSize();
#endif
}

uint64_t removableTotalBytes() {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  return SD_MMC.totalBytes();
#else
  return SD.totalBytes();
#endif
}

uint64_t removableUsedBytes() {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  return SD_MMC.usedBytes();
#else
  return SD.usedBytes();
#endif
}

void endRemovableStorage() {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  SD_MMC.end();
#else
  SD.end();
#endif
}
#endif

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

bool Storage::ensureSdMounted(bool allowInternalFallback) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  if (mountMutex == nullptr)
    mountMutex = xSemaphoreCreateMutex();
  if (mountMutex == nullptr)
    return false;
  xSemaphoreTake(mountMutex, portMAX_DELAY);

  struct stat mounted = {};
  bool ready = isSdLoaded.load() && ::stat("/sdcard", &mounted) == 0 &&
               S_ISDIR(mounted.st_mode);
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) ||          \
    defined(SPI_SHARED)
  ready = ready && removableCardType() != CARD_NONE;
  if (ready) {
    File root = openRemovableRoot();
    ready = static_cast<bool>(root);
    root.close();
  }
#endif
  if (!ready) {
    // The FFat fallback shares /sdcard with the removable card. Retrying the
    // removable mount would have to unmount FFat and invalidate every map/file
    // handle in the application. Automatic diagnostics recovery therefore
    // retries only when no fallback is active. Existing explicit callers that
    // allow the fallback retain the historical remount-and-restore behavior.
    if (!storage_mount_policy::shouldAttemptAutomaticRemovableRetry(
            isSdLoaded.load(), internalFallbackMounted.load()) &&
        !allowInternalFallback) {
      xSemaphoreGive(mountMutex);
      return false;
    }
    isSdLoaded = false;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) ||          \
    defined(SPI_SHARED)
    const bool restoreInternalFallback =
        storage_mount_policy::shouldRestoreFallbackAfterFailedRetry(
            allowInternalFallback, internalFallbackMounted.load());
    FFat.end();
    endRemovableStorage();
    delay(25);
#endif
    ready = initSD() == ESP_OK;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
    if (!ready && restoreInternalFallback)
      initSPIFFS();
#endif
  }
  xSemaphoreGive(mountMutex);
  return ready;
}

void Storage::markSdUnavailable() { isSdLoaded = false; }

bool Storage::hasInternalFallbackMounted() const {
  return internalFallbackMounted.load();
}

bool Storage::canRetryRemovableSd() const {
  return storage_mount_policy::shouldAttemptAutomaticRemovableRetry(
      isSdLoaded.load(), internalFallbackMounted.load());
}

uint64_t Storage::removableSdFreeBytes() const {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  if (!isSdLoaded.load())
    return 0;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) ||          \
    defined(SPI_SHARED)
  const uint64_t total = removableTotalBytes();
  const uint64_t used = removableUsedBytes();
  return total > used ? total - used : 0;
#else
  // Persistent diagnostics is enabled only on the Waveshare targets. Other
  // legacy storage backends do not expose a portable free-space query here.
  return UINT64_MAX;
#endif
}

StoragePreparation Storage::prepareDiagnosticsStorage() {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  if (mountMutex == nullptr)
    mountMutex = xSemaphoreCreateMutex();
  if (mountMutex == nullptr) {
    lastDiagnosticsMountResult = StoragePreparation::MountFailed;
    return StoragePreparation::MountFailed;
  }
  xSemaphoreTake(mountMutex, portMAX_DELAY);

  const bool mainMounted = isSdLoaded.load();
  const bool internalMounted = internalFallbackMounted.load();
  constexpr const char *root = "/sdcard";
  if (mainMounted || internalMounted) {
    StoragePreparation result = StoragePreparation::ReadyRemovable;
    if (!mountedDirectoryAvailable(root)) {
      result = StoragePreparation::MountFailed;
    }
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) ||          \
    defined(SPI_SHARED)
    else if (!internalMounted && removableCardType() == CARD_NONE) {
      result = StoragePreparation::CardMissing;
    }
#endif
    else if (!writableProbeSucceeded(root)) {
      result = StoragePreparation::WritableProbeFailed;
    } else if (internalMounted) {
      // The diagnostics backend remains stable for the complete boot. This
      // intentionally exports the bounded FFat recorder instead of mounting a
      // newly inserted card at another root while an FFat FILE may be open.
      result = StoragePreparation::ReadyInternalFallback;
    }
    diagnosticsSdHealthy =
        ride_diagnostics::transfer_policy::storageReady(result);
    lastDiagnosticsMountResult = result;
    xSemaphoreGive(mountMutex);
    return result;
  }

  xSemaphoreGive(mountMutex);
  if (!ensureSdMounted(false))
    return lastDiagnosticsMountResult.load();
  return prepareDiagnosticsStorage();
}

bool Storage::ensureDiagnosticsSdMounted() {
  return ride_diagnostics::transfer_policy::storageReady(
      prepareDiagnosticsStorage());
}

void Storage::markDiagnosticsSdUnavailable() {
  diagnosticsSdHealthy = false;
}

bool Storage::getDiagnosticsSdLoaded() const {
  return diagnosticsSdHealthy.load() &&
         (isSdLoaded.load() || internalFallbackMounted.load());
}

bool Storage::canRetryDiagnosticsSd() const {
  if (!diagnosticsSdHealthy.load())
    return true;
  return storage_mount_policy::shouldAttemptDiagnosticsRemovableRetry(
      isSdLoaded.load(), internalFallbackMounted.load());
}

uint64_t Storage::diagnosticsSdFreeBytes() const {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  if (!getDiagnosticsSdLoaded())
    return 0;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) ||          \
    defined(SPI_SHARED)
  if (internalFallbackMounted.load()) {
    const uint64_t total = FFat.totalBytes();
    const uint64_t used = FFat.usedBytes();
    return total > used ? total - used : 0;
  }
  const uint64_t total = removableTotalBytes();
  const uint64_t used = removableUsedBytes();
  return total > used ? total - used : 0;
#else
  return UINT64_MAX;
#endif
}

const char *Storage::diagnosticsRootPath() const {
  return "/sdcard";
}

/**
 * @brief Initialize removable storage with the active board backend
 */
esp_err_t Storage::initSD() {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  const uint32_t mountStartMs = millis();
  uint8_t mountedCardType = CARD_NONE;
  uint64_t mountedCardSize = 0;
  bool observedCardMissing = false;

  // Both Waveshare boards route CLK/CMD/D0 to the ESP32-S3 native SDMMC
  // peripheral. One-bit mode leaves the board's SPI CS/D3 trace unused and
  // keeps storage independent from the AMOLED QSPI controller.
  Serial.printf(
      "SDIO: init bus=SDMMC mode=1bit freqKHz=%lu "
      "pins[clk=%d cmd=%d d0=%d]\n",
      (unsigned long)WAVESHARE_SDMMC_FREQ_KHZ, WAVESHARE_SDMMC_CLK,
      WAVESHARE_SDMMC_CMD, WAVESHARE_SDMMC_D0);

  const auto mountResult = storage_mount_retry_policy::runMountSequence(
      []() { SD_MMC.end(); },
      [](uint32_t delayMs) {
        Serial.printf("SDIO: recovery action=sdmmc-teardown delayMs=%lu\n",
                      (unsigned long)delayMs);
        delay(delayMs);
      },
      [&](std::size_t attempt) {
        const uint32_t attemptStartMs = millis();
        Serial.printf("SDIO: attempt=%u/%u phase=begin bus=SDMMC "
                      "mode=1bit freqKHz=%lu\n",
                      static_cast<unsigned>(attempt),
                      static_cast<unsigned>(
                          storage_mount_retry_policy::kMountAttemptCount),
                      (unsigned long)WAVESHARE_SDMMC_FREQ_KHZ);

        const bool pinsConfigured = SD_MMC.setPins(
            WAVESHARE_SDMMC_CLK, WAVESHARE_SDMMC_CMD, WAVESHARE_SDMMC_D0);
        const bool mounted =
            pinsConfigured &&
            SD_MMC.begin("/sdcard", true, false,
                         WAVESHARE_SDMMC_FREQ_KHZ, 5);
        uint8_t cardType = CARD_NONE;
        bool rootHealthy = false;
        if (mounted) {
          cardType = SD_MMC.cardType();
          observedCardMissing = observedCardMissing || cardType == CARD_NONE;
          if (cardType != CARD_NONE) {
            File root = SD_MMC.open("/");
            rootHealthy = static_cast<bool>(root);
            root.close();
          }
        }

        Serial.printf("SDIO: attempt=%u/%u phase=mount pins=%u mounted=%u "
                      "card=%u root=%u elapsedMs=%lu\n",
                      static_cast<unsigned>(attempt),
                      static_cast<unsigned>(
                          storage_mount_retry_policy::kMountAttemptCount),
                      pinsConfigured ? 1U : 0U, mounted ? 1U : 0U,
                      cardType != CARD_NONE ? 1U : 0U,
                      rootHealthy ? 1U : 0U,
                      (unsigned long)(millis() - attemptStartMs));

        if (mounted && cardType != CARD_NONE && rootHealthy) {
          mountedCardType = cardType;
          mountedCardSize = SD_MMC.cardSize();
        }
        return storage_mount_retry_policy::MountAttemptResult{
            mounted && cardType != CARD_NONE, rootHealthy};
      });

  if (!mountResult.ok) {
    SD_MMC.end();
    ESP_LOGE(TAG,
             "Native one-bit SDMMC mount failed after bounded recovery");
    Serial.printf("SDIO: summary ok=0 attempts=%u totalElapsedMs=%lu "
                  "next=ffat\n",
                  static_cast<unsigned>(mountResult.attempts),
                  (unsigned long)(millis() - mountStartMs));
    isSdLoaded = false;
    diagnosticsSdHealthy = false;
    lastDiagnosticsMountResult =
        observedCardMissing ? StoragePreparation::CardMissing
                            : StoragePreparation::MountFailed;
    return ESP_FAIL;
  }

  const char *typeStr = "UNKNOWN";
  if (mountedCardType == CARD_MMC)
    typeStr = "MMC";
  else if (mountedCardType == CARD_SD)
    typeStr = "SD";
  else if (mountedCardType == CARD_SDHC)
    typeStr = "SDHC";

  ESP_LOGI(TAG, "SD Card Type: %s, Size: %lluMB", typeStr,
           mountedCardSize / (1024 * 1024));
  Serial.printf("SDIO: summary ok=1 attempts=%u totalElapsedMs=%lu "
                "mode=1bit freqKHz=%lu type=%s sizeMB=%llu fallback=none\n",
                static_cast<unsigned>(mountResult.attempts),
                (unsigned long)(millis() - mountStartMs),
                (unsigned long)WAVESHARE_SDMMC_FREQ_KHZ, typeStr,
                mountedCardSize / (1024 * 1024));

#ifdef WAVESHARE_SD_LIST_ROOT
  Serial.println("SDIO: root listing enabled");
  File root = SD_MMC.open("/");
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
#endif

  isSdLoaded = true;
  internalFallbackMounted = false;
  diagnosticsSdHealthy = true;
  lastDiagnosticsMountResult = StoragePreparation::ReadyRemovable;
  return ESP_OK;

#elif defined(SPI_SHARED)
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH); // De-select SD card initially

  SPI.begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS);

  if (!SD.begin(SD_CS, SPI, 4000000, "/sdcard")) {
    ESP_LOGE(TAG, "SD Card Mount Failed");
    isSdLoaded = false;
    lastDiagnosticsMountResult = StoragePreparation::MountFailed;
    return ESP_FAIL;
  } else {
    ESP_LOGI(TAG, "SD Card Mounted");
    isSdLoaded = true;
    internalFallbackMounted = false;
    diagnosticsSdHealthy = true;
    lastDiagnosticsMountResult = StoragePreparation::ReadyRemovable;
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
    lastDiagnosticsMountResult = StoragePreparation::MountFailed;
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
    lastDiagnosticsMountResult = StoragePreparation::MountFailed;
    return ret;
  } else {
    ESP_LOGI(TAG, "SD card initialized successfully");
    sdmmc_card_print_info(stdout, card);
    isSdLoaded = true;
    internalFallbackMounted = false;
    diagnosticsSdHealthy = true;
    lastDiagnosticsMountResult = StoragePreparation::ReadyRemovable;
    return ESP_OK;
  }
#endif
}

/**
 * @brief SPIFFS initialization
 *
 * @return esp_err_t Error code for SPIFFS setup
 */
/**
 * @brief Initialize FFat (used as fallback or primary storage)
 *
 * @return esp_err_t Error code
 */
esp_err_t Storage::initSPIFFS() {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  ESP_LOGI(TAG, "Initializing FFat as /sdcard");

  // Mount FFat at "/sdcard" so the rest of the application thinks it's
  // reading from SD Partition label "ffat" is standard for the data partition
  // even when using FFat
  if (!FFat.begin(true, "/sdcard", 20, "ffat")) {
    ESP_LOGE(TAG, "FFat Mount Failed");
    internalFallbackMounted = false;
    return ESP_FAIL;
  }

  size_t total = FFat.totalBytes();
  size_t used = FFat.usedBytes();
  ESP_LOGI(TAG, "FFat Mounted at /sdcard. Total: %d, Used: %d", total, used);
  internalFallbackMounted = true;
  diagnosticsSdHealthy = true;

#ifdef WAVESHARE_SD_LIST_ROOT
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
#endif

  return ESP_OK;
}

/**
 * @brief Get SD card information
 *
 * @return SDCardInfo structure containing SD card information
 */
SDCardInfo Storage::getSDCardInfo() {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  SDCardInfo info{};

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206) ||          \
    defined(SPI_SHARED)
  const uint8_t cardType = removableCardType();
  if (cardType == CARD_MMC)
    info.card_type = "MMC";
  else if (cardType == CARD_SD)
    info.card_type = "SDSC";
  else if (cardType == CARD_SDHC)
    info.card_type = "SDHC";
  else
    info.card_type = "UNKNOWN";

  const uint64_t cardSize = removableCardSize();
  const uint64_t totalBytes = removableTotalBytes();
  const uint64_t usedBytes = removableUsedBytes();
  info.capacity = formatSize(cardSize);
  info.total_space = formatSize(totalBytes);
  info.free_space =
      formatSize(totalBytes > usedBytes ? totalBytes - usedBytes : 0);
  info.used_space = formatSize(usedBytes);
#else
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
#endif

  return info;
}

/**
 * @brief Get SD status
 *
 * @return true if SD card is loaded, false otherwise
 */
bool Storage::getSdLoaded() const { return isSdLoaded.load(); }

/**
 * @brief Open a file on the SD card
 *
 * @param path Path to the file
 * @param mode Mode in which to open the file
 * @return FILE* Pointer to the opened file
 */
FILE *Storage::open(const char *path, const char *mode) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  return fopen(path, mode);
}

/**
 * @brief Close a file on the SD card
 *
 * @param file Pointer to the file
 * @return int 0 on success, EOF on error
 */
int Storage::close(FILE *file) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  return fclose(file);
}

/**
 * @brief Get the size of a file on the SD card
 *
 * @param path Path to the file
 * @return size_t Size of the file in bytes
 */
size_t Storage::size(const char *path) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
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
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
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
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  if (!file)
    return 0;
  return fread(buffer, 1, size, file);
}

bool Storage::hasError(FILE *file) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  return file == nullptr || ferror(file) != 0;
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
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
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
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  if (!file)
    return 0;
  return fwrite(buffer, 1, size, file);
}

int Storage::flush(FILE *file) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  return file == nullptr ? EOF : fflush(file);
}

/**
 * @brief Check if a file exists on the SD card
 *
 * @param path Path to the file
 * @return true if the file exists, false otherwise
 */
bool Storage::exists(const char *path) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  struct stat st;
  return stat(path, &st) == 0;
}

/**
 * @brief Create a directory on the SD card
 *
 * @param path Path to the directory
 * @return true if the directory was created successfully, false otherwise
 */
bool Storage::mkdir(const char *path) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  return ::mkdir(path, 0777) == 0;
}

/**
 * @brief Remove a file from the SD card
 *
 * @param path Path to the file
 * @return true if the file was removed successfully, false otherwise
 */
bool Storage::remove(const char *path) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  return ::remove(path) == 0;
}

/**
 * @brief Remove a directory from the SD card
 *
 * @param path Path to the directory
 * @return true if the directory was removed successfully, false otherwise
 */
bool Storage::rmdir(const char *path) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  return ::rmdir(path) == 0;
}

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
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
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
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
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
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
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
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  if (!file)
    return 0;
  long current_pos = ftell(file);
  fseek(file, 0, SEEK_END);
  long end_pos = ftell(file);
  fseek(file, current_pos, SEEK_SET);
  return end_pos - current_pos;
}
