"""Execute runtime owner boundaries with controlled host scheduling/allocations."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = next(p for p in Path(__file__).resolve().parents
            if (p / "esp32/lib").is_dir()) / "esp32"


def source(path):
    return (ROOT / path).read_text()


def section(path, start, end):
    text = source(path)
    first = text.index(start)
    return text[first:text.index(end, first)]


class FirmwareConcurrencyTests(unittest.TestCase):
    def run_cpp(self, fixture, *arguments):
        with tempfile.TemporaryDirectory(prefix="firmware-concurrency-") as directory:
            root = Path(directory)
            unit, binary = root / "test.cpp", root / "test"
            unit.write_text(fixture)
            subprocess.run([shutil.which("c++"), "-std=c++17", "-Wall", "-Wextra",
                            "-Werror", "-Wno-unused-variable",
                            "-Wno-unused-but-set-variable", "-fsanitize=undefined",
                            "-fno-sanitize-recover=all", "-I", str(ROOT / "lib"),
                            str(unit), "-o", str(binary)], check=True)
            # Real POSIX fixture, never an ESP32 mount or a device port.
            (root / "block.fmb").write_bytes(b"FMB\x01" + bytes(32))
            if "validation" in arguments:
                (root / "block.fmb").unlink()
                (root / "block.fmp").write_text("Polygons:0\nPolylines:0\n")
            result = subprocess.run([str(binary), str(root / "block"), *arguments],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_settings_drain_is_bounded_and_fair_under_refill(self):
        drain = section("lib/ble_navigation/ble_navigation.cpp",
                        "static void processPendingMapInputs()", "// ============================================================================")
        self.run_cpp(r'''
#include <array>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <vector>
constexpr int pdTRUE=1, portMAX_DELAY=-1;
void *pendingMapInputMutex=reinterpret_cast<void *>(1);
int xSemaphoreTake(void *, int) { return pdTRUE; }
void xSemaphoreGive(void *) {}
uint32_t millis() { return 100; }
namespace ui_scheduler { enum class WakeReason { Ble }; unsigned wakes=0;
void notify(WakeReason) { ++wakes; } }
enum class PendingMapInputType { Route, Gps, Setting };
struct PendingMapInput {
  bool pending=false, fallback=false;
  uint8_t *data=nullptr;
  unsigned length=0, payloadGeneration=1, gpsArrivals=0;
  PendingMapInputType type=PendingMapInputType::Route;
};
struct PendingRouteRideDelivery {
  bool pending=false;
  unsigned leaseGeneration=0, result=0;
  unsigned member() const { return 0; }
};
constexpr size_t MAP_SETTING_SLOT_COUNT=256, MAP_SETTING_MASK_BYTES=32;
std::array<PendingMapInput, MAP_SETTING_SLOT_COUNT> slots;
auto *pendingSettingInputs=slots.data();
uint8_t pendingSettingMask[MAP_SETTING_MASK_BYTES]{};
PendingMapInput pendingRouteInput, pendingGpsInput;
PendingRouteRideDelivery pendingRouteRideDelivery;
std::atomic<unsigned> pendingMapInputCount{0}, ridePayloadGeneration{1};
bool deviceOwnershipReady=false;
void *deviceOwnershipMutex=nullptr;
struct { unsigned authenticatedRideLeaseGeneration(unsigned) { return 0; } } deviceOwnership;
namespace ride_delivery_protocol { bool leaseMatches(unsigned a,unsigned b) { return a==b; } }
void noteRideDeliveryMember(unsigned,unsigned,unsigned) {}
unsigned routeCalls=0, gpsCalls=0;
void handleRouteGeometryPayload(const uint8_t *,size_t,const char *) { ++routeCalls; }
void handleGpsPayload(const uint8_t *,size_t,const char *,unsigned) { ++gpsCalls; }
std::vector<unsigned> applied;
bool refill=true;
void enqueue(unsigned id, bool fallback=false) {
  auto &slot=slots[id];
  if (!slot.pending) ++pendingMapInputCount;
  free(slot.data);
  slot={true,fallback,static_cast<uint8_t *>(malloc(5)),5,1,0,PendingMapInputType::Setting};
  slot.data[0]=id;
  pendingSettingMask[id/8] |= uint8_t(1U << (id%8));
}
void handleMapSettingPayload(const uint8_t *data,size_t,const char *) {
  applied.push_back(data[0]);
  if (applied.size()>32) { std::fputs("settings drain did not yield\n",stderr); std::exit(42); }
  if (refill) enqueue(1); // Producer replenishes the lowest ID during application.
}
''' + drain + r'''
int main() {
  enqueue(1); enqueue(250,true);
  pendingRouteInput.pending=true; pendingGpsInput.pending=true;
  pendingGpsInput.type=PendingMapInputType::Gps;
  pendingMapInputCount+=2;
  processPendingMapInputs();
  assert(applied.size()<=4 && routeCalls==1 && gpsCalls==1);
  assert(ui_scheduler::wakes>0 && pendingMapInputCount>0);
  for (unsigned tick=0; tick<4; ++tick) processPendingMapInputs();
  bool highSeen=false;
  for (auto id:applied) highSeen |= id==250;
  assert(highSeen); // A busy low slot cannot starve an older higher slot.
  refill=false;
  for (unsigned tick=0; tick<256 && pendingMapInputCount; ++tick) processPendingMapInputs();
  assert(pendingMapInputCount==0);
  // All IDs remain independently retained, including native/fallback origins.
  applied.clear();
  for (unsigned id=0; id<256; ++id) enqueue(id,id%2);
  for (unsigned tick=0; tick<256 && pendingMapInputCount; ++tick) {
    applied.clear(); processPendingMapInputs(); assert(applied.size()<=4);
  }
  assert(pendingMapInputCount==0);
}
''')

    def test_flash_http_stack_is_internal_and_sd_only_renderer_uses_psram(self):
        http = section("lib/device_transfer/device_transfer_http.cpp",
                       "    const bool workerStackInPsram =", "    // Publish the worker handle")
        http_create = section("lib/device_transfer/device_transfer_http.cpp",
                              "    const BaseType_t created = xTaskCreateWithCaps(",
                              "    if (created == pdPASS)")
        renderer = section("lib/maps/src/maps.cpp", "  // Rasterization needs a deliberately large stack",
                           "  if (created != pdPASS)")
        self.run_cpp(r'''
#include <cassert>
#include <cstdint>
#include <string>
using UBaseType_t=unsigned;
using BaseType_t=int;
using TaskHandle_t=void *;
constexpr unsigned MALLOC_CAP_SPIRAM=1, MALLOC_CAP_INTERNAL=2, MALLOC_CAP_8BIT=4;
constexpr unsigned kPsramHttpWorkerStackBytes=16384, kTransferHttpWorkerStackBytes=16384;
constexpr unsigned MAP_RENDER_WORKER_STACK_BYTES=24576, tskIDLE_PRIORITY=0;
unsigned lastCaps=0;
bool admission=true;
struct { bool sd=false, ffat=false;
  bool getSdLoaded() const { return sd; }
  bool hasInternalFallbackMounted() const { return ffat; }
} storage;
int xTaskCreateWithCaps(void (*)(void *),const char *,unsigned,void *,unsigned,void **,unsigned caps) {
  lastCaps=caps; return admission ? 1:0;
}
int xTaskCreatePinnedToCoreWithCaps(void (*)(void *),const char *,unsigned,void *,unsigned,void **,int,unsigned caps) {
  lastCaps=caps; return admission ? 1:0;
}
struct Owner {
  TaskHandle_t renderWorkerTaskHandle=nullptr;
  static void renderWorkerTaskThunk(void *) {}
  static void workerTaskThunk(void *) {}
  int http(const std::string &requestedMode) {
    TaskHandle_t worker=nullptr;
''' + http + http_create + r'''
    return created;
  }
  int render() {
''' + renderer + r'''
    return created;
  }
};
void flashRead() { assert((lastCaps & MALLOC_CAP_INTERNAL)!=0); }
int main() {
  Owner owner;
  for (bool ffat:{true,false}) {
    storage.ffat=ffat; storage.sd=!ffat;
    for (const char *mode:{"diagnostics","debug","map","firmware"}) {
      assert(owner.http(mode)==1);
      if (ffat) flashRead(); else assert(lastCaps & MALLOC_CAP_SPIRAM);
    }
    assert(owner.render()==1);
    assert(lastCaps & MALLOC_CAP_SPIRAM); // Map entry guards forbid FFat reads.
  }
  storage.sd=false; storage.ffat=false; owner.render();
  assert(lastCaps & MALLOC_CAP_SPIRAM);
  storage.ffat=true; admission=false;
  assert(owner.http("diagnostics")==0 && owner.render()==0);
}
''')

    def test_live_storage_backend_is_not_unmounted_on_retry(self):
        method = section("lib/storage/storage.cpp", "bool Storage::ensureSdMounted(",
                         "\nbool Storage::hasInternalFallbackMounted() const")
        method = method.replace("::stat(", "fakeStat(")
        self.run_cpp(r'''
#include "storage/storage_mount_policy.hpp"
#include "storage/storage_stream_admission.hpp"
#include <atomic>
#include <cassert>
#include <initializer_list>
#include <sys/stat.h>
#define WAVESHARE_AMOLED_175 1
using SemaphoreHandle_t=void *;
constexpr int ESP_OK=0, pdTRUE=1, portMAX_DELAY=-1, CARD_NONE=0;
SemaphoreHandle_t xSemaphoreCreateMutex() { return reinterpret_cast<void *>(1); }
int xSemaphoreTake(SemaphoreHandle_t,int) { return pdTRUE; }
void xSemaphoreGive(SemaphoreHandle_t) {}
void delay(unsigned) {}
namespace power_management { enum class LockDomain { Storage }; struct ScopedLock { explicit ScopedLock(LockDomain) {} }; }
enum class StorageBackend { Unavailable, NativeSdmmc, InternalFFat };
unsigned unmounts=0, mounts=0;
bool rootHealthy=false;
int fakeStat(const char *,struct stat *result) {
  result->st_mode=S_IFDIR;
  return rootHealthy ? 0:-1;
}
struct { void end() { ++unmounts; } } FFat;
void endRemovableStorage(StorageBackend) { ++unmounts; }
int removableCardType(StorageBackend) { return 1; }
struct File { explicit operator bool() const { return rootHealthy; } void close() {} };
File openRemovableRoot(StorageBackend) { return {}; }
class Storage {
public:
  storage_shutdown::StreamAdmission streamAdmission_;
  std::atomic<bool> shutdownAdmissionClosed_{false}, isSdLoaded{false}, internalFallbackMounted{false};
  std::atomic<StorageBackend> mountedBackend{StorageBackend::Unavailable};
  std::atomic<unsigned> mountGeneration_{0};
  SemaphoreHandle_t mountMutex=reinterpret_cast<void *>(1);
  int initSD() { ++mounts; isSdLoaded=true; mountedBackend=StorageBackend::NativeSdmmc; return ESP_OK; }
  int initSPIFFS() { ++mounts; return ESP_OK; }
  bool ensureSdMounted();
};
''' + method + r'''
int main() {
  for (bool ffat:{true,false}) {
    Storage store;
    store.mountedBackend=ffat ? StorageBackend::InternalFFat:StorageBackend::NativeSdmmc;
    store.internalFallbackMounted=ffat; store.isSdLoaded=!ffat;
    // The renderer may hold a raw FD outside the wrapper's stream registry.
    assert(!store.ensureSdMounted());
    assert(unmounts==0 && mounts==0 && store.mountGeneration_==0);
  }
  Storage empty;
  assert(!empty.ensureSdMounted() && mounts==0);
  // Even an initially empty backend stays pinned for this boot.
  empty.isSdLoaded=true;
  empty.mountedBackend=StorageBackend::NativeSdmmc;
  const unsigned initialUnmounts=unmounts;
  rootHealthy=true;
  assert(empty.ensureSdMounted() && mounts==0 && unmounts==initialUnmounts);
  empty.shutdownAdmissionClosed_=true;
  assert(!empty.ensureSdMounted() && mounts==0);
}
''')

    def test_failed_live_retry_invalidates_cached_diagnostics_readiness(self):
        method = section("lib/storage/storage.cpp",
                         "StoragePreparation Storage::prepareDiagnosticsStorage()",
                         "\nbool Storage::ensureDiagnosticsSdMounted()")
        self.run_cpp(r'''

#include "ride_diagnostics/ride_diagnostics_transfer_policy.hpp"
#include "storage/storage_stream_admission.hpp"
#include <atomic>
#include <cassert>
#include <initializer_list>
#define WAVESHARE_AMOLED_175 1
using ride_diagnostics::transfer_policy::StoragePreparation;
constexpr int pdTRUE=1, portMAX_DELAY=-1, CARD_NONE=0;
int xSemaphoreTake(void *,int) { return pdTRUE; }
void xSemaphoreGive(void *) {}
namespace power_management { enum class LockDomain { Storage }; struct ScopedLock { explicit ScopedLock(LockDomain) {} }; }
enum class StorageBackend { Unavailable,NativeSdmmc };
int removableCardType(StorageBackend) { return 1; }
bool mountedDirectoryAvailable(const char *) { return true; }
bool writableProbeSucceeded(const char *) { return true; }
class Storage {
public:
 storage_shutdown::StreamAdmission streamAdmission_;
 std::atomic<bool> shutdownAdmissionClosed_{false},isSdLoaded{false},internalFallbackMounted{false},diagnosticsSdHealthy{true};
 std::atomic<StorageBackend> mountedBackend{StorageBackend::NativeSdmmc};
 std::atomic<StoragePreparation> lastDiagnosticsMountResult{StoragePreparation::ReadyRemovable};
 void *mountMutex=reinterpret_cast<void *>(1);
 // The live-backend guard refuses remount after markSdUnavailable().
 bool ensureSdMounted(bool) { return false; }
 StoragePreparation prepareDiagnosticsStorage();
};
''' + method + r'''

int main() {
 for (auto previous:{StoragePreparation::ReadyRemovable,StoragePreparation::ReadyInternalFallback,StoragePreparation::CardMissing}) {
   Storage store; store.lastDiagnosticsMountResult=previous;
   const auto result=store.prepareDiagnosticsStorage();
   assert(!ride_diagnostics::transfer_policy::storageReady(result));
   assert(store.lastDiagnosticsMountResult==result && !store.diagnosticsSdHealthy);
   if (previous==StoragePreparation::CardMissing) assert(result==previous);
 }
 Storage healthy; healthy.isSdLoaded=true;
 assert(healthy.prepareDiagnosticsStorage()==StoragePreparation::ReadyRemovable);
 healthy.isSdLoaded=false; healthy.internalFallbackMounted=true;
 assert(healthy.prepareDiagnosticsStorage()==StoragePreparation::ReadyInternalFallback);
}
''')

    def test_storage_mount_mutex_exists_before_concurrent_callers(self):
        header = source("lib/storage/storage.hpp")
        fields = "\n".join(line for line in header.splitlines()
                           if "mountMutex" in line)
        constructor = section("lib/storage/storage.cpp", "Storage::Storage()",
                              "\nbool Storage::pollShutdownQuiescence()")
        self.run_cpp(r'''
#include <atomic>
#include <cassert>
using SemaphoreHandle_t=void *;
struct StaticSemaphore_t { int storage=0; };
unsigned creations=0;
SemaphoreHandle_t xSemaphoreCreateMutexStatic(StaticSemaphore_t *storage) { ++creations; return storage; }
#define configASSERT(value) assert(value)
class Storage {
public:
  std::atomic<bool> isSdLoaded;
  void *card;
''' + fields + r'''
  Storage();
};
''' + constructor + r'''
int main() { Storage store; assert(store.mountMutex!=nullptr && creations==1); }
''')

    def test_map_read_releases_resources_when_binary_decoder_throws(self):
        self.map_allocation_case("binary")

    def test_map_read_releases_block_when_filename_allocation_throws(self):
        self.map_allocation_case("filename")

    def test_map_read_releases_resources_when_ascii_validation_throws(self):
        self.map_allocation_case("validation")

    def test_binary_decoder_replacement_allocation_does_not_double_delete(self):
        self.binary_allocation_case("replacement")

    def test_binary_poi_rejection_releases_ownership_once(self):
        for fault in ("poi-reject", "poi-replacement"):
            with self.subTest(fault=fault):
                self.binary_allocation_case(fault)

    def test_binary_poi_allocation_failure_and_success(self):
        for fault in ("poi-allocation", "poi-success"):
            with self.subTest(fault=fault):
                self.binary_allocation_case(fault)

    def binary_allocation_case(self, fault):
        reader = section("lib/maps/src/maps.cpp",
                         "Maps::MapBlock *Maps::readMapBlockBinary(char *file, size_t fileSize)",
                         "/**\n * @brief Build spatial grid index")
        fixture = Path(__file__).with_name("map_read_allocation_harness.cpp").read_text()
        self.run_cpp("#define REAL_BINARY_READER 1\n" +
                     fixture.replace("// PRODUCTION_READER", reader), fault)

    def test_map_read_ordinary_and_cancelled_ownership(self):
        for fault in ("success", "cancel", "buffer", "missing"):
            with self.subTest(fault=fault):
                self.map_allocation_case(fault)

    def map_allocation_case(self, fault):
        reader = section("lib/maps/src/maps.cpp", "Maps::MapBlock *Maps::readMapBlock(String fileName)",
                         "/**\n * @brief High performance binary map block reader")
        fixture = (Path(__file__).with_name("map_read_allocation_harness.cpp")).read_text()
        self.run_cpp(fixture.replace("// PRODUCTION_READER", reader), fault)


if __name__ == "__main__":
    unittest.main()
