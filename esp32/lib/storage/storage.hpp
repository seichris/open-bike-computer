/**
 * @file storage.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Storage definition and functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include "../power_management/power_management.hpp"
#include "Stream.h"
#include "driver/sdmmc_host.h"
#include "driver/sdspi_host.h"
#include "esp_err.h"
#include "esp_spiffs.h"
#include "sdmmc_cmd.h"
#include <atomic>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <stdio.h>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>

#ifdef SPI_SHARED
#include "Arduino.h"
#include "SD.h"
#include "SD_MMC.h"
#endif

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "Arduino.h"
#include "SD_MMC.h"
#endif

struct SDCardInfo {
  std::string name;
  std::string capacity;
  int sector_size;
  int read_block_len;
  std::string card_type;
  std::string total_space;
  std::string free_space;
  std::string used_space;
};

class FileStream : public Stream {
public:
  FileStream(FILE *file) : file(file) {}

  virtual int available() override {
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

  virtual int read() override {
    power_management::ScopedLock powerLock(
        power_management::LockDomain::Storage);
    if (!file)
      return -1;
    return fgetc(file);
  }

  virtual size_t read(uint8_t *buffer, size_t size) {
    power_management::ScopedLock powerLock(
        power_management::LockDomain::Storage);
    if (!file)
      return 0;
    return fread(buffer, 1, size, file);
  }

  virtual size_t readBytes(char *buffer, size_t length) override {
    power_management::ScopedLock powerLock(
        power_management::LockDomain::Storage);
    if (!file)
      return 0;
    return fread(buffer, 1, length, file);
  }

  virtual int peek() override {
    power_management::ScopedLock powerLock(
        power_management::LockDomain::Storage);
    if (!file)
      return -1;
    int c = fgetc(file);
    if (c != EOF)
      ungetc(c, file);
    return c;
  }

  virtual void flush() override {
    power_management::ScopedLock powerLock(
        power_management::LockDomain::Storage);
    if (file)
      fflush(file);
  }

  size_t write(uint8_t) override {
    // Not implemented
    return 0;
  }

  size_t write(const uint8_t *, size_t) override {
    // Not implemented
    return 0;
  }

private:
  FILE *file;
};

class Storage {
private:
  std::atomic<bool> isSdLoaded;
  // True when /sdcard is currently backed by the main-branch FFat fallback.
  // Diagnostics must not treat this as removable-SD availability, but a
  // failed SD retry must restore it so the rest of the application keeps the
  // same fallback behavior as the non-diagnostics firmware.
  std::atomic<bool> internalFallbackMounted{false};
  // When FFat owns /sdcard, diagnostics may mount a newly inserted removable
  // card at a separate VFS root. This preserves every live fallback/map handle
  // while allowing the recorder to recover without a reboot.
  std::atomic<bool> diagnosticsSdMountedAtAlternateRoot{false};
  // Recorder health is separate from the physical mount. A write fault must
  // not unmount SD beneath map/font readers or an in-flight diagnostics GET.
  std::atomic<bool> diagnosticsSdHealthy{true};
  sdmmc_card_t *card;
  SemaphoreHandle_t mountMutex = nullptr;

public:
  Storage();

  esp_err_t initSD();
  // Remount the removable card when requested. Existing callers retain the
  // FFat fallback by default; diagnostics can opt out so an absent card never
  // turns into an unbounded internal log sink.
  bool ensureSdMounted(bool allowInternalFallback = true);
  void markSdUnavailable();
  bool hasInternalFallbackMounted() const;
  bool canRetryRemovableSd() const;
  uint64_t removableSdFreeBytes() const;
  bool ensureDiagnosticsSdMounted();
  void markDiagnosticsSdUnavailable();
  bool getDiagnosticsSdLoaded() const;
  bool canRetryDiagnosticsSd() const;
  uint64_t diagnosticsSdFreeBytes() const;
  const char *diagnosticsRootPath() const;
  esp_err_t initSPIFFS();
  SDCardInfo getSDCardInfo();
  bool getSdLoaded() const;
  FILE *open(const char *path, const char *mode);
  int close(FILE *file);
  bool exists(const char *path);
  bool mkdir(const char *path);
  bool remove(const char *path);
  bool rmdir(const char *path);
  size_t size(const char *path);
  size_t read(FILE *file, uint8_t *buffer, size_t size);
  size_t read(FILE *file, char *buffer, size_t size);
  bool hasError(FILE *file);
  size_t write(FILE *file, const uint8_t *buffer, size_t size);
  size_t write(FILE *file, const char *buffer, size_t size);
  int flush(FILE *file);
  int seek(FILE *file, long offset, int whence);
  int print(FILE *file, const char *str);
  int println(FILE *file, const char *str);
  size_t fileAvailable(FILE *file);
};
