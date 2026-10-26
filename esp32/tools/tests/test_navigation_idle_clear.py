"""Execute the firmware's real maneuver retention against a navigation clear."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BLE_SOURCE = (ROOT / "lib" / "ble_navigation" / "ble_navigation.cpp").read_text(
    encoding="utf-8")


def function(source: str, signature: str) -> str:
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
    raise AssertionError(f"unterminated function: {signature}")


class NavigationIdleClearTests(unittest.TestCase):
    def test_canonical_idle_maneuver_ends_the_navigation_session(self):
        # A navigation clear is an empty route plus "1|0|Navigation idle"
        # (docs/ble-protocol.md). The route member applies later on the UI task
        # while the maneuver member applies on the host task, so the clear must
        # hold in either order. Stored as live guidance, the idle maneuver made
        # course-up Map + Navigation defer every frame while stationary.
        constants = "\n".join(re.findall(
            r"^static constexpr char kNavigationIdlePacket\[\] = \"[^\"]*\";$",
            BLE_SOURCE, re.M))
        fixture = r'''
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#define FIRMWARE_DIAGNOSTICS 0
static uint32_t millis() { return 0; }
struct SerialStub {
  void println(const char *) {}
  template <typename... Arguments> void printf(const char *, Arguments...) {}
} Serial;
namespace ui_scheduler {
enum class WakeReason { Ble };
static void notify(WakeReason) {}
}
namespace ride_diagnostics {
enum class Level { Info, Warning };
static bool record(Level, const char *, const char *, const char *) { return true; }
}
struct NavigationData {
  uint8_t iconID;
  uint16_t distance;
  char instruction[64];
};
namespace runtime_ownership {
struct CriticalSection {};
template <typename T, typename Lock> class Snapshot {
public:
  T read() const { return value_; }
  void publish(const T &next) { value_ = next; }
private:
  T value_{};
};
}
static runtime_ownership::Snapshot<NavigationData,
                                   runtime_ownership::CriticalSection> currentNavData;
''' + constants + "\n" + "\n".join((
            function(BLE_SOURCE, "static void clearCurrentNavigationData()"),
            function(BLE_SOURCE, "bool hasCurrentNavigationData()"),
            function(BLE_SOURCE, "static void parseNavigationData(const std::string &data)"),
        )) + r'''
int main() {
  parseNavigationData("3|120|Turn left onto Main Street");
  assert(hasCurrentNavigationData());
  // Route member first, then the idle maneuver.
  clearCurrentNavigationData();
  parseNavigationData("1|0|Navigation idle");
  assert(!hasCurrentNavigationData());
  // The idle maneuver first, then the deferred route member.
  parseNavigationData("3|120|Turn left onto Main Street");
  parseNavigationData("1|0|Navigation idle");
  clearCurrentNavigationData();
  assert(!hasCurrentNavigationData());
  // The idle maneuver alone also ends a live maneuver.
  parseNavigationData("3|120|Turn left onto Main Street");
  parseNavigationData("1|0|Navigation idle");
  assert(!hasCurrentNavigationData());
  // Only the exact canonical packet clears: a real 0 m maneuver stays live.
  parseNavigationData("5|0|Arrived at destination");
  assert(hasCurrentNavigationData());
  parseNavigationData("1|0|Navigation idle ahead");
  assert(hasCurrentNavigationData());
}
'''
        with tempfile.TemporaryDirectory(prefix="navigation-idle-clear-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture, encoding="utf-8")
            subprocess.run([shutil.which("c++"), "-std=c++17", str(path / "test.cpp"),
                            "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
