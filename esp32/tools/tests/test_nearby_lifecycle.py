"""Execute actual activation, GPS gating and UI retry branches with faults."""
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
                 "-DMAP_POIS_RUNTIME_ENABLED=1",
                 "-I", str(ROOT / "lib/ble_navigation"),
                 "-I", str(ROOT / "lib/maps/src"),
                 str(fixture), "-o", str(binary)],
                [str(binary), str(candidate)],
            ):
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_both_hardware_short_presses_return_to_picker_before_cycling(self):
        source = (ROOT / "lib/gui/src/mainScr.cpp").read_text()
        fixture = r'''
#include <cassert>
bool isMainScreen=true;
void *mainScreen=(void*)1, *mapTile=(void*)1, *navTile=(void*)1,
     *rideStatsTile=(void*)1, *batteryStatusTile=(void*)1,
     *worldRadioTile=nullptr, *elevationTile=nullptr, *mapGuidanceOverlay=(void*)1;
namespace world_radio_config { constexpr bool ENABLED=false; }
namespace route_elevation_config { constexpr bool ENABLED=false; }
constexpr unsigned NEARBY=7;
unsigned activeTile=NEARBY, next=0, previous=0, picker=0;
struct { bool showingMap=true; } nearby;
void showNearbyPicker() { ++picker; nearby.showingMap=false; }
void showNextMainScreen() { ++next; }
void showPreviousMainScreen() { ++previous; }
'''
        fixture += fragment(source, "void toggleNavigationScreen()")
        fixture += fragment(source, "void togglePreviousNavigationScreen()")
        fixture += r'''
int main() {
  toggleNavigationScreen();
  assert(picker==1 && next==0 && !nearby.showingMap);
  nearby.showingMap=true;
  togglePreviousNavigationScreen();
  assert(picker==2 && previous==0 && !nearby.showingMap);
  toggleNavigationScreen(); togglePreviousNavigationScreen();
  assert(next==1 && previous==1); // picker still permits normal screen cycling
  activeTile=0; nearby.showingMap=true;
  toggleNavigationScreen(); togglePreviousNavigationScreen();
  assert(next==2 && previous==2 && picker==2);
  activeTile=NEARBY; isMainScreen=false;
  toggleNavigationScreen(); togglePreviousNavigationScreen();
  assert(next==2 && previous==2 && picker==2);
}
'''
        self.run_fixture(fixture)

    def test_icon_binding_retains_alpha_plane_on_creation_and_rebinding(self):
        source = (ROOT / "lib/gui/src/mainScr.cpp").read_text()
        fixture = r'''
#include <array>
#include <cassert>
#include <cstdint>
#include "mapNearbyIcons.hpp"
struct Buffer { unsigned data_size=0; void *data=nullptr; };
struct lv_obj_t { Buffer buffer; };
constexpr int LV_COLOR_FORMAT_RGB565A8=1;
alignas(4) std::array<std::array<uint8_t,16*16*3>,5> nearbyIconPixels{};
void lv_canvas_set_buffer(lv_obj_t *icon,void *data,int w,int h,int cf) {
  assert(w==16 && h==16 && cf==LV_COLOR_FORMAT_RGB565A8);
  icon->buffer={512,data}; // reproduce the pinned LVGL metadata quirk
}
Buffer *lv_canvas_get_draw_buf(lv_obj_t *icon) { return &icon->buffer; }
'''
        fixture += fragment(source, "static void nearbyBindIcon(")
        fixture += r'''
int main() {
  lv_obj_t icon;
  for (uint8_t category=1; category<=5; ++category) {
    nearbyBindIcon(&icon,category);
    assert(icon.buffer.data_size==768);
    assert(icon.buffer.data==nearbyIconPixels[category-1].data());
  }
  nearbyBindIcon(&icon,0); nearbyBindIcon(nullptr,1);
  assert(icon.buffer.data_size==768);
}
'''
        self.run_fixture(fixture)

    def test_pins_use_actual_canvas_transform_during_drag_and_settlement(self):
        source = (ROOT / "lib/maps/src/maps.cpp").read_text()
        fixture = r'''
#include <cassert>
#include <cmath>
#include "mapNearbyQuery.hpp"
#include "mapNearbyLayout.hpp"
#include "mapPresentation.hpp"
#include "mapTransform.hpp"
constexpr double EARTH_RADIUS=6378137.0;
constexpr int LV_SCALE_NONE=256;
struct Canvas { int x=40, y=60, px=0, py=0, angle=0, sx=256, sy=256; } canvas;
struct lv_point_t { int x,y; };
void lv_obj_update_layout(Canvas *) {}
int lv_obj_get_x(Canvas *p) { return p->x; }
int lv_obj_get_y(Canvas *p) { return p->y; }
int lv_image_get_rotation(Canvas *p) { return p->angle; }
int lv_image_get_scale_x(Canvas *p) { return p->sx; }
int lv_image_get_scale_y(Canvas *p) { return p->sy; }
void lv_image_get_pivot(Canvas *p,lv_point_t *v) { *v={p->px,p->py}; }
struct Projection {
  struct Config { struct { double x=0; } worldOrigin; };
  Config config() const { return {}; }
  struct Point { double x=100, y=120; bool valid=true; } point;
  Point projectWorld(map_transform::WorldPoint) const { return point; }
  struct Ground { double lateral=3, forward=4; };
  Ground groundForWorld(map_transform::WorldPoint) const { return {}; }
};
struct Maps {
  bool publishedMapFrame=true, hasVisibleProjection=true;
  Canvas *canvasMap=&canvas;
  Projection visibleProjection;
  bool projectNearbyResult(const map_nearby_query::Result &,map_nearby_layout::Input &) const;
};
'''
        fixture += fragment(source, "bool Maps::projectNearbyResult(")
        fixture += r'''
int main() {
  Maps view;
  map_nearby_query::Result place{};
  place.position={31.2,121.4}; place.category=2; place.directDistanceM=100;
  map_nearby_layout::Input pin;
  assert(view.projectNearbyResult(place,pin) && pin.projected);
  assert(pin.x==140 && pin.y==180 && pin.category==2);
  canvas.x+=30; canvas.y-=20; // live drag, before a new raster exists
  assert(view.projectNearbyResult(place,pin));
  assert(pin.x==170 && pin.y==160);
  assert(view.projectNearbyResult(place,pin)); // clamped/settling pixels unchanged
  assert(pin.x==170 && pin.y==160);
  canvas.x-=100; view.visibleProjection.point.x+=100; // synthetic source-frame rebase
  assert(view.projectNearbyResult(place,pin));
  assert(pin.x==170 && pin.y==160);
  canvas={40,60,20,30,900,512,256};
  view.visibleProjection.point={100,120,true};
  assert(view.projectNearbyResult(place,pin));
  assert(std::abs(pin.x-(-30))<1e-8 && std::abs(pin.y-250)<1e-8);
  view.visibleProjection.point.valid=false;
  assert(view.projectNearbyResult(place,pin) && !pin.projected);
  assert(std::abs(pin.directionX-4)<1e-8 && std::abs(pin.directionY-6)<1e-8);
  view.publishedMapFrame=false;
  assert(!view.projectNearbyResult(place,pin));
}
'''
        self.run_fixture(fixture)

    def test_picker_is_black_with_selection_borders_and_no_checkbox_or_map_back_button(self):
        source = (ROOT / "lib/gui/src/mainScr.cpp").read_text()
        picker = fragment(source, "static void createNearbyScreen() {")
        state = fragment(source, "static void nearbyPickerStatus()")
        self.assertIn("lv_color_black()", picker)
        self.assertIn("lv_obj_remove_style_all(button)", picker)
        self.assertIn("lv_obj_set_style_bg_opa(button, LV_OPA_TRANSP, 0)", picker)
        # The selection persists and a tap toggles it, so the selected state
        # is both a thicker border and a fill, not a border alone.
        self.assertIn("selected ? 3 : 0", state)
        self.assertIn("selected ? LV_OPA_30 : LV_OPA_TRANSP", state)
        self.assertIn("lv_obj_set_style_bg_color(button, lv_color_hex(0x80E8A1), 0)", picker)
        self.assertNotIn("categoryChecks", source)
        self.assertNotIn('"[x]"', source)
        self.assertNotIn('"Categories"', picker)
        self.assertNotIn("Direct distance - not route distance", source)

    def test_results_name_crowded_out_categories_and_mark_mixed_groups(self):
        # Nearby keeps the nearest ten in total. When a selected category is
        # absent from either coverage mode, say so; a merged group of
        # different categories gets a distinct count badge.
        source = (ROOT / "lib/gui/src/mainScr.cpp").read_text()
        service = fragment(source, "static void serviceNearbyScreen(uint32_t nowMs) {")
        self.assertIn("nearby.selectedMask, categories, count", service)
        markers = fragment(source, "static void refreshNearbyMarkers(uint32_t nowMs) {")
        self.assertIn("const bool mixed = placed.category == 0;", markers)
        self.assertIn("mixed ? LV_OPA_COVER : LV_OPA_TRANSP", markers)

    def test_actual_status_keeps_absent_category_and_partial_coverage_warning(self):
        source = (ROOT / "lib/gui/src/mainScr.cpp").read_text()
        fixture = r'''
#include <algorithm>
#include <cassert>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include "mapNearbyLayout.hpp"
namespace map_nearby_storage {
enum class Status {Ok, Unavailable, Corrupt, ReadFailed, ResourceRejected, Cancelled};
}
struct Result {
  map_nearby_storage::Status status=map_nearby_storage::Status::Ok;
  unsigned count=10;
  bool coverageComplete=false;
  struct Place {uint8_t category=2;} places[10];
} replacement;
struct {
  void *status=nullptr;
  double radiusM=10000;
  uint32_t selectedMask=(1U<<1U)|(1U<<2U), querySequence=1;
  bool haveResults=true;
} nearby;
std::string displayed;
void lv_label_set_text(void *,const char *text) {displayed=text;}
// The device formats with LVGL's built-in printf and LV_USE_FLOAT 0, where a
// float conversion prints its letter and consumes no argument. Reject it
// rather than let the host's vsnprintf format it.
void lv_label_set_text_fmt(void *,const char *format,...) {
  for (const char *p=format; *p; ++p) {
    if (*p!='%' || *++p=='%') continue;
    while (*p && std::strchr("-+ #0123456789.*hljztL",*p)) ++p;
    assert(*p && !std::strchr("fFeEgGaA",*p));
  }
  char value[512]; va_list args; va_start(args,format);
  vsnprintf(value,sizeof(value),format,args); va_end(args); displayed=value;
}
'''
        fixture += fragment(source, "static unsigned nearbyRadiusKm() {")
        fixture += "\nvoid refreshStatus() {\n"
        fixture += fragment(source, "switch (replacement.status)")
        fixture += r'''
}
int main() {
  refreshStatus();
  assert(displayed.rfind("10 places - 10 km\n", 0)==0);
  assert(displayed.find("No toilets in nearest 10")!=std::string::npos);
  assert(displayed.find("Downloaded area only; map edge nearby")!=std::string::npos);
  replacement.coverageComplete=true; refreshStatus();
  assert(displayed.find("No toilets in nearest 10")!=std::string::npos);
  assert(displayed.find("map edge")==std::string::npos);
  replacement.places[0].category=3; refreshStatus();
  assert(displayed=="10 places - 10 km");
  replacement.coverageComplete=false; replacement.count=0; refreshStatus();
  assert(displayed=="No matches in downloaded area (10 km)\nMap edge nearby");
  replacement.coverageComplete=true; refreshStatus();
  assert(displayed=="No matching places within 10 km in this map");
  nearby.radiusM=25000; refreshStatus();
  assert(displayed=="No matching places within 25 km in this map");
}
'''
        self.run_fixture(fixture)

    def test_search_uses_current_position_source_not_onboard_receiver_fix(self):
        source = (ROOT / "lib/gui/src/mainScr.cpp").read_text()
        fixture = r'''
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include "gps_input_freshness.hpp"
#include "mapNearbyQuery.hpp"
bool isGpsFixed=false; // Onboard NMEA receiver has no fix indoors.
struct Gps {
  struct Data { double latitude=31.2, longitude=121.4; } gpsData;
  GpsSampleTiming presentationSample;
} gps;
struct Server {
  struct Stats { GpsSampleTiming gpsSource; } stats;
  Stats getDebugStats() const { return stats; }
} bleNavServer;
struct Nearby {
  bool showingMap=true, querying=false, haveResults=false, waitingForPosition=false;
  uint32_t selectedMask=3, lastQueryMs=0, querySequence=0;
  double radiusM=10000;
  map_nearby_query::Position lastQueryPosition;
  void *status=nullptr;
} nearby;
const char *lastStatus=nullptr;
void lv_label_set_text(void *, const char *text) { lastStatus=text; }
struct View {
  unsigned requests=0;
  uint32_t nextSequence=42;
  uint32_t requestNearbySearch(map_nearby_query::Position position,
                              uint32_t mask, double radius) {
    assert(position.latitude==gps.gpsData.latitude);
    assert(position.longitude==gps.gpsData.longitude);
    assert(mask==3 && radius==10000);
    ++requests;
    return nextSequence;
  }
} mapView;
'''
        fixture += fragment(source, "static bool nearbyFreshPosition(")
        fixture += "\n" + fragment(source, "static void nearbyStartSearch(")
        fixture += "\n" + fragment(source, "static bool nearbyRefreshPosition(")
        fixture += "\nvoid retrySearch(uint32_t nowMs) {\n"
        fixture += "map_nearby_query::Position current{gps.gpsData.latitude, gps.gpsData.longitude};\n"
        fixture += fragment(source, "  if (!nearby.querying &&\n      static_cast<uint32_t>(nowMs - nearby.lastQueryMs)")
        fixture += "\n}\n"
        fixture += r'''
void expectSearch(uint32_t now, bool expected) {
  nearby=Nearby{}; mapView.requests=0; lastStatus=nullptr;
  nearbyStartSearch(now);
  assert(mapView.requests==(expected ? 1U : 0U));
  assert(nearby.querying==expected);
  assert(std::strcmp(lastStatus, expected ? "Finding nearby places..."
                                         : "Waiting for GPS")==0);
  assert(nearby.querySequence==(expected ? 42U : 0U));
}
int main() {
  // A stationary phone can have a fresh location without a speed sample or
  // an independent satellite fix on the bike. Exercise the production search
  // entry point, not a duplicated approximation of its predicate.
  gps.presentationSample={true, false, 1000, RidePositionSource::AuthenticatedBle};
  bleNavServer.stats.gpsSource=gps.presentationSample;
  expectSearch(1075, true);
  assert(!isGpsFixed); // Do not change the onboard receiver's status globally.
  nearby.querying=false; nearby.haveResults=true;
  map_nearby_query::Position position;
  assert(!nearbyRefreshPosition(3500, position));
  assert(nearby.waitingForPosition);
  assert(std::strcmp(lastStatus, "Waiting for GPS - results stale")==0);
  bleNavServer.stats.gpsSource.capturedAtMs=3501;
  const auto requestsBeforeRecovery=mapView.requests;
  assert(nearbyRefreshPosition(3502, position));
  assert(!nearby.waitingForPosition && nearby.querying);
  assert(mapView.requests==requestsBeforeRecovery+1);
  assert(std::strcmp(lastStatus, "Updating nearby places...")==0);
  assert(nearbyRefreshPosition(3503, position));
  assert(mapView.requests==requestsBeforeRecovery+1);
  nearby.querying=false;
  assert(!nearbyRefreshPosition(6001, position));
  bleNavServer.stats.gpsSource.capturedAtMs=6002;
  mapView.nextSequence=0; // transient worker/mutex admission rejection
  assert(nearbyRefreshPosition(6003, position));
  assert(nearby.haveResults && !nearby.querying && nearby.querySequence==0);
  assert(std::strcmp(lastStatus, "Nearby search unavailable")==0);
  const auto rejectedRequests=mapView.requests;
  mapView.nextSequence=42;
  bleNavServer.stats.gpsSource.capturedAtMs=11002;
  assert(nearbyRefreshPosition(11002, position));
  retrySearch(11002);
  assert(mapView.requests==rejectedRequests);
  retrySearch(11003); // same coordinates, existing five-second backoff
  assert(mapView.requests==rejectedRequests+1 && nearby.querying);
  assert(nearby.querySequence==42 && nearby.haveResults);
  bleNavServer.stats.gpsSource.capturedAtMs=1000;
  expectSearch(3499, true);
  expectSearch(3500, false); // Keep the existing strict 2.5-second freshness bound.

  // Repeated transport traffic must not make an old source measurement fresh.
  bleNavServer.stats.gpsSource.capturedAtMs=1000;
  expectSearch(10000, false);
  // BLE disconnect/session invalidation supersedes cached presentation state.
  bleNavServer.stats.gpsSource={};
  expectSearch(1075, false);
  isGpsFixed=true;
  expectSearch(1075, false); // An onboard fix cannot bless a stale BLE source.
  bleNavServer.stats.gpsSource={false, false, 1000,
                              RidePositionSource::AuthenticatedBle};
  expectSearch(1075, false); // Unknown source age stays unavailable.

  bleNavServer.stats.gpsSource={true, false, UINT32_MAX-1000,
                              RidePositionSource::AuthenticatedBle};
  expectSearch(100, true); // Millisecond wrap remains valid.
  gps.gpsData.latitude=std::numeric_limits<double>::quiet_NaN();
  expectSearch(100, false);
  gps.gpsData.latitude=91;
  expectSearch(100, false);
  gps.gpsData.latitude=31.2; gps.gpsData.longitude=181;
  expectSearch(100, false);
  gps.gpsData.longitude=121.4;

  // Physical NMEA sources retain their own validated capture clock and do not
  // inherit a fresh or invalidated BLE sample.
  gps.presentationSample={true, false, 1000, RidePositionSource::HardwareNmea};
  bleNavServer.stats.gpsSource={};
  expectSearch(1075, true);
  expectSearch(3500, false);
  gps.presentationSample.ageKnown=false;
  expectSearch(1075, false);
}
'''
        self.run_fixture(fixture)

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
