#include "ride_diagnostics_transfer_policy.hpp"
#include "device_transfer_network_owner.hpp"
#include <atomic>
#include <cassert>
#include <cstdio>
#include <string>
using Storage = ride_diagnostics::transfer_policy::StoragePreparation;
using Seal = ride_diagnostics::transfer_policy::SealPreparation;
using TaskHandle_t = void *;
enum eTaskState { eRunning, eSuspended };
constexpr int pdTRUE = 1, portMAX_DELAY = 0;
static int mutex, task;
static void *diagnosticsSessionMutex = &mutex;
static TaskHandle_t diagnosticsSessionStartTaskHandle = &task;
static std::atomic<bool> diagnosticsSessionPreparationComplete{true};
static std::atomic<bool> diagnosticsSessionStartInProgress{true};
static std::atomic<bool> bleSessionSupportsRideDiagnostics{true};
static std::atomic<bool> shutdownWritesClosed{false};
static std::atomic<unsigned> shutdownWritesInFlight{0};
static std::atomic<unsigned> diagnosticsSessionStartGeneration{7};
static std::atomic<unsigned> diagnosticsSessionActiveGeneration{7};
static Storage diagnosticsStorageResult = Storage::ReadyRemovable;
static Seal diagnosticsSealResult = Seal::Ready;
static eTaskState taskState = eRunning;
static unsigned deletes = 0, enables = 0, released = 0;
static unsigned internalFree = 58 * 1024;
eTaskState eTaskGetState(TaskHandle_t handle) { assert(handle == &task); return taskState; }
void vTaskDelete(TaskHandle_t handle) {
  assert(handle == &task && taskState == eSuspended);
  ++deletes; internalFree += 6144;
}
int xSemaphoreTake(void *, int) { return pdTRUE; }
void xSemaphoreGive(void *) {}
struct { bool connected = true; bool isConnected() { return connected; } } bleNavServer;
struct { template<class... T> void printf(const char *, T...) {} void println(const char *) {} } Serial;
namespace device_transfer { struct HttpTransferStatus { bool enabled = false; std::string lastErrorCode; }; }
struct {
  device_transfer::HttpTransferStatus state;
  auto status() { return state; }
  bool setEnabled(bool enabled, const char *) {
    assert(enabled && deletes > 0);
    ++enables;
    const bool admitted = device_transfer::wifiStartupMemoryAboveObservedFailure(
        {internalFree, internalFree, internalFree, internalFree});
    state.enabled = admitted;
    state.lastErrorCode = admitted ? "" : "wifi_memory";
    return admitted;
  }
  void setLastError(const char *code, const char *) { state.lastErrorCode = code; }
} deviceTransferHttp;
namespace ride_diagnostics {
enum class Level { Info, Warning };
bool record(Level, const char *, const char *, const char *) { return true; }
void endTransferSnapshotLease() { ++released; }
}
void cancelDiagnosticsSessionStart() { ++diagnosticsSessionStartGeneration; }
// PRODUCTION_FUNCTION
// PRODUCTION_SHUTDOWN
void reset() {
  deletes = enables = released = 0; internalFree = 58 * 1024;
  taskState = eSuspended; diagnosticsSessionStartTaskHandle = &task;
  diagnosticsSessionPreparationComplete = true; diagnosticsSessionStartInProgress = true;
  diagnosticsSessionStartGeneration = diagnosticsSessionActiveGeneration = 7;
  bleNavServer.connected = true; bleSessionSupportsRideDiagnostics = true;
  diagnosticsStorageResult = Storage::ReadyRemovable; diagnosticsSealResult = Seal::Ready;
  deviceTransferHttp.state = {};
  shutdownWritesClosed = false; shutdownWritesInFlight = 0;
}
int main() {
  processCompletedDiagnosticsSessionStart();
  assert(deletes == 0 && enables == 0 && diagnosticsSessionStartInProgress);
  taskState = eSuspended;
  processCompletedDiagnosticsSessionStart();
  assert(deletes == 1 && enables == 1 && deviceTransferHttp.state.enabled);
  assert(!diagnosticsSessionStartInProgress && released == 0);
  processCompletedDiagnosticsSessionStart(); assert(deletes == 1 && enables == 1);
  reset(); diagnosticsSessionStartGeneration = 8; // Cancelled while sealing.
  processCompletedDiagnosticsSessionStart(); assert(deletes == 1 && enables == 0 && released == 1);
  reset(); bleNavServer.connected = false;
  processCompletedDiagnosticsSessionStart(); assert(enables == 0 && released == 1);
  reset(); diagnosticsSealResult = Seal::FlushFailed;
  processCompletedDiagnosticsSessionStart();
  assert(enables == 0 && released == 1 && deviceTransferHttp.state.lastErrorCode == "diagnostics_flush_failed");
  reset(); internalFree = 32 * 1024; // Reclamation does not waive the actual guard.
  processCompletedDiagnosticsSessionStart();
  assert(enables == 1 && !deviceTransferHttp.state.enabled && released == 1);
  assert(deviceTransferHttp.state.lastErrorCode == "wifi_memory");
  reset(); taskState = eRunning;
  assert(!pollShutdownQuiescence()); // Storage work must finish before shutdown.
  assert(deletes == 0 && enables == 0 && diagnosticsSessionStartGeneration == 8);
  taskState = eSuspended;
  assert(pollShutdownQuiescence());
  assert(deletes == 1 && enables == 0 && released == 1);
}
