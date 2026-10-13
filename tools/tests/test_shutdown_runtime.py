"""Execute the actual shutdown orchestration/unmount functions with host IO stubs."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ShutdownRuntimeTests(unittest.TestCase):
    def run_cpp(self, code):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "test.cpp"
            binary = Path(directory) / "test"
            source.write_text(code)
            built = subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                                    "-I", str(ROOT), str(source), "-o", str(binary)],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            subprocess.run([str(binary)], check=True)

    def test_actual_power_request_drain_defer_and_success(self):
        source = (ROOT / "esp32/lib/power/power.cpp").read_text()
        functions = source[source.index("void Power::deviceShutdown()") :]
        header = (ROOT / "esp32/lib/power/power.hpp").read_text()
        declaration = header[header.index("class Power {") :]
        self.run_cpp(r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#include "esp32/lib/power/shutdown_barrier_policy.hpp"
uint32_t now=0; int sleeps=0, seals=0, drains=0, stops=0, notices=0;
bool drainReady=false, renderReady=false, sealReady=false, storageReady=false, accepted=false;
uint64_t progress=0;
uint32_t millis() { return now; }
struct SerialMock { template<class... T> void printf(const char*,T...){} } Serial;
struct ESPMock { void restart() { assert(false); } } ESP;
namespace sleep_audit { void recorderSealed(bool ready) { assert(ready); } }
namespace ride_diagnostics {
bool pollShutdownQuiescence() { ++seals; return sealReady; }
void noteShutdownDeferred(uint8_t) {}
}
''' + declaration + functions + r'''
void Power::powerOffPeripherals() { assert(shutdownBarrier_.permit()); ++stops; }
void Power::powerDeepSleep() { assert(shutdownBarrier_.permit()); ++sleeps; }
void configure(Power &p) {
  p.setShutdownDeferredCallback([](uint8_t stage) { assert(stage>=1 && stage<=4); ++notices; });
  p.configureShutdown([] { return true; },[] { ++drains; return drainReady; },
      [] { return renderReady; },[] { return accepted; },[] { return storageReady; },
      []()->uint64_t { return progress; });
}
int main() {
  Power p; configure(p); p.deviceShutdown(); assert(sleeps==0);
  assert(!p.processShutdown()); now=5001;
  assert(!p.processShutdown()); // Deferred Drain MUST keep UI completions alive.
  assert(notices==1);
  for(int poll=0;poll<100;++poll) assert(!p.processShutdown());
  assert(notices==1); // Callback is one-shot even while completion service continues.
  const int before=drains; drainReady=renderReady=sealReady=storageReady=true;
  assert(!p.processShutdown()); assert(drains>before && sleeps==0);
  Power good; configure(good); now=0; good.deviceShutdown();
  for(int stage=0;stage<4;++stage) { ++now; good.processShutdown(); }
  assert(sleeps==1 && stops==1 && seals==1 && notices==1);
  for(int failed=2;failed<=4;++failed) {
    Power blocked; configure(blocked); now=0;
    const int noticeBefore=notices;
    drainReady=true; renderReady=failed!=2; sealReady=failed!=3; storageReady=false;
    blocked.deviceShutdown();
    for(int poll=0;poll<4;++poll) { ++now; blocked.processShutdown(); }
    now=6000; assert(blocked.processShutdown());
    assert(notices==noticeBefore+1);
    const int count=notices;
    for(int poll=0;poll<100;++poll) assert(blocked.processShutdown());
    assert(notices==count && sleeps==1);
  }
  Power progressing; configure(progressing); accepted=true; drainReady=false;
  now=0; progressing.deviceShutdown(); progressing.processShutdown();
  for(now=20000;now<600000;now+=20000) { ++progress; assert(!progressing.processShutdown()); }
  ++progress; assert(!progressing.processShutdown()); assert(sleeps==1);
}
''')

    def test_preallocated_deferred_notice_is_one_shot_and_storage_free(self):
        source = (ROOT / "esp32/src/main.cpp").read_text()
        start = source.index("static void showShutdownDeferredNotice(")
        function = source[start:source.index("static const char *remoteDebugStartErrorCode(", start)]
        for forbidden in ("lv_obj_create", "lv_label_create", "lv_timer_handler", "storage.",
                          "startRenderWorker", "power.deviceShutdown", "power.deviceRestart"):
            self.assertNotIn(forbidden, function)
        self.run_cpp(r'''
#include <cassert>
#include <cstdint>
#define USE_ARDUINO_GFX 1
#define WAVESHARE_AMOLED_175 1
#define LV_OBJ_FLAG_HIDDEN 1
struct lv_obj_t {}; struct lv_timer_t {}; struct lv_display_t {};
lv_obj_t notice, oldScene, top, bottom;
lv_timer_t timer; lv_display_t lcd;
static lv_obj_t *shutdownDeferredNotice=nullptr;
static bool shutdownDeferredNoticeShown=false;
lv_timer_t *mainTimer=&timer; lv_display_t *display=&lcd;
int hidden=0, shown=0, refreshed=0, paused=0, dimmed=0, applied=0;
void lv_timer_pause(lv_timer_t*) { ++paused; }
lv_obj_t *lv_screen_active() { return &oldScene; }
lv_obj_t *lv_layer_top() { return &top; }
lv_obj_t *lv_layer_bottom() { return &bottom; }
void lv_obj_add_flag(lv_obj_t*,int) { ++hidden; }
void lv_obj_clear_flag(lv_obj_t*,int) { ++shown; }
namespace display_power { enum class State { Dimmed }; }
namespace display_inactivity { enum class Mode { Active, Dimmed }; }
display_inactivity::Mode currentDisplayMode=display_inactivity::Mode::Active;
struct Display {
  void requestState(display_power::State) { ++dimmed; }
  void applyPendingPanelChange() { ++applied; }
} displayPowerManager;
void lv_refr_now(lv_display_t*) {
  assert(hidden==3 && shown==1 && applied==1 && paused==1); ++refreshed;
}
''' + function + r'''
int main() {
  showShutdownDeferredNotice(3); // No UI in maintenance: never initialize it here.
  assert(!shutdownDeferredNoticeShown && refreshed==0 && dimmed==0);
  shutdownDeferredNotice=&notice;
  showShutdownDeferredNotice(3);
  for(int repeat=0;repeat<100;++repeat) showShutdownDeferredNotice(4);
  assert(shutdownDeferredNoticeShown && refreshed==1 && dimmed==1 && applied==1);
  assert(currentDisplayMode==display_inactivity::Mode::Dimmed);
}
''')

    def test_actual_backend_unmount_ack_and_fail_closed_paths(self):
        source = (ROOT / "esp32/lib/storage/storage.cpp").read_text()
        functions = source[source.index("bool Storage::pollShutdownQuiescence()"):
                           source.index("bool Storage::ensureSdMounted(")]
        self.run_cpp(r'''
#include <atomic>
#include <cassert>
#include <cstddef>
#include <initializer_list>
#include <cstdint>
#include "esp32/lib/storage/storage_stream_admission.hpp"
#define WAVESHARE_AMOLED_175 1
#define pdTRUE 1
#define pdPASS 1
#define pdMS_TO_TICKS(x) (x)
#define tskIDLE_PRIORITY 0
bool createOK=true, lockOK=true, flushOK=true, unmountOK=true, mounted=true;
int calls=0, backendEnded=-1;
void (*task)(void*)=nullptr; void *taskArg=nullptr;
int xTaskCreate(void (*fn)(void*),const char*,int,void *arg,int,void*) {
  if (!createOK) return 0;
  task=fn; taskArg=arg; return pdPASS;
}
int xSemaphoreTake(void*,int) { return lockOK?pdTRUE:0; }
void xSemaphoreGive(void*) {}
void vTaskDelete(void*) {}
int fakeFlush(void*) { ++calls; return flushOK?0:-1; }
#define fflush fakeFlush
bool mountedDirectoryAvailable(const char*) { return mounted; }
enum class StorageBackend { Unavailable, NativeSdmmc, LegacySpiMigration, RemovableSpi, InternalFFat };
void endRemovableStorage(StorageBackend backend) {
  backendEnded=static_cast<int>(backend); if(unmountOK) mounted=false;
}
struct Fat { void end() { backendEnded=4; if(unmountOK) mounted=false; } } FFat;
struct Storage {
  storage_shutdown::StreamAdmission streamAdmission_;
  std::atomic<bool> shutdownAdmissionClosed_{false}, shutdownStarted_{false}, shutdownComplete_{false};
  void *mountMutex=reinterpret_cast<void*>(1);
  std::atomic<StorageBackend> mountedBackend{StorageBackend::NativeSdmmc};
  std::atomic<bool> isSdLoaded{true}, internalFallbackMounted{false};
  bool pollShutdownQuiescence(); static void shutdownTask(void*);
};
''' + functions + r'''
int main() {
  for (auto backend : {StorageBackend::NativeSdmmc,StorageBackend::LegacySpiMigration,
                       StorageBackend::RemovableSpi,StorageBackend::InternalFFat}) {
    for(int fail=0;fail<4;++fail) {
      createOK=true; lockOK=fail!=1; flushOK=fail!=2; unmountOK=fail!=3;
      mounted=true; backendEnded=-1; calls=0; task=nullptr;
      Storage storage; storage.mountedBackend=backend;
      assert(!storage.pollShutdownQuiescence());
      assert(storage.shutdownAdmissionClosed_ && calls==0 && task);
      task(taskArg);
      assert(storage.pollShutdownQuiescence()==(fail==0));
      if(fail==0) assert(!storage.isSdLoaded && !mounted);
      else assert(!storage.shutdownComplete_);
    }
  }
  createOK=false; Storage failure;
  assert(!failure.pollShutdownQuiescence()); createOK=true;
  assert(!failure.pollShutdownQuiescence()); // Failed create cannot reopen admission.
  Storage noCard; noCard.mountedBackend=StorageBackend::Unavailable;
  lockOK=flushOK=true; calls=0;
  assert(!noCard.pollShutdownQuiescence()); task(taskArg);
  assert(noCard.pollShutdownQuiescence()); // OTA does not require an SD mount.
}
''')

    def test_actual_stream_wrappers_fence_delayed_open_and_close(self):
        source = (ROOT / "esp32/lib/storage/storage.cpp").read_text()
        def body(marker):
            start = source.index(marker)
            return source[start:source.index("\n}\n", start) + 3]
        functions = "\n".join(body(marker) for marker in (
            "FILE *Storage::open(", "int Storage::close(", "bool Storage::remove(",
            "bool Storage::pollShutdownQuiescence()"))
        self.run_cpp(r'''
#include <atomic>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <functional>
#include "esp32/lib/storage/storage_stream_admission.hpp"
#define pdPASS 1
#define tskIDLE_PRIORITY 0
int tasks=0, opens=0, closes=0; bool failOpen=false, failClose=false;
std::function<void()> beforeReserve, duringOpen, duringClose, duringMetadata;
void (*task)(void*)=nullptr; void *taskArg=nullptr;
int xTaskCreate(void (*fn)(void*),const char*,int,void *arg,int,void*) {
  ++tasks; task=fn; taskArg=arg; return pdPASS;
}
namespace power_management {
enum class LockDomain { Storage };
struct ScopedLock { explicit ScopedLock(LockDomain) { if(beforeReserve) beforeReserve(); } };
}
FILE *fakeOpen(const char*,const char*) {
  ++opens; if(duringOpen) duringOpen();
  return failOpen?nullptr:reinterpret_cast<FILE*>(uintptr_t{0x10});
}
int fakeClose(FILE*) { ++closes; if(duringClose) duringClose(); return failClose?EOF:0; }
int fakeRemove(const char*) { if(duringMetadata) duringMetadata(); return 0; }
#define fopen fakeOpen
#define fclose fakeClose
#define remove fakeRemove
struct Storage {
  storage_shutdown::StreamAdmission streamAdmission_;
  std::atomic<bool> shutdownAdmissionClosed_{false}, shutdownStarted_{false}, shutdownComplete_{false};
  FILE *open(const char*,const char*); int close(FILE*); bool remove(const char*);
  bool pollShutdownQuiescence();
  static void shutdownTask(void *arg) {
    auto &storage=*static_cast<Storage*>(arg);
    assert(storage.streamAdmission_.quiescent()); storage.shutdownComplete_=true;
  }
};
''' + functions + r'''
int main() {
  // Shutdown wins precisely between the old flag read and fopen admission.
  Storage flagGap;
  beforeReserve=[&] { assert(!flagGap.pollShutdownQuiescence()); };
  assert(flagGap.open("gpx","w")==nullptr && opens==0);
  beforeReserve=nullptr; task(taskArg); assert(flagGap.pollShutdownQuiescence());

  // An already admitted, delayed fopen owns a lease before it returns FILE*.
  Storage opening; const int oldTasks=tasks;
  duringOpen=[&] { assert(!opening.pollShutdownQuiescence()); assert(tasks==oldTasks); };
  FILE *file=opening.open("calibration","w"); assert(file);
  duringOpen=nullptr; assert(!opening.pollShutdownQuiescence());
  // Final flush/close is still a writer even though the application requested close.
  duringClose=[&] { assert(!opening.pollShutdownQuiescence()); assert(tasks==oldTasks); };
  assert(opening.close(file)==0); duringClose=nullptr;
  assert(!opening.pollShutdownQuiescence()); assert(tasks==oldTasks+1);
  task(taskArg); assert(opening.pollShutdownQuiescence());
  assert(opening.open("late","w")==nullptr);

  // Failed fopen retires its reservation; no-card OTA stays able to shut down.
  Storage failedOpen; failOpen=true; assert(!failedOpen.open("missing","r")); failOpen=false;
  assert(!failedOpen.pollShutdownQuiescence()); task(taskArg);
  assert(failedOpen.pollShutdownQuiescence());

  // A failing fclose releases FILE ownership but permanently denies unmount.
  Storage failedClose; file=failedClose.open("upgrade","r"); assert(file);
  failClose=true; assert(failedClose.close(file)==EOF); failClose=false;
  const int before=tasks;
  for(int retry=0;retry<100;++retry) assert(!failedClose.pollShutdownQuiescence());
  assert(tasks==before);
  assert(failedClose.close(file)==EOF); // Unknown/double close never reaches libc.
  assert(closes==2);

  // Metadata IO has no FILE lifetime, so its scoped operation owns a lease.
  Storage metadata; const int beforeMetadata=tasks;
  duringMetadata=[&] { assert(!metadata.pollShutdownQuiescence()); assert(tasks==beforeMetadata); };
  assert(metadata.remove("old-waypoint")); duringMetadata=nullptr;
  assert(!metadata.pollShutdownQuiescence()); task(taskArg);
  assert(metadata.pollShutdownQuiescence()); assert(!metadata.remove("late"));

  storage_shutdown::StreamAdmission bounded;
  for(size_t i=0;i<storage_shutdown::StreamAdmission::kCapacity;++i) {
    const size_t slot=bounded.reserveOpen();
    assert(slot!=storage_shutdown::StreamAdmission::kInvalid);
    bounded.finishOpen(slot,reinterpret_cast<FILE*>(uintptr_t{0x100}+i));
  }
  assert(bounded.reserveOpen()==storage_shutdown::StreamAdmission::kInvalid);
  bounded.closeAdmission(); assert(!bounded.quiescent());
  for(size_t i=0;i<storage_shutdown::StreamAdmission::kCapacity;++i) {
    const auto slot=bounded.beginClose(reinterpret_cast<FILE*>(uintptr_t{0x100}+i));
    assert(slot!=storage_shutdown::StreamAdmission::kInvalid);
    bounded.finishClose(slot,true);
  }
  assert(bounded.quiescent());
}
''')

    def test_late_recorder_ack_is_not_replaced_by_a_new_cutoff(self):
        source = (ROOT / "esp32/lib/ride_diagnostics/ride_diagnostics.cpp").read_text()
        function = source[source.index("bool pollShutdownQuiescence()"):
                          source.index("void armTransferSnapshotLease(")]
        self.run_cpp(r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#define PERSISTENT_RIDE_DIAGNOSTICS 1
#define tskIDLE_PRIORITY 0
#define pdPASS 1
void *writerTaskHandle=reinterpret_cast<void*>(1), *activeFile=nullptr;
std::atomic<bool> shutdownSealStarted{false}, shutdownSealReady{false}, storageTransitionRequested{false};
int requests=0, tasks=0;
void (*task)(void*)=nullptr;
bool prepareForShutdown(uint32_t budget) { assert(budget==4000); ++requests; return true; }
void vTaskDelete(void*) {}
int xTaskCreate(void (*fn)(void*),const char*,int,void*,int,void*) { ++tasks; task=fn; return pdPASS; }
''' + function + r'''
int main() {
  assert(!pollShutdownQuiescence());
  for(int delay=0;delay<100;++delay) assert(!pollShutdownQuiescence());
  assert(tasks==1 && requests==0);
  task(nullptr); // Writer completed between UI polls, no wall-clock sleeps.
  for(int late=0;late<100;++late) assert(pollShutdownQuiescence());
  assert(tasks==1 && requests==1);
}
''')

    def test_waveshare_has_no_legacy_manual_suspend_registration(self):
        import configparser
        config = configparser.ConfigParser(interpolation=None)
        config.read(ROOT / "esp32/platformio.ini")
        profiles = [name for name in config.sections() if name.startswith("env:WAVESHARE_AMOLED_")]
        self.assertTrue(profiles)
        for profile in profiles:
            self.assertNotIn("-DPOWER_SAVE", config.get(profile, "build_flags", fallback=""))
        source = (ROOT / "esp32/lib/lvgl/src/lvglSetup.cpp").read_text()
        setup = source[source.index("void initLVGL()") :]
        self.assertLess(setup.index("#ifdef USE_ARDUINO_GFX"), setup.index("#else"))
        self.assertLess(setup.index("#else"), setup.index("gpioClickEvent, LV_EVENT_SHORT_CLICKED"))

    def test_inactive_recorder_needs_no_sd_but_active_failure_denies_sleep(self):
        source = (ROOT / "esp32/lib/ride_diagnostics/ride_diagnostics.cpp").read_text()
        function = source[source.index("bool prepareForShutdown("):
                          source.index("void noteShutdownDeferred(")]
        self.run_cpp(r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#define PERSISTENT_RIDE_DIAGNOSTICS 1
void *writerTaskHandle=nullptr, *activeFile=nullptr;
std::atomic<bool> storageTransitionRequested{false}, checkpointRequested{false};
bool sealOK=false; int seals=0;
enum class Level { Warning, Error };
bool recordHealth(const char*) { return true; }
bool record(Level,const char*,const char*,const char*) { return true; }
bool sealActiveChunk(uint32_t) { ++seals; return sealOK; }
void updateFaultCapsule(Level,const char*,const char*,bool) {}
''' + function + r'''
int main() {
  assert(prepareForShutdown(20)); assert(seals==0 && storageTransitionRequested);
  writerTaskHandle=reinterpret_cast<void*>(1);
  assert(!prepareForShutdown(20)); assert(seals==1);
  sealOK=true; assert(prepareForShutdown(20));
  writerTaskHandle=nullptr; activeFile=reinterpret_cast<void*>(1); sealOK=false;
  assert(!prepareForShutdown(20)); // Missing task cannot excuse an open writer.
}
''')

if __name__ == "__main__":
    unittest.main()
