// The production map-renderer storage entry points are inserted by
// test_sd_only_map_storage.py: block/terrain lookup, directory probe, root
// probe and switch, queued storage control and activation admission, Nearby
// queries and root binding. Every filesystem call they can make is counted.
// argv[1] holds a complete installed map under maps/a. With map storage
// available it must load; without it (a no-card boot whose FFat would own
// /sdcard) nothing may be opened, probed or queued.
#define BOARD_HAS_PSRAM 1
#define FIRMWARE_DIAGNOSTICS 1
#define MAP_POIS_RUNTIME_ENABLED 1
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <memory>
#include <new>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include "../../lib/maps/src/mapProbeDiagnostics.hpp"

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,    \
                   #condition);                                                \
      std::exit(42);                                                           \
    }                                                                          \
  } while (0)

// Counted filesystem. The production code below reaches these through the
// function-like macros defined just before it is inserted.
unsigned fsCalls = 0;
int countedOpen(const char *path, int flags) {
  ++fsCalls;
  return ::open(path, flags);
}
int countedStat(const char *path, struct stat *out) {
  ++fsCalls;
  return ::stat(path, out);
}
DIR *countedOpendir(const char *path) {
  ++fsCalls;
  return ::opendir(path);
}

template <typename... Arguments> void discardLog(const Arguments &...) {}
#define ESP_LOGI(...) discardLog(__VA_ARGS__)
#define ESP_LOGW(...) discardLog(__VA_ARGS__)
#define ESP_LOGE(...) discardLog(__VA_ARGS__)
#define MAPIO_LOG(...) discardLog(__VA_ARGS__)
#define MAPIO_TIME_MS() 0U
static const char *TAG = "Maps";
uint32_t millis() { return 0; }

struct FakeStorage {
  bool mapStorage = false;
  bool mapStorageAvailable() const { return mapStorage; }
} storage;

class String {
public:
  String() = default;
  String(const char *text) : text_(text) {}
  const char *c_str() const { return text_.c_str(); }
  bool endsWith(const char *suffix) const {
    const size_t length = std::strlen(suffix);
    return text_.size() >= length &&
           text_.compare(text_.size() - length, length, suffix) == 0;
  }
  String &operator+=(const char *suffix) {
    text_ += suffix;
    return *this;
  }
  String operator+(const char *suffix) const {
    return String((text_ + suffix).c_str());
  }
  bool operator==(const String &other) const { return text_ == other.text_; }

private:
  std::string text_;
};

constexpr unsigned MALLOC_CAP_SPIRAM = 1;
void *heap_caps_malloc(size_t bytes, unsigned) { return std::malloc(bytes); }
template <class T> using PsramAllocator = std::allocator<T>;
constexpr uint8_t MAX_ZOOM = 18;
using TaskHandle_t = void *;
using SemaphoreHandle_t = void *;
constexpr int pdTRUE = 1;
constexpr unsigned portMAX_DELAY = 0xffffffffU;
constexpr unsigned pdMS_TO_TICKS(unsigned milliseconds) { return milliseconds; }
int xSemaphoreTake(SemaphoreHandle_t, unsigned) { return pdTRUE; }
void xSemaphoreGive(SemaphoreHandle_t) {}
unsigned notifications = 0;
void xTaskNotifyGive(TaskHandle_t) { ++notifications; }

namespace power_management {
enum class LockDomain { Storage };
struct ScopedLock {
  explicit ScopedLock(LockDomain) {}
};
} // namespace power_management
namespace runtime_watchdog_diagnostics {
enum class Role { MapRender };
enum class Phase { MapBlockIo, MapBlockParse };
void notePhase(Role, Phase, uint32_t) {}
} // namespace runtime_watchdog_diagnostics
namespace map_block_format {
constexpr size_t kMaximumBlockBytes = 2 * 1024 * 1024;
}
namespace map_terrain {
struct Grid {};
enum class LoadResult { Complete, Cancelled };
constexpr off_t BYTES = 8;
template <class Read, class Cancel>
LoadResult loadGrid(uint8_t *, Grid &, Read, Cancel) {
  return LoadResult::Complete;
}
} // namespace map_terrain
namespace map_render_job {
enum class State { Idle, Ready };
}
namespace renderer_diagnostics {
enum class JobEvent { Stale };
void noteJobForWindow(uint32_t, JobEvent) {}
} // namespace renderer_diagnostics

namespace map_font_asset {
enum class RuntimeError { None };
unsigned opens = 0;
// Production calls Asset::open(); the counting macro renames that call site.
struct Asset {
  bool countedOpen(const std::string &path) {
    ++opens;
    ++fsCalls;
    return std::fopen(path.c_str(), "rb") != nullptr;
  }
  uint32_t profileFingerprint() const { return 7; }
  uint16_t glyphCount() const { return 1; }
  uint8_t languageCount() const { return 1; }
  bool healthy() const { return true; }
};
} // namespace map_font_asset

namespace map_nearby_query {
struct Position {
  double latitude = 0;
  double longitude = 0;
};
} // namespace map_nearby_query
namespace map_poi_index {
struct Entry {};
}
namespace map_nearby_coverage {
struct Block {};
}
template <class T> using MapNearbyVector = std::vector<T>;
namespace map_nearby_storage {
enum class Status : uint8_t {
  Ok, Unavailable, Corrupt, ReadFailed, Cancelled, ResourceRejected
};
using Cancel = bool (*)(void *);
struct SearchResult {
  Status status = Status::Unavailable;
};
bool invalidatesHealth(Status status) { return status == Status::Corrupt; }
unsigned indexReads = 0, cursors = 0;
bool readIndex(const std::string &, MapNearbyVector<map_poi_index::Entry> &,
               Cancel, void *, Status &status) {
  ++indexReads;
  ++fsCalls;
  status = Status::Ok;
  return true;
}
bool readCoverage(const std::string &,
                  std::vector<map_nearby_coverage::Block> &blocks,
                  Status &status) {
  ++indexReads;
  ++fsCalls;
  blocks.resize(1);
  status = Status::Ok;
  return true;
}
class SearchCursor {
public:
  SearchCursor(std::string, map_nearby_query::Position, uint32_t, double,
               const std::vector<map_nearby_coverage::Block> *) {
    ++cursors;
    ++fsCalls;
  }
  bool step(Cancel, void *) { return true; }
  SearchResult result() const { return {Status::Ok}; }
};
} // namespace map_nearby_storage

std::atomic<uint32_t> gMapRenderActiveSequence{0};
std::atomic<uint32_t> gMapRenderCancellationGeneration{0};
bool onMapRenderWorkerTask() { return true; }
bool shouldCancelMapRenderWork() { return false; }
bool validateMapBlockCooperatively(const std::string &, const uint8_t *, size_t,
                                   bool &interrupted) {
  interrupted = false;
  return false;
}

struct Point16 {
  int16_t x = 0, y = 0;
};
struct Bounds {
  Point16 min, max;
};
struct Polygon {
  uint16_t color = 0;
  uint8_t maxZoom = 0, typeId = 0;
  Bounds bbox;
  std::vector<Point16> points;
};
struct Polyline : Polygon {
  uint8_t width = 1;
};

uint8_t binaryFormatVersion = 3;

class Maps {
public:
  struct LabelData {
    uint32_t profileFingerprint = 7;
    bool referencesResolve(uint16_t, uint8_t) const { return true; }
  };
  struct MapBlock {
    bool inView = false;
    uint8_t formatVersion = 1;
    LabelData labelData;
    std::vector<map_terrain::Grid> terrain;
    std::vector<Polygon> polygons;
    std::vector<Polyline> polylines;
  };
  struct MemCache {
    std::vector<MapBlock *> blocks;
  } memCache;
  struct {
    void invalidate() {}
  } preparedScene;
  struct {
    void clear() {}
  } labelLayoutCache, buildingFailureRetryCooldown;
  struct NearbySearchRequest {
    uint32_t sequence = 0;
    map_nearby_query::Position rider{};
    uint32_t selectedMask = 0;
    double radiusM = 10000.0;
  } pendingNearbySearch{}, activeNearbyRequest{};
  struct NearbySearchCompletion {
    uint32_t sequence = 0;
    map_nearby_storage::SearchResult result{};
  } readyNearbySearch{};
  struct VectorMapActivationRequest {
    uint32_t sequence = 0;
    std::string folder;
  } pendingVectorMapActivation{};
  struct {
    uint16_t diagnosticsWindowId = 0;
  } readyJob;
  struct {
    map_render_job::State current = map_render_job::State::Idle;
    unsigned cancellations = 0;
    void requestCancellation() { ++cancellations; }
    map_render_job::State state() const { return current; }
    decltype(readyJob) ready() const { return {}; }
    void rejectReadyAsStale() {}
  } renderJobs;

  std::atomic<bool> isMapFound{false};
  uint32_t idx = 0;
  String vectorMapFolder;
  map_font_asset::Asset labelFontAsset;
  std::atomic<bool> streetLabelFontHealthy{false};
  std::atomic<bool> nearbyPoiIndexHealthy{false};
  std::vector<map_nearby_coverage::Block> nearbyCoverageBlocks;
  std::atomic<map_font_asset::RuntimeError> streetLabelRuntimeFailure{
      map_font_asset::RuntimeError::None};
  std::atomic<size_t> cachedBlockCount{0};
  std::atomic<bool> shutdownAdmissionClosed_{false};
  std::atomic<bool> renderWorkerShutdown{false};
  std::atomic<bool> renderWorkerRestartAfterExit{false};
  std::atomic<uint32_t> nearbySearchGeneration{0};
  TaskHandle_t renderWorkerTaskHandle = nullptr;
  SemaphoreHandle_t renderStateMutex = this;
  void (*pendingStorageControl_)(void *) = nullptr;
  void *pendingStorageControlContext_ = nullptr;
  bool pendingVectorMapActivationValid = false;
  bool completedVectorMapActivationValid = false;
  bool pendingNearbySearchValid = false;
  bool readyNearbySearchValid = false;
  bool latestRenderRequestValid = true;
  bool readyRenderResultValid = true;
  uint32_t vectorMapActivationSequence = 0;
  std::unique_ptr<map_nearby_storage::SearchCursor> activeNearbyCursor;
  unsigned workerStarts = 0;

  bool startRenderWorker() {
    ++workerStarts;
    renderWorkerTaskHandle = this;
    return true;
  }
  bool recoverRenderWorkerIfNeeded() { return true; }
  void cancelNearbySearch() {}
  void pauseNearbySearchOnStorageOwner() { activeNearbyCursor.reset(); }
  MapBlock *readMapBlockBinary(char *, size_t) {
    auto *block = new MapBlock();
    block->formatVersion = binaryFormatVersion;
    isMapFound = true;
    return block;
  }
  void parseStrUntil(char *, char, char *out) { out[0] = '\0'; }
  int16_t parseInt16(char *) { return 0; }
  bool parseCoords(char *, std::vector<Point16> &) { return false; }
  bool buildPolygonGrid(MapBlock *) { return true; }

  MapBlock *readMapBlock(String fileName);
  map_probe_diagnostics::Result
  probeVectorMapFolderOnStorageOwner(const std::string &folder);
  bool switchVectorMapFolderOnStorageOwner(const std::string &folder);
  bool requestStorageControl(void (*work)(void *), void *context);
  bool requestVectorMapFolderActivation(const std::string &folder);
  bool processPendingNearbySearch();
  void bindMapStorageRoot(const char *root);
};

#define open(...) countedOpen(__VA_ARGS__)
#define stat(...) countedStat(__VA_ARGS__)
#define opendir(...) countedOpendir(__VA_ARGS__)
// PRODUCTION_RENDERER
#undef opendir
#undef stat
#undef open

void queuedWork(void *) {}

struct Outcome {
  bool blockFound = false;
  bool missingFound = true;
  bool directoryFound = false;
  map_probe_diagnostics::Code probe = map_probe_diagnostics::Code::NotRun;
  bool switched = false;
  bool controlAdmitted = false;
  bool activationAdmitted = false;
  map_nearby_storage::Status nearby = map_nearby_storage::Status::Corrupt;
  unsigned workerStarts = 0;
};

Outcome exercise(const std::string &root, bool mapStorage) {
  storage.mapStorage = mapStorage;
  fsCalls = map_font_asset::opens = 0;
  map_nearby_storage::indexReads = map_nearby_storage::cursors = 0;
  Maps maps;
  maps.bindMapStorageRoot(root.c_str());
  CHECK(std::string(maps.vectorMapFolder.c_str()) == root + "/VECTMAP/");
  // An installed map root, distinct from the bound legacy default folder.
  const std::string tree = root + "/maps/a";
  Outcome outcome;

  std::unique_ptr<Maps::MapBlock> block(
      maps.readMapBlock(String((tree + "/+000+000/0_0").c_str())));
  outcome.blockFound = block != nullptr && maps.isMapFound.load();
  std::unique_ptr<Maps::MapBlock> missing(
      maps.readMapBlock(String((tree + "/+000+000/9_9").c_str())));
  outcome.missingFound = maps.isMapFound.load();

  std::string base;
  size_t visited = 0;
  outcome.directoryFound = findMapBlock(tree, base, visited, 0);
  outcome.probe = maps.probeVectorMapFolderOnStorageOwner(tree).code;
  outcome.switched = maps.switchVectorMapFolderOnStorageOwner(tree);
  if (!outcome.switched)
    CHECK(std::string(maps.vectorMapFolder.c_str()) == root + "/VECTMAP/");

  int context = 0;
  outcome.controlAdmitted = maps.requestStorageControl(queuedWork, &context);
  CHECK(outcome.controlAdmitted == (maps.pendingStorageControl_ != nullptr));
  maps.pendingStorageControl_ = nullptr;
  outcome.activationAdmitted = maps.requestVectorMapFolderActivation(tree);
  CHECK(outcome.activationAdmitted == maps.pendingVectorMapActivationValid);
  maps.pendingVectorMapActivationValid = false;

  // A query with stale coverage must still not reach the POI index.
  maps.nearbyCoverageBlocks.resize(1);
  maps.pendingNearbySearch.sequence = 1;
  maps.pendingNearbySearchValid = true;
  maps.nearbySearchGeneration = 1;
  CHECK(maps.processPendingNearbySearch());
  CHECK(maps.readyNearbySearchValid && maps.readyNearbySearch.sequence == 1);
  outcome.nearby = maps.readyNearbySearch.result.status;
  outcome.workerStarts = maps.workerStarts;
  return outcome;
}

int main(int argc, char **argv) {
  CHECK(argc == 2);
  const std::string root = argv[1];

  // Ordinary SD behavior: blocks, terrain, probe, font, switch, Nearby and
  // queued work all run, and a missing block is a real filesystem lookup.
  const Outcome sd = exercise(root, true);
  CHECK(sd.blockFound && !sd.missingFound && sd.directoryFound);
  CHECK(sd.probe == map_probe_diagnostics::Code::Ok);
  CHECK(sd.switched && map_font_asset::opens >= 2);
  CHECK(sd.controlAdmitted && sd.activationAdmitted);
  CHECK(sd.nearby == map_nearby_storage::Status::Ok);
  CHECK(map_nearby_storage::cursors == 1 && map_nearby_storage::indexReads == 2);
  CHECK(fsCalls > 0);

  // No-card boot: the same complete tree stands in for files on FFat. No
  // lookup, probe, font, index or queued operation may touch it.
  const Outcome noCard = exercise(root, false);
  CHECK(!noCard.blockFound && !noCard.missingFound && !noCard.directoryFound);
  CHECK(noCard.probe == map_probe_diagnostics::Code::RootUnavailable);
  CHECK(!noCard.switched);
  CHECK(!noCard.controlAdmitted && !noCard.activationAdmitted);
  CHECK(noCard.workerStarts == 0);
  CHECK(noCard.nearby == map_nearby_storage::Status::Unavailable);
  CHECK(map_font_asset::opens == 0 && map_nearby_storage::indexReads == 0);
  CHECK(map_nearby_storage::cursors == 0);
  CHECK(fsCalls == 0);
  std::puts("map storage boundary harness passed");
  return 0;
}
