"""Run the production BLE status producer through bounded queue backpressure."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def function(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    while ";" in source[start:opening]:  # skip forward declarations
        start = source.index(signature, start + len(signature))
        opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("unterminated function: " + signature)


class DeviceTransferStatusRefreshTests(unittest.TestCase):
    def test_changed_policy_is_delivered_after_inflight_status(self):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler)
        source = (ROOT / "lib/ble_navigation/ble_navigation.cpp").read_text()
        fixture = r'''
#include <atomic>
#include <cassert>
#include <deque>
#include <string>
#include <vector>
#include "map_transfer_status_chunk_session.hpp"
#include "transfer_control_dispatch.hpp"
struct NimBLECharacteristic {} characteristic;
static NimBLECharacteristic *mapTransferStatusCharacteristic = &characteristic;
static map_transfer_status_protocol::ChunkTransmission pendingDeviceTransferStatusChunks;
static std::atomic<bool> pendingDeviceTransferStatusContinuation{false};
static bool pendingDeviceTransferStatusRefresh = false;
static std::atomic<uint16_t> activePeerMtu{185};
static constexpr uint16_t BLE_HS_CONN_HANDLE_NONE = 0xffff;
static uint16_t activeConnHandle = 1;
static bool bleSessionAuthenticated = true;
static ble_transfer::PendingRequest pendingTransferControl;
static std::string currentBody;
static std::deque<std::string> transport;
static std::vector<std::string> delivered;
static constexpr size_t capacity = 2;
static bool rejectNextChunk = false;
struct SerialStub { template<class... Args> void printf(const char *, Args...) {} } Serial;
namespace ui_scheduler {
enum class WakeReason { Ble };
void notify(WakeReason) {}
}
static std::string genericTransferStatusJson() { return currentBody; }
static uint8_t deferredNotificationAvailableCapacity() { return capacity - transport.size(); }
static bool notifyAuthenticatedNavigation(NimBLECharacteristic *, const uint8_t *data, size_t size) {
  if (!bleSessionAuthenticated || activeConnHandle == BLE_HS_CONN_HANDLE_NONE ||
      transport.size() == capacity || size + 22 > activePeerMtu.load() - 3U) return false;
  const std::string frame(reinterpret_cast<const char *>(data), size);
  if (frame.substr(0, 4) == "DSTC" && rejectNextChunk) {
    rejectNextChunk = false;
    return false;
  }
  transport.push_back(frame);
  return true;
}
static void pumpPendingDeviceTransferStatusChunks();
static void queueTransferControl(ble_transfer::Action, uint8_t);
'''
        for signature in (
            "static void notifyGenericTransferStatus(NimBLECharacteristic *pChar) {",
            "static void pumpPendingDeviceTransferStatusChunks() {",
            "static void resetPendingDeviceTransferStatusChunks() {",
            "static void queueTransferControl(ble_transfer::Action action,",
        ):
            fixture += function(source, signature) + "\n"
        fixture += r'''
static void drain() {
  std::string body;
  uint8_t id = 0, next = 0;
  for (unsigned tick = 0; tick < 100; ++tick) {
    while (!transport.empty()) {
      const std::string frame = transport.front(); transport.pop_front();
      if (frame.substr(0, 4) == "DSTS") { delivered.push_back(frame.substr(4)); continue; }
      assert(frame.substr(0, 4) == "DSTC");
      if (next == 0) id = static_cast<uint8_t>(frame[4]);
      assert(static_cast<uint8_t>(frame[4]) == id);
      assert(static_cast<uint8_t>(frame[5]) == next);
      body += frame.substr(7);
      if (++next == static_cast<uint8_t>(frame[6])) {
        delivered.push_back(body); body.clear(); next = 0;
      }
    }
    const auto request = pendingTransferControl.take();
    if (request.notifications & ble_transfer::NotifyGeneric) notifyGenericTransferStatus(nullptr);
    pumpPendingDeviceTransferStatusChunks();
    if (transport.empty() && !pendingDeviceTransferStatusContinuation.load()) {
      const auto last = pendingTransferControl.take();
      if (last.empty()) { assert(body.empty()); return; }
      pendingTransferControl.merge(last.action, last.notifications);
    }
  }
  assert(false && "status did not finish within bounded owner ticks");
}
static void clear() {
  resetPendingDeviceTransferStatusChunks();
  queueTransferControl(ble_transfer::Action::None, ble_transfer::NotifyNone);
  pendingTransferControl.take(); transport.clear(); delivered.clear();
  bleSessionAuthenticated = true; activeConnHandle = 1;
  mapTransferStatusCharacteristic = &characteristic; rejectNextChunk = false;
}
int main() {
  const std::string oldBody(700, 'o'), acknowledged(750, 'a'), newest(800, 'n');
  currentBody = oldBody; notifyGenericTransferStatus(nullptr);
  assert(pendingDeviceTransferStatusChunks.active());
  const auto progress = pendingDeviceTransferStatusChunks.nextIndex();
  currentBody = acknowledged;
  for (unsigned poll = 0; poll < 10; ++poll) notifyGenericTransferStatus(nullptr);
  assert(pendingDeviceTransferStatusChunks.nextIndex() == progress); // no restart
  currentBody = newest; notifyGenericTransferStatus(nullptr);
  drain();
  assert((delivered == std::vector<std::string>{oldBody, newest})); // latest state, no new request

  clear(); currentBody = oldBody; rejectNextChunk = true; notifyGenericTransferStatus(nullptr);
  assert(pendingDeviceTransferStatusChunks.nextIndex() == 0);
  currentBody = acknowledged; notifyGenericTransferStatus(nullptr); drain();
  assert((delivered == std::vector<std::string>{oldBody, acknowledged}));

  // Mode / authorization reset must discard the pending refresh and old body.
  clear(); currentBody = oldBody; notifyGenericTransferStatus(nullptr);
  currentBody = acknowledged; notifyGenericTransferStatus(nullptr);
  resetPendingDeviceTransferStatusChunks(); transport.clear(); drain();
  assert(delivered.empty());
  currentBody = "new mode"; notifyGenericTransferStatus(nullptr); drain();
  assert((delivered == std::vector<std::string>{"new mode"}));

  for (unsigned boundary = 0; boundary < 3; ++boundary) {
    clear(); currentBody = oldBody; notifyGenericTransferStatus(nullptr);
    currentBody = acknowledged; notifyGenericTransferStatus(nullptr); transport.clear();
    if (boundary == 0) bleSessionAuthenticated = false;
    else if (boundary == 1) activeConnHandle = BLE_HS_CONN_HANDLE_NONE;
    else mapTransferStatusCharacteristic = nullptr;
    pumpPendingDeviceTransferStatusChunks(); drain();
    assert(delivered.empty());
    assert(!pendingDeviceTransferStatusRefresh);
  }
}
'''
        with tempfile.TemporaryDirectory(prefix="device-status-refresh-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I" + str(ROOT / "lib/ble_navigation"),
                            str(path / "test.cpp"), "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
