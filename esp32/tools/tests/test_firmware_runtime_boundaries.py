"""Execute production firmware boundaries with deterministic host dependencies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def section(path, start, end):
    source = (ROOT / path).read_text()
    first = source.index(start)
    return source[first:source.index(end, first)]


class FirmwareRuntimeBoundaryTests(unittest.TestCase):
    def run_cpp(self, fixture):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory(prefix="firmware-boundary-") as directory:
            path = Path(directory)
            (path / "test.cpp").write_text(fixture)
            subprocess.run([
                compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                "-fsanitize=undefined", "-fno-sanitize-recover=all",
                "-I", str(ROOT / "lib"), str(path / "test.cpp"),
                "-o", str(path / "test"),
            ], check=True)
            result = subprocess.run([str(path / "test")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ride_evaluation_clock_follows_imu_acquisition(self):
        calls = section("src/main.cpp", "  waveshare_board::imu::process();",
                        "\n  logSystemDebugHeartbeat();")
        calls = "\n".join(line for line in calls.splitlines()
                          if not line.startswith("#"))
        self.run_cpp(r'''
#include "ride_automation/ride_automation_policy.hpp"
#include <cassert>
#include <cstdint>
uint32_t clockMs = 0;
uint32_t sampleDelayMs = 0;
ride_automation::TimedMetric sample{};
uint32_t millis() { return clockMs; }
namespace waveshare_board::imu {
void process() {
  clockMs += sampleDelayMs;
  sample = {true, 0.1F, clockMs, 3000};
}
}
namespace ride_automation_runtime {
void processFirmwareShadow(uint32_t nowMs) {
  assert(ride_automation::metricFresh(sample, nowMs, 3000));
}
}
void loopBoundary() {
  const uint32_t now = millis();
  (void)now;
''' + calls + r'''
}
int main() {
  for (const uint32_t start : {1000U, UINT32_MAX - 5U}) {
    for (const uint32_t delay : {1U, 25U, 250U}) {
      clockMs = start;
      sampleDelayMs = delay;
      loopBoundary();
    }
  }
}
''')

    def test_route_rejection_has_no_map_side_effects(self):
        handler = section("lib/ble_navigation/ble_navigation.cpp",
                          "static void handleRouteGeometryPayload(",
                          "\nstatic void handleGpsPayload(")
        self.run_cpp(r'''
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstddef>
#include <vector>
struct SerialStub {
  void println(const char *) {}
  template<class... T> void printf(const char *, T...) {}
} Serial;
namespace power_metrics {
enum class BlePacketClass { Route };
void noteBlePacket(BlePacketClass) {}
}
namespace map_render_policy { enum class Reason { Route }; }
void requestMapRender(map_render_policy::Reason) {}
void clearCurrentNavigationData() {}
struct BLEDebugStats { uint32_t routePacketCount=0, lastRoutePacketMs=0; };
struct Stats {
  template<class F> void updateWith(F f) { BLEDebugStats state; f(state); }
} bleDebugStats;
uint32_t millis() { return 1000; }
uint32_t lastRouteHash = 0;
size_t lastRouteLen = 0;
bool gpsReceivedFromApp = false;
struct Gps { struct Data { double latitude=10, longitude=20; } gpsData; } gps;
int mapEntryCalls = 0;
bool noteNavigationInputForMapEntry() { ++mapEntryCalls; return true; }
struct Overlay {
  bool accept = false;
  int parseCalls = 0;
  bool hasRoute() { return true; }
  void clear() {}
  std::vector<uint8_t> stored;
  bool matchesRouteData(const uint8_t *bytes, size_t length) const {
    return stored == std::vector<uint8_t>(bytes, bytes + length);
  }
  bool parseRouteData(const uint8_t *bytes, size_t length) {
    ++parseCalls;
    if (accept) stored.assign(bytes, bytes + length);
    return accept;
  }
} routeOverlay;
''' + handler + r'''
int main() {
  const int32_t points[] = {30000000, 40000000, 0};
  const auto *bytes = reinterpret_cast<const uint8_t *>(points);
  handleRouteGeometryPayload(bytes, sizeof(points), "native");
  assert(gps.gpsData.latitude == 10 && gps.gpsData.longitude == 20);
  assert(mapEntryCalls == 0 && lastRouteLen == 0);
  routeOverlay.accept = true;
  handleRouteGeometryPayload(bytes, sizeof(points), "fallback");
  assert(gps.gpsData.latitude == 30 && gps.gpsData.longitude == 40);
  assert(mapEntryCalls == 1 && lastRouteLen == sizeof(points));
  // Re-pairing may require map entry even when route content is unchanged.
  handleRouteGeometryPayload(bytes, sizeof(points), "fallback");
  assert(mapEntryCalls == 2 && routeOverlay.parseCalls == 2);
  // These distinct WGS-84 routes have equal length and the same base-31 hash.
  uint8_t colliding[12] = {0, 31};
  handleRouteGeometryPayload(colliding, sizeof(colliding), "native");
  const uint32_t collisionHash = lastRouteHash;
  assert(routeOverlay.parseCalls == 3);
  colliding[0] = 1; colliding[1] = 0;
  handleRouteGeometryPayload(colliding, sizeof(colliding), "fallback");
  assert(lastRouteHash == collisionHash);
  assert(routeOverlay.parseCalls == 4);
}
''')

    def test_malformed_route_preserves_previous_geometry(self):
        parser = section("lib/route_overlay/route_overlay.cpp",
                         "bool RouteOverlay::parseRouteData(",
                         "\nvoid RouteOverlay::clear()")
        self.run_cpp(r'''
#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>
#include <memory>
#include <new>
struct SerialStub {
  void println(const char *) {}
  template<class... T> void printf(const char *, T...) {}
} Serial;
struct GeoPoint { int32_t lat, lon; };
template<class T> using PsramAllocator = std::allocator<T>;
void portENTER_CRITICAL(int *) {}
void portEXIT_CRITICAL(int *) {}
class RouteOverlay {
public:
  std::vector<GeoPoint, PsramAllocator<GeoPoint>> points{{1, 2}, {3, 4}};
  mutable int routeMutex = 0;
  uint32_t revisionCounter = 0;
  bool parseRouteData(const uint8_t *, size_t);
  bool matchesRouteData(const uint8_t *, size_t) const;
};
''' + parser + r'''
void reject(const uint8_t *bytes, size_t length) {
  RouteOverlay route;
  assert(!route.parseRouteData(bytes, length));
  assert(route.points.size() == 2 && route.points[0].lat == 1);
  assert(route.revisionCounter == 0);
}
int main() {
  uint8_t bytes[16]{};
  int32_t first = INT32_MAX;
  std::memcpy(bytes, &first, sizeof(first));
  bytes[8] = 1;
  reject(bytes, 12); // Previously overflowed signed latitude accumulation.
  std::memset(bytes, 0, sizeof(bytes));
  for (size_t length : {1U, 7U, 9U, 11U, 13U}) reject(bytes, length);
  first = 89999999;
  std::memcpy(bytes, &first, sizeof(first));
  bytes[8] = 2;
  reject(bytes, 12); // Valid seed, invalid accumulated WGS-84 point.
  first = 1000000;
  std::memcpy(bytes, &first, sizeof(first));
  bytes[8] = 0xff; bytes[9] = 0xff; // Negative little-endian delta.
  RouteOverlay route;
  assert(route.parseRouteData(bytes, 12));
  assert(route.points.size() == 2 && route.points[1].lat == 999999);
  assert(route.matchesRouteData(bytes, 12));
  const uint32_t acceptedRevision = route.revisionCounter;
  bytes[10] = 1;
  assert(!route.matchesRouteData(bytes, 12));
  bytes[10] = 0;
  assert(!route.matchesRouteData(bytes, 13));
  assert(!route.matchesRouteData(nullptr, 12));
  assert(route.revisionCounter == acceptedRevision);
  assert(route.parseRouteData(nullptr, 0));
  assert(!route.matchesRouteData(bytes, 12));
  assert(route.points.empty());
}
''')

    def test_legacy_gps_rejects_out_of_range_coordinates_at_ingress(self):
        self.run_cpp(r'''
#include "ble_navigation/gps_input_freshness.hpp"
#include <cassert>
#include <cstdint>
#include <cstring>
#include <initializer_list>
int main() {
  uint8_t bytes[30]{};
  for (size_t length : {8U, 10U, 14U, 16U, 18U, 22U, 26U, 30U}) {
    for (int32_t latitude : {90000001, -90000001, INT32_MAX, INT32_MIN}) {
      std::memcpy(bytes, &latitude, sizeof(latitude));
      assert(!gps_input_freshness::acceptsPayload(bytes, length));
    }
    std::memset(bytes, 0, sizeof(bytes));
    for (int32_t longitude : {180000001, -180000001, INT32_MAX, INT32_MIN}) {
      std::memcpy(bytes + 4, &longitude, sizeof(longitude));
      assert(!gps_input_freshness::acceptsPayload(bytes, length));
    }
    std::memset(bytes, 0, sizeof(bytes));
    assert(gps_input_freshness::acceptsPayload(bytes, length));
  }
}
''')


if __name__ == "__main__":
    unittest.main()
