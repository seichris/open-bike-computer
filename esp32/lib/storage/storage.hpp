/**
 * @file storage.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Storage definition and functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include "../power_management/power_management.hpp"
#include "storage_stream_admission.hpp"
#include "Stream.h"
#include "driver/sdmmc_host.h"
#include "driver/sdspi_host.h"
#include "esp_err.h"
#include "esp_spiffs.h"
#include "../ride_diagnostics/ride_diagnostics_transfer_policy.hpp"
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

struct StorageReadEvidence {
  size_t requested = 0;
  size_t returned = 0;
  int errorNumber = 0;
  bool error = false;
  bool eof = false;
};

enum class StorageBackend : uint8_t {
  Unavailable,
  NativeSdmmc,
  LegacySpiMigration,
  RemovableSpi,
  InternalFFat,
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
  mutable storage_shutdown::StreamAdmission streamAdmission_;
  std::atomic<bool> shutdownAdmissionClosed_{false};
  std::atomic<bool> shutdownStarted_{false};
  std::atomic<bool> shutdownComplete_{false};
  static void shutdownTask(void *context);
  // True when /sdcard is backed by the FFat fallback for this boot. It holds
  // bounded diagnostics and other device files, never maps.
  std::atomic<bool> internalFallbackMounted{false};
  // Set once by pinBackendForBoot(), before any file owner starts. Afterwards
  // no request may unmount, remount or replace /sdcard until shutdown.
  std::atomic<bool> backendPinned_{false};
  std::atomic<bool> mapStorageAvailable_{false};
  // Recorder health is separate from the physical mount. A write fault must
  // not unmount SD beneath map/font readers or an in-flight diagnostics GET.
  std::atomic<bool> diagnosticsSdHealthy{true};
  // Tracks the concrete owner of /sdcard. Waveshare firmware can temporarily
  // use the historical isolated SPI transport only when native SDMMC fails
  // during the HSPI-to-SDMMC migration boot.
  std::atomic<StorageBackend> mountedBackend{StorageBackend::Unavailable};
  std::atomic<uint32_t> mountGeneration_{0};
  std::atomic<ride_diagnostics::transfer_policy::StoragePreparation>
      lastDiagnosticsMountResult{
          ride_diagnostics::transfer_policy::StoragePreparation::MountFailed};
  sdmmc_card_t *card;
  SemaphoreHandle_t mountMutex = nullptr;
  esp_err_t mountRemovableStorage();

public:
  uint32_t mountGeneration() const { return mountGeneration_.load(std::memory_order_acquire); }
  Storage();

  // Called only after transfer, renderer and diagnostics producer ACKs.
  // Starts a dedicated internal-stack unmount task; never waits on the UI.
  bool pollShutdownQuiescence();
  // Boot-only mounts: setup() tries the card, then FFat, then pins the result.
  // Both refuse once the backend is pinned.
  esp_err_t initSD();
  // Called once by setup() after its mount attempts and before any file owner
  // starts. /sdcard then keeps this backend until the shutdown barrier; a card
  // that fails, is removed or is inserted later is adopted after a restart.
  void pinBackendForBoot();
  bool backendPinned() const;
  // True only when this boot pinned removable SD. Map data never uses FFat.
  bool mapStorageAvailable() const;
  // Root for every map path. It is the removable mount when
  // mapStorageAvailable(), and otherwise a path that no filesystem serves, so
  // a map lookup cannot reach the FFat fallback that shares /sdcard.
  const char *mapStorageRoot() const;
  // Validates the pinned removable mount without mounting, remounting or
  // falling back. A failed or removed card is marked unavailable.
  bool ensureSdMounted();
  void markSdUnavailable();
  bool hasInternalFallbackMounted() const;
  StorageBackend storageBackend() const;
  const char *storageBackendName() const;
  bool storagePowerCycleRequired() const;
  uint64_t removableSdFreeBytes() const;
  bool tryRemovableSdFreeBytes(uint64_t &bytes) const;
  ride_diagnostics::transfer_policy::StoragePreparation
  prepareDiagnosticsStorage();
  bool ensureDiagnosticsSdMounted();
  void markDiagnosticsSdUnavailable();
  bool getDiagnosticsSdLoaded() const;
  bool canRetryDiagnosticsSd() const;
  uint64_t diagnosticsSdFreeBytes() const;
  const char *diagnosticsRootPath() const;
  esp_err_t initSPIFFS();
  SDCardInfo getSDCardInfo();
  bool getSdLoaded() const;
  // Registered streams hold shutdown admission through their complete
  // fopen -> fclose lifetime. Only close streams returned by this instance.
  // Exhaustion/shutdown rejects open before reaching the backend; unknown or
  // already-closing streams return EOF rather than closing a foreign handle.
  FILE *open(const char *path, const char *mode);
  int close(FILE *file);
  bool exists(const char *path);
  bool mkdir(const char *path);
  bool remove(const char *path);
  bool rmdir(const char *path);
  size_t size(const char *path);
  size_t read(FILE *file, uint8_t *buffer, size_t size);
  StorageReadEvidence readWithEvidence(FILE *file, uint8_t *buffer, size_t size);
  size_t read(FILE *file, char *buffer, size_t size);
  bool hasError(FILE *file);
  size_t write(FILE *file, const uint8_t *buffer, size_t size);
  size_t write(FILE *file, const char *buffer, size_t size);
  int flush(FILE *file);
  int sync(FILE *file);
  int seek(FILE *file, long offset, int whence);
  int print(FILE *file, const char *str);
  int println(FILE *file, const char *str);
  size_t fileAvailable(FILE *file);
};
