"""Execute actual activation and UI retry branches with deterministic faults."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def fragment(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("unterminated production fragment: " + signature)


class NearbyLifecycleTests(unittest.TestCase):
    def run_fixture(self, source):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory(prefix="nearby-lifecycle-") as temporary:
            root = Path(temporary)
            candidate = root / "candidate"
            candidate.mkdir()
            fixture = root / "fixture.cpp"
            fixture.write_text(source)
            binary = root / "fixture"
            for command in (
                [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                 "-DMAP_POIS_RUNTIME_ENABLED=1", str(fixture), "-o", str(binary)],
                [str(binary), str(candidate)],
            ):
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_activation_preserves_old_map_on_transient_metadata_failure(self):
        source = (ROOT / "lib/maps/src/maps.cpp").read_text()
        fixture = r'''
#include <atomic>
#include <cassert>
#include <new>
#include <string>
#include <vector>
#include <sys/stat.h>
#define ESP_LOGE(...) ((void)0)
struct String : std::string {
  using std::string::string;
  bool endsWith(const char *suffix) const {
    const std::string tail(suffix);
    return size() >= tail.size() && compare(size()-tail.size(), tail.size(), tail)==0;
  }
};
namespace power_management {
enum class LockDomain { Storage };
struct ScopedLock { explicit ScopedLock(LockDomain) {} };
}
namespace map_font_asset {
enum class RuntimeError { None };
struct Asset { bool open(const std::string &) { return true; }
               bool healthy() const { return true; } };
}
namespace map_poi_index { struct Entry {}; }
namespace map_nearby_coverage { struct Block { int x, y; }; }
template<typename T> using MapNearbyVector = std::vector<T>;
namespace map_nearby_storage {
enum class Status { Ok, Unavailable, Corrupt, ReadFailed, Cancelled, ResourceRejected };
static Status indexStatus, coverageStatus;
static bool failIndexAllocation, failCoverageAllocation;
bool readIndex(const std::string &, std::vector<map_poi_index::Entry> &,
               void *, void *, Status &status) {
  if (failIndexAllocation) throw std::bad_alloc();
  status = indexStatus;
  return status == Status::Ok;
}
bool readCoverage(const std::string &, std::vector<map_nearby_coverage::Block> &out,
                  Status &status) {
  if (failCoverageAllocation) throw std::bad_alloc();
  status = coverageStatus;
  if (status == Status::Ok) out = {{1, 2}};
  return status == Status::Ok;
}
}
struct MapBlock {};
struct Cache { std::vector<MapBlock *> blocks{nullptr}; };
struct Scene { bool invalidated = false; void invalidate() { invalidated = true; } };
struct Clearable { unsigned clears=0; void clear() { ++clears; } };
class Maps {
public:
  String vectorMapFolder = "/old/";
  Cache memCache;
  Scene preparedScene;
  std::atomic<unsigned> cachedBlockCount{1};
  map_font_asset::Asset labelFontAsset;
  std::atomic<bool> streetLabelFontHealthy{true}, nearbyPoiIndexHealthy{true};
  std::vector<map_nearby_coverage::Block> nearbyCoverageBlocks{{7, 8}};
  Clearable labelLayoutCache, buildingFailureRetryCooldown;
  std::atomic<map_font_asset::RuntimeError> streetLabelRuntimeFailure{
      map_font_asset::RuntimeError::None};
  unsigned cancellations=0;
  bool isMapFound=true;
  void cancelNearbySearch() { ++cancellations; }
  bool switchVectorMapFolderOnStorageOwner(const std::string &);
};
'''
        fixture += fragment(source, "bool Maps::switchVectorMapFolderOnStorageOwner(")
        fixture += r'''
int main(int argc, char **argv) {
  assert(argc == 2);
  using namespace map_nearby_storage;
  for (int fault=0; fault<8; ++fault) {
    indexStatus=Status::Ok; coverageStatus=Status::Ok;
    failIndexAllocation=false; failCoverageAllocation=false;
    if (fault == 0) indexStatus=Status::ReadFailed;
    if (fault == 1) coverageStatus=Status::ReadFailed;
    if (fault == 2) failIndexAllocation=true;
    if (fault == 3) failCoverageAllocation=true;
    if (fault == 4) indexStatus=Status::Cancelled;
    if (fault == 5) indexStatus=Status::Unavailable; // a legacy map has no index
    if (fault == 6) indexStatus=Status::Corrupt; // degrade POIs, preserve base map
    Maps maps;
    const bool committed=maps.switchVectorMapFolderOnStorageOwner(argv[1]);
    if (fault < 5) {
      assert(!committed);
      assert(maps.vectorMapFolder == "/old/");
      assert(maps.memCache.blocks.size()==1 && maps.cachedBlockCount.load()==1);
      assert(!maps.preparedScene.invalidated && maps.cancellations==0);
      assert(maps.nearbyPoiIndexHealthy.load());
      assert(maps.nearbyCoverageBlocks.size()==1 && maps.nearbyCoverageBlocks[0].x==7);
      assert(maps.labelLayoutCache.clears==0 && maps.isMapFound);
    } else {
      assert(committed);
      assert(maps.vectorMapFolder == std::string(argv[1])+"/");
      assert(maps.memCache.blocks.empty() && maps.cachedBlockCount.load()==0);
      assert(maps.preparedScene.invalidated && maps.cancellations==1);
      assert(maps.nearbyPoiIndexHealthy.load() == (fault==7));
    }
  }
}
'''
        self.run_fixture(fixture)

    def test_ui_retries_superseded_queries_not_slow_current_queries(self):
        source = (ROOT / "lib/gui/src/mainScr.cpp").read_text()
        header = (ROOT / "lib/maps/src/maps.hpp").read_text()
        fixture = r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#include <initializer_list>
struct Nearby {
  bool querying=true, haveResults=false;
  uint32_t querySequence=42, lastQueryMs=0;
  void *status=nullptr;
} nearby;
void lv_label_set_text(void *, const char *) {}
struct View {
  unsigned cancellations=0;
  std::atomic<uint32_t> nearbySearchGeneration{42};
  std::atomic<bool> renderWorkerShutdown{false};
  void cancelNearbySearch() { ++cancellations; ++nearbySearchGeneration; }
'''
        # At the baseline no accessor exists or is called; after the fix compile
        # its actual production body too, rather than substituting a policy mock.
        if "bool nearbySearchIsCurrent(" in header:
            fixture += fragment(header, "bool nearbySearchIsCurrent(")
        fixture += "\n} mapView;\nvoid retry(uint32_t nowMs) {\n"
        fixture += fragment(source, "  if (nearby.querying &&")
        fixture += r'''
}
int main() {
  // A valid query can need many scheduled slices. Elapsed time, including a
  // wrapping millisecond clock, must not discard a still-current generation.
  for (uint32_t now : {100U, 14999U, 15000U, 20000U, UINT32_MAX}) {
    nearby=Nearby{}; mapView.nearbySearchGeneration=42;
    mapView.renderWorkerShutdown=false; mapView.cancellations=0;
    retry(now);
    assert(nearby.querying && nearby.querySequence==42 && mapView.cancellations==0);
  }
  for (bool shutdown : {false, true}) {
    nearby=Nearby{}; mapView.nearbySearchGeneration=shutdown ? 42 : 43;
    mapView.renderWorkerShutdown=shutdown; mapView.cancellations=0;
    retry(100U); // detect cancellation without waiting fifteen seconds
    assert(!nearby.querying && nearby.querySequence==0 && nearby.lastQueryMs==100U);
    assert(mapView.cancellations==0); // never cancel the replacement generation
  }
  nearby=Nearby{}; nearby.querying=false;
  mapView.nearbySearchGeneration=43; mapView.cancellations=0;
  retry(30000U);
  assert(mapView.cancellations==0);
}
'''
        self.run_fixture(fixture)


if __name__ == "__main__":
    unittest.main()
