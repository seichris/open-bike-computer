// The production Storage header and its mount, pin, map-root and diagnostics
// methods are inserted by test_sd_only_map_storage.py. The card, FFat and the
// /sdcard VFS entry are fakes that count every mount and unmount, so a live
// backend switch after setup pins the boot's storage is observable.
#define WAVESHARE_AMOLED_175 1 // Both boards share this storage path.
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include "../../lib/ride_diagnostics/ride_diagnostics_transfer_policy.hpp"
#include "../../lib/storage/storage_mount_policy.hpp"
#include "../../lib/storage/storage_stream_admission.hpp"

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,    \
                   #condition);                                                \
      std::exit(42);                                                           \
    }                                                                          \
  } while (0)

using esp_err_t = int;
constexpr esp_err_t ESP_OK = 0, ESP_FAIL = -1, ESP_ERR_INVALID_STATE = 0x103;
using SemaphoreHandle_t = void *;
constexpr unsigned portMAX_DELAY = 0xffffffffU;
struct sdmmc_card_t {};
SemaphoreHandle_t xSemaphoreCreateMutex() {
  static int mutex = 0;
  return &mutex;
}
int xSemaphoreTake(SemaphoreHandle_t, unsigned) { return 1; }
void xSemaphoreGive(SemaphoreHandle_t) {}
void delay(unsigned) {}
template <typename... Arguments> void discardLog(const Arguments &...) {}
#define ESP_LOGI(...) discardLog(__VA_ARGS__)
#define ESP_LOGE(...) discardLog(__VA_ARGS__)
static const char *TAG = "Storage";

namespace power_management {
enum class LockDomain { Storage };
struct ScopedLock {
  explicit ScopedLock(LockDomain) {}
};
} // namespace power_management

class Stream {
public:
  virtual ~Stream() = default;
  virtual int available() = 0;
  virtual int read() = 0;
  virtual size_t readBytes(char *buffer, size_t length) = 0;
  virtual int peek() = 0;
  virtual void flush() = 0;
  virtual size_t write(uint8_t) = 0;
  virtual size_t write(const uint8_t *, size_t) = 0;
};

constexpr uint8_t CARD_NONE = 0, CARD_SD = 2;
struct File {
  bool valid = false;
  explicit operator bool() const { return valid; }
  void close() {}
};

// Simulated hardware: a card slot, the /sdcard VFS entry and the FFat volume.
bool cardInserted = false;
bool removableVfsMounted = false;
unsigned removableMounts = 0, removableUnmounts = 0;
struct FakeFFat {
  bool mounted = false;
  bool canMount = true;
  unsigned begins = 0, ends = 0;
  bool begin(bool, const char *basePath, uint8_t, const char *) {
    ++begins;
    CHECK(std::strcmp(basePath, "/sdcard") == 0);
    mounted = canMount;
    return mounted;
  }
  void end() {
    ++ends;
    mounted = false;
  }
  size_t totalBytes() const { return 9U << 20; }
  size_t usedBytes() const { return 0; }
  File open(const char *) { return File{mounted}; }
} FFat;

int harnessStat(const char *path, struct stat *out) {
  if (std::strcmp(path, "/sdcard") != 0 ||
      (!removableVfsMounted && !FFat.mounted))
    return -1;
  std::memset(out, 0, sizeof(*out));
  out->st_mode = S_IFDIR;
  return 0;
}

// PRODUCTION_HEADER

using ride_diagnostics::transfer_policy::StoragePreparation;
// PRODUCTION_UNAVAILABLE_ROOT

uint8_t removableCardType(StorageBackend) {
  return removableVfsMounted ? CARD_SD : CARD_NONE; // Cached at mount.
}
File openRemovableRoot(StorageBackend) {
  return File{removableVfsMounted && cardInserted};
}
void endRemovableStorage(StorageBackend) {
  ++removableUnmounts;
  removableVfsMounted = false;
}
bool mountedDirectoryAvailable(const char *root) {
  struct stat mounted = {};
  return harnessStat(root, &mounted) == 0;
}
bool writableProbeSucceeded(const char *) {
  return FFat.mounted || (removableVfsMounted && cardInserted);
}

// The real removable mount sequence drives SDMMC; this fake keeps its state
// transitions and counts each attempt.
esp_err_t Storage::mountRemovableStorage() {
  ++removableMounts;
  if (!cardInserted) {
    isSdLoaded = false;
    mountedBackend = StorageBackend::Unavailable;
    diagnosticsSdHealthy = false;
    lastDiagnosticsMountResult = StoragePreparation::CardMissing;
    return ESP_FAIL;
  }
  removableVfsMounted = true;
  isSdLoaded = true;
  mountedBackend = StorageBackend::NativeSdmmc;
  internalFallbackMounted = false;
  diagnosticsSdHealthy = true;
  lastDiagnosticsMountResult = StoragePreparation::ReadyRemovable;
  return ESP_OK;
}

#define stat(...) harnessStat(__VA_ARGS__)
// PRODUCTION_METHODS
#undef stat

void resetHardware() {
  cardInserted = false;
  removableVfsMounted = false;
  removableMounts = removableUnmounts = 0;
  FFat = FakeFFat{};
}

void cardBootPinsTheCardAndNeverRemounts() {
  resetHardware();
  cardInserted = true;
  Storage storage;
  CHECK(storage.initSD() == ESP_OK);
  storage.pinBackendForBoot();
  CHECK(storage.backendPinned() && storage.mapStorageAvailable());
  CHECK(std::strcmp(storage.mapStorageRoot(), "/sdcard") == 0);
  const uint32_t generation = storage.mountGeneration();
  CHECK(storage.ensureSdMounted());

  // Card removed mid-ride, then the rider asks to download a map.
  cardInserted = false;
  CHECK(!storage.ensureSdMounted());
  CHECK(!storage.getSdLoaded());
  CHECK(storage.storageBackend() == StorageBackend::Unavailable);
  CHECK(!FFat.mounted && FFat.begins == 0);
  CHECK(std::strcmp(storage.mapStorageRoot(), "/sdcard") == 0);

  // Reinserting it is not adopted until a restart, through any entry point.
  cardInserted = true;
  CHECK(!storage.ensureSdMounted());
  CHECK(storage.initSD() == ESP_ERR_INVALID_STATE);
  CHECK(storage.initSPIFFS() == ESP_ERR_INVALID_STATE);
  CHECK(removableMounts == 1 && removableUnmounts == 0);
  CHECK(FFat.begins == 0 && FFat.ends == 0);
  CHECK(storage.mountGeneration() == generation);
}

void noCardBootKeepsMapsOffFfat() {
  resetHardware();
  Storage storage;
  CHECK(storage.initSD() != ESP_OK);
  CHECK(storage.initSPIFFS() == ESP_OK);
  storage.pinBackendForBoot();
  CHECK(storage.hasInternalFallbackMounted());
  CHECK(!storage.mapStorageAvailable());
  const std::string root = storage.mapStorageRoot();
  CHECK(root == kUnavailableMapRoot);
  CHECK(root.rfind("/sdcard", 0) != 0);
  struct stat unavailable = {};
  CHECK(harnessStat(root.c_str(), &unavailable) != 0);

  // A card inserted after boot does not displace FFat or receive maps.
  cardInserted = true;
  CHECK(!storage.ensureSdMounted());
  CHECK(storage.initSD() == ESP_ERR_INVALID_STATE);
  CHECK(!storage.mapStorageAvailable());
  CHECK(FFat.mounted && FFat.begins == 1 && FFat.ends == 0);
  CHECK(removableMounts == 1 && removableUnmounts == 0);

  // Bounded FFat diagnostics remain available and are only ever re-probed.
  CHECK(storage.prepareDiagnosticsStorage() ==
        StoragePreparation::ReadyInternalFallback);
  storage.markDiagnosticsSdUnavailable();
  CHECK(storage.canRetryDiagnosticsSd());
  CHECK(storage.ensureDiagnosticsSdMounted());
  CHECK(FFat.begins == 1 && FFat.ends == 0 && removableMounts == 1);
}

void unmountedBootNeverMountsLater() {
  resetHardware();
  FFat.canMount = false;
  Storage storage;
  CHECK(storage.initSD() != ESP_OK);
  CHECK(storage.initSPIFFS() != ESP_OK);
  storage.pinBackendForBoot();
  CHECK(!storage.mapStorageAvailable());

  cardInserted = true;
  FFat.canMount = true;
  CHECK(!storage.canRetryDiagnosticsSd());
  CHECK(storage.prepareDiagnosticsStorage() == StoragePreparation::CardMissing);
  CHECK(!storage.ensureSdMounted());
  CHECK(storage.initSPIFFS() == ESP_ERR_INVALID_STATE);
  CHECK(removableMounts == 1 && FFat.begins == 1 && !FFat.mounted);
}

int main() {
  cardBootPinsTheCardAndNeverRemounts();
  noCardBootKeepsMapsOffFfat();
  unmountedBootNeverMountsLater();
  std::puts("storage backend pin harness passed");
  return 0;
}
