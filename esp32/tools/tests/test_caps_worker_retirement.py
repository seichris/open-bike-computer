"""Execute production worker exits/reclamation with deterministic task barriers."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1] + "\n"
    raise AssertionError("unterminated method: " + signature)


class CapsWorkerRetirementTests(unittest.TestCase):
    def test_http_and_renderer_retire_from_owner_after_cleanup(self):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler)
        http = (ROOT / "lib/device_transfer/device_transfer_http.cpp").read_text()
        maps = (ROOT / "lib/maps/src/maps.cpp").read_text()
        fixture = r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#include <string>
using TaskHandle_t = void *;
using SemaphoreHandle_t = void *;
constexpr int pdTRUE = 1;
[[maybe_unused]] constexpr int portMAX_DELAY = -1;
constexpr unsigned pdMS_TO_TICKS(unsigned value) { return value; }
static TaskHandle_t owner = reinterpret_cast<void *>(1);
static TaskHandle_t httpWorker = reinterpret_cast<void *>(2);
static TaskHandle_t mapWorker = reinterpret_cast<void *>(3);
static TaskHandle_t current = owner;
static bool internalStack = true;
static bool mutexAvailable = true;
static unsigned deletes = 0, clockMs = 0;
struct Parked {};
TaskHandle_t xTaskGetCurrentTaskHandle() { return current; }
void vTaskSuspend(TaskHandle_t task) { assert(task == nullptr); throw Parked{}; }
void xTaskNotifyGive(TaskHandle_t) {}
unsigned millis() { return clockMs; }
void vTaskDelay(unsigned ticks) { clockMs += ticks; }
bool esp_ptr_internal(const void *) { return internalStack; }
int xSemaphoreTake(SemaphoreHandle_t, int wait) {
  assert(wait == 0); // shutdown/recovery polling remains nonblocking
  return mutexAvailable ? pdTRUE : 0;
}
void xSemaphoreGive(SemaphoreHandle_t) {}
#define ESP_LOGE(...) ((void)0)
std::atomic<bool> gMapRenderWorkerShutdown{false};
std::atomic<unsigned> gMapRenderLatestSequence{0};
class HttpTransferServer {
public:
  TaskHandle_t workerTask_ = httpWorker;
  bool workerStopped_ = false, cleanupComplete = false, locked = false;
  void lockState() { assert(!locked); locked = true; }
  void unlockState() { assert(locked); locked = false; }
  void runWorker() { cleanupComplete = true; }
  void observeResources(const char *) {}
  void signalStatusChanged() {}
  void process();
  bool waitUntilStopped(uint32_t);
  static void workerTaskThunk(void *);
};
class Maps {
public:
  TaskHandle_t renderWorkerTaskHandle = mapWorker;
  SemaphoreHandle_t renderStateMutex = reinterpret_cast<void *>(4);
  std::atomic<bool> renderWorkerExited{false}, renderWorkerShutdown{false};
  std::atomic<bool> renderWorkerRestartAfterExit{false};
  bool cleanupComplete = false;
  void renderWorkerLoop() { cleanupComplete = true; }
  bool reclaimRenderWorker();
  bool stopRenderWorker();
  static void renderWorkerTaskThunk(void *);
};
static HttpTransferServer *httpServer;
static Maps *mapServer;
void vTaskDeleteWithCaps(TaskHandle_t task) {
  // Self deletion creates the SDK's minimal-stack cleanup task. Never use it.
  assert(task != nullptr && task != current && internalStack);
  if (task == httpWorker) {
    assert(httpServer->cleanupComplete && httpServer->workerStopped_);
    assert(httpServer->workerTask_ == task); // not published free before reclamation
  } else {
    assert(task == mapWorker && mapServer->cleanupComplete);
    assert(mapServer->renderWorkerExited.load());
    assert(mapServer->renderWorkerTaskHandle == task);
  }
  ++deletes;
}
'''
        fixture += method(http, "void HttpTransferServer::process()")
        fixture += method(http, "bool HttpTransferServer::waitUntilStopped(uint32_t timeoutMs)")
        fixture += method(http, "void HttpTransferServer::workerTaskThunk(void *arg)")
        if "bool Maps::reclaimRenderWorker()" in maps:
            fixture += method(maps, "bool Maps::reclaimRenderWorker()")
        fixture += method(maps, "bool Maps::stopRenderWorker()")
        fixture += method(maps, "void Maps::renderWorkerTaskThunk(void *argument)")
        fixture += r'''
int main(int argc, char **argv) {
  assert(argc == 2);
  if (std::string(argv[1]) == "http") {
    HttpTransferServer server; httpServer = &server;
    server.process(); assert(deletes == 0 && server.workerTask_ == httpWorker);
    assert(!server.waitUntilStopped(4)); // no premature stopped result
    current = httpWorker;
    try { HttpTransferServer::workerTaskThunk(&server); assert(false); } catch (Parked &) {}
    assert(server.workerTask_ == httpWorker && deletes == 0);
    server.process(); assert(deletes == 0); // worker cannot reap itself
    current = owner; internalStack = false;
    server.process(); assert(deletes == 0 && server.workerTask_ == httpWorker);
    internalStack = true;
    assert(server.waitUntilStopped(4)); // owner poll reaps without a separate UI tick
    assert(deletes == 1 && server.workerTask_ == nullptr);
    server.process(); assert(deletes == 1); // idempotent
  } else {
    Maps maps; mapServer = &maps;
    assert(!maps.stopRenderWorker() && deletes == 0);
    assert(maps.renderWorkerRestartAfterExit.load()); // preserve timeout recovery
    current = mapWorker;
    try { Maps::renderWorkerTaskThunk(&maps); assert(false); } catch (Parked &) {}
    assert(maps.renderWorkerTaskHandle == mapWorker && deletes == 0);
    assert(!maps.stopRenderWorker() && deletes == 0); // cannot self-reap
    current = owner; internalStack = false;
    assert(!maps.stopRenderWorker() && deletes == 0);
    internalStack = true;
    mutexAvailable = false;
    assert(!maps.stopRenderWorker() && deletes == 0);
    assert(maps.renderWorkerTaskHandle == mapWorker);
    mutexAvailable = true;
    assert(maps.stopRenderWorker() && deletes == 1);
    assert(maps.renderWorkerTaskHandle == nullptr);
    assert(!maps.renderWorkerShutdown.load() && !maps.renderWorkerRestartAfterExit.load());
    assert(maps.stopRenderWorker() && deletes == 1);
  }
}
'''
        with tempfile.TemporaryDirectory(prefix="caps-worker-retirement-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            str(path / "test.cpp"), "-o", str(path / "test")], check=True)
            for worker in ("http", "map"):
                with self.subTest(worker=worker):
                    subprocess.run([str(path / "test"), worker], check=True)


if __name__ == "__main__":
    unittest.main()
