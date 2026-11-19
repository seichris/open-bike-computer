"""Compile the firmware's deferred ride-acknowledgement resend on the host and
cross a session or lease boundary while an old acknowledgement is pending.

The two marked blocks of ble_navigation.cpp (authenticated notification
admission and the deferred ride acknowledgement) are extracted verbatim and
linked against stubs. The ownership-lock stub can replace the session or lease
at the instant the lock is granted, which is the race a check outside the lock
cannot see: the stale acknowledgement must be retired, never queued into the
new session.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = next(p for p in Path(__file__).resolve().parents
            if (p / "esp32/lib").is_dir()) / "esp32"
SOURCE = ROOT / "lib/ble_navigation/ble_navigation.cpp"


def marked(text, name):
    begin = f"// BEGIN {name}"
    end = f"// END {name}"
    first = text.index(begin)
    return text[first:text.index(end, first) + len(end)]


FIXTURE = r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "ble_navigation/ride_command_admission.hpp"
#include "ble_navigation/ride_delivery_protocol.hpp"

// --- Stubs for the firmware environment ---------------------------------
struct NimBLECharacteristic {};
namespace device_ownership {
enum class AuthenticatedChannel { Navigation };
}
using TickType_t = int;
constexpr int pdTRUE = 1;
constexpr int pdMS_TO_TICKS(int ms) { return ms; }
constexpr uint16_t BLE_HS_CONN_HANDLE_NONE = 0xFFFF;
struct portMUX_TYPE { int unused = 0; };
#define portMUX_INITIALIZER_UNLOCKED {}
#define portENTER_CRITICAL(mux) (void)(mux)
#define portEXIT_CRITICAL(mux) (void)(mux)

static bool bleSessionAuthenticated = true;
static bool deviceOwnershipReady = true;
static int ownershipLockToken = 1, transportLockToken = 1;
static void *deviceOwnershipMutex = &ownershipLockToken;
static void *notificationTransportMutex = &transportLockToken;
static uint16_t activeConnHandle = 1;
static std::atomic<uint32_t> ridePayloadGeneration{5};
static uint32_t currentLease = 3;
static bool lockAvailable = true;
static int lockAttempts = 0;
// Runs while the lock is being granted: another task replacing the session
// or lease after the caller's last look, before the admission check.
static std::function<void()> whileTakingLock;

static int xSemaphoreTake(void *, int) {
  ++lockAttempts;
  if (whileTakingLock) {
    auto replace = whileTakingLock;
    whileTakingLock = nullptr;
    replace();
  }
  return lockAvailable ? pdTRUE : 0;
}
static void xSemaphoreGive(void *) {}
static bool isNimbleCallbackContext() { return false; }
static uint32_t millis() { return 1000; }

struct OwnershipStub {
  uint32_t authenticatedRideLeaseGeneration(uint32_t) { return currentLease; }
  bool isSessionAuthenticated() { return bleSessionAuthenticated; }
  bool protectAuthenticatedPayload(device_ownership::AuthenticatedChannel,
                                   const std::string &payload,
                                   std::string &frame) {
    frame = payload;
    return true;
  }
} deviceOwnership;

struct QueuedNotification {
  std::string frame;
  uint32_t session;
  uint32_t lease;
};
static std::vector<QueuedNotification> queued;
static bool enqueueDeferredNotification(NimBLECharacteristic *, uint16_t,
                                        const uint8_t *data, size_t length) {
  queued.push_back({std::string(reinterpret_cast<const char *>(data), length),
                    ridePayloadGeneration.load(), currentLease});
  return true;
}

namespace ride_diagnostics {
enum class Level { Info, Warning };
static std::vector<std::string> records;
static bool record(Level, const char *, const char *event, const char *fields) {
  records.push_back(std::string(event) + " " + fields);
  return true;
}
}  // namespace ride_diagnostics

struct SerialStub { void println(const char *) {} } Serial;
namespace ui_scheduler {
enum class WakeReason { Ble };
static void notify(WakeReason) {}
}  // namespace ui_scheduler
static NimBLECharacteristic statusCharacteristic;
static NimBLECharacteristic *mapTransferStatusCharacteristic = &statusCharacteristic;

// --- Extracted firmware --------------------------------------------------
@ADMISSION@

static bool notifyAuthenticatedNavigation(NimBLECharacteristic *characteristic,
                                          const uint8_t *data, size_t length) {
  return notifyAuthenticatedPayloadResult(
             characteristic, device_ownership::AuthenticatedChannel::Navigation,
             data, length, {}) == AuthenticatedNotifyResult::Queued;
}

@DEFERRED@

// --- Scenarios ------------------------------------------------------------
static ride_delivery_protocol::Acknowledgement acknowledgement(uint32_t lease) {
  ride_delivery_protocol::Acknowledgement value{};
  value.type = ride_delivery_protocol::CommandType::WorkoutState;
  value.result = ride_delivery_protocol::Result::Success;
  value.commandId.fill(0x5A);
  value.stateGeneration = 9;
  value.leaseGeneration = lease;
  return value;
}

static void reset(uint32_t session, uint32_t lease) {
  ridePayloadGeneration = session;
  currentLease = lease;
  bleSessionAuthenticated = true;
  lockAvailable = true;
  lockAttempts = 0;
  whileTakingLock = nullptr;
  queued.clear();
  ride_diagnostics::records.clear();
  pendingRideAcknowledgement = {};
}

// The first notification fails (lock busy inside the NimBLE callback), so
// the acknowledgement waits for the loop task.
static void pendOldAcknowledgement(uint32_t lease) {
  lockAvailable = false;
  notifyRideDeliveryAcknowledgement(acknowledgement(lease));
  lockAvailable = true;
  assert(queued.empty());
  assert(pendingRideAcknowledgement.pending);
}

static bool lastRecordIs(const char *phase) {
  return !ride_diagnostics::records.empty() &&
         ride_diagnostics::records.back().find(
             std::string("\"phase\":\"") + phase + "\"") != std::string::npos;
}

int main() {
  // A new link and lease replace the old ones between the loop's last look
  // and the lock that admits the notification.
  reset(5, 3);
  pendOldAcknowledgement(3);
  whileTakingLock = [] { ridePayloadGeneration = 6; currentLease = 4; };
  resendPendingRideAcknowledgement();
  assert(queued.empty() && "a stale acknowledgement never enters the new session");
  assert(!pendingRideAcknowledgement.pending && "the fenced acknowledgement is retired");
  assert(lastRecordIs("fenced"));
  const int attemptsAfterFence = lockAttempts;
  resendPendingRideAcknowledgement();
  assert(lockAttempts == attemptsAfterFence && queued.empty());
  // The new session's own notifications still pass.
  const uint8_t fresh[] = {1, 2, 3};
  assert(notifyAuthenticatedNavigation(mapTransferStatusCharacteristic, fresh, 3));
  assert(queued.size() == 1 && queued[0].session == 6 && queued[0].lease == 4);

  // The lease alone is replaced on the same link.
  reset(7, 3);
  pendOldAcknowledgement(3);
  whileTakingLock = [] { currentLease = 5; };
  resendPendingRideAcknowledgement();
  assert(queued.empty() && !pendingRideAcknowledgement.pending);
  assert(lastRecordIs("fenced"));

  // Nothing changed: the original acknowledgement is resent once.
  reset(8, 2);
  pendOldAcknowledgement(2);
  resendPendingRideAcknowledgement();
  assert(queued.size() == 1 && queued[0].session == 8 && queued[0].lease == 2);
  uint8_t expected[ride_delivery_protocol::ACK_SIZE]{};
  assert(ride_delivery_protocol::encodeAcknowledgement(
             acknowledgement(2), expected, sizeof(expected)) ==
         ride_delivery_protocol::ACK_SIZE);
  assert(queued[0].frame ==
         std::string(reinterpret_cast<const char *>(expected), sizeof(expected)));
  assert(!pendingRideAcknowledgement.pending && lastRecordIs("resent"));

  // A busy lock is retried a bounded number of times, then dropped.
  reset(9, 6);
  pendOldAcknowledgement(6);
  lockAvailable = false;
  resendPendingRideAcknowledgement();
  resendPendingRideAcknowledgement();
  assert(pendingRideAcknowledgement.pending);
  resendPendingRideAcknowledgement();
  assert(!pendingRideAcknowledgement.pending && lastRecordIs("dropped"));
  assert(queued.empty());

  // An unauthenticated session is never sent to, and the session that
  // follows it cannot receive the old acknowledgement either.
  reset(10, 7);
  pendOldAcknowledgement(7);
  bleSessionAuthenticated = false;
  resendPendingRideAcknowledgement();
  assert(queued.empty() && pendingRideAcknowledgement.pending);
  bleSessionAuthenticated = true;
  ridePayloadGeneration = 11;
  resendPendingRideAcknowledgement();
  assert(queued.empty() && !pendingRideAcknowledgement.pending);
  assert(lastRecordIs("fenced"));
  return 0;
}
'''


class RideAcknowledgementFenceTests(unittest.TestCase):
    def test_stale_acknowledgement_never_enters_a_new_session(self):
        text = SOURCE.read_text()
        fixture = (FIXTURE
                   .replace("@ADMISSION@",
                            marked(text, "authenticated notification admission"))
                   .replace("@DEFERRED@",
                            marked(text, "deferred ride acknowledgement")))
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler, "a host C++ compiler is required")
        with tempfile.TemporaryDirectory(prefix="ride-ack-fence-") as directory:
            unit = Path(directory) / "fence.cpp"
            binary = Path(directory) / "fence"
            unit.write_text(fixture)
            subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-Wno-unused-function", "-fsanitize=address,undefined",
                            "-fno-sanitize-recover=all", "-I", str(ROOT / "lib"),
                            str(unit), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True,
                                    text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
