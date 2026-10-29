// Production writer loop, deferral accounting, admission and recovery under a
// scripted internal DMA heap. The trough and ready values are the ones logged
// by the failed 40caf06a 1.75 boots (BLE crypto minimum and SYS at ready).
// Medium I/O is modeled by the mock: it fails the run if any record write,
// checkpoint or recovery probe starts below the background I/O floor.
#include "ride_diagnostics.hpp"
#include "ride_diagnostics_queue_policy.hpp"
#include "../ble_navigation/device_ownership_crypto_resource.hpp"
#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <string>
#include <vector>
using namespace ride_diagnostics;
using queue_policy::DropReason;

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,    \
                   #condition);                                                \
      std::exit(42);                                                           \
    }                                                                          \
  } while (0)

#define PERSISTENT_RIDE_DIAGNOSTICS 1
constexpr int configUSE_PREEMPTION=1, configUSE_TIME_SLICING=1;
constexpr int pdTRUE=1, pdFALSE=0, pdPASS=1;
#define pdMS_TO_TICKS(ms) (ms)
using BaseType_t=int;
using UBaseType_t=unsigned;
using TaskHandle_t=int*;
struct QueuedEvent { uint32_t sequence, enqueuedAtMs; bool critical; };
struct Queue { unsigned capacity; std::deque<QueuedEvent> events; };
using QueueHandle_t=Queue*;
Queue normal{kNormalQueueCapacity,{}}, critical{kCriticalQueueCapacity,{}};
QueueHandle_t normalQueue=&normal, criticalQueue=&critical;
int mutex=0, task=0;
int *queueMutationMutex=&mutex;
TaskHandle_t writerTaskHandle=&task;
std::atomic<bool> storageTransitionRequested{false}, sealRequested{false},
 storageTransitionIdle{false}, checkpointRequested{false}, lastStorageAvailable{true},
 recorderResourcesReady{true}, recorderWriterReady{true};
std::atomic<uint32_t> nextSequence{0}, enqueued{0}, dropped{0}, storageErrors{0},
 faultCapsuleGeneration{0}, faultCapsuleQueuedGeneration{0},
 maximumWriterDelayMs{0}, maximumWriteDurationMs{0};
std::atomic<uint32_t> memoryDeferrals{0}, maximumMemoryDeferralMs{0},
 memoryDeferralMinimumDmaFree{UINT32_MAX}, memoryDeferralMinimumDmaLargest{UINT32_MAX};
std::atomic<uint16_t> normalQueueCriticalCount{0}, maxQueueDepth{0};
constexpr unsigned kDropReasonCount=static_cast<unsigned>(DropReason::Count);
std::atomic<uint32_t> dropsByReason[kDropReasonCount]{};
int activeDescriptor=-1;
uint32_t lastCheckpointMs=0;

constexpr storage_policy::MemoryHeadroom kTrough{451, 40};
constexpr storage_policy::MemoryHeadroom kReady{25307, 24564};
// Background evidence never takes the headroom the authenticated-BLE crypto
// guard requires, plus the SDMMC bounce its own I/O allocates.
static_assert(storage_policy::kBackgroundIoMinimumDmaFreeBytes >=
              device_ownership::kMinimumCryptoDmaFreeBytes +
                  storage_policy::kSdmmcBounceBytes, "crypto free floor");
static_assert(storage_policy::kBackgroundIoMinimumDmaLargestBytes >=
              device_ownership::kMinimumCryptoDmaLargestBlockBytes,
              "crypto largest-block floor");
static_assert(!storage_policy::admitsBackgroundIo(kTrough) &&
              storage_policy::admitsBackgroundIo(kReady), "observed values");

storage_policy::MemoryHeadroom heap=kReady;
unsigned samples=0;
storage_policy::MemoryHeadroom backgroundIoHeadroom() { ++samples; return heap; }
bool admitted() { return storage_policy::admitsBackgroundIo(heap); }

uint32_t clockMs=0;
uint32_t millis() { return clockMs; }
unsigned lockDepth=0, notifications=0, waits=0, delays=0;
struct Stop {};
std::function<void()> tick;

struct StorageMock {
 bool healthy=true, mounted=true, probeResult=false, failNextWrite=false;
 std::vector<uint32_t> probes;
 unsigned syncs=0, unavailable=0;
 bool getDiagnosticsSdLoaded() const { return healthy; }
 bool canRetryDiagnosticsSd() const { return !healthy && mounted; }
 bool ensureDiagnosticsSdMounted() {
   CHECK(admitted()); // the probe creates, writes, syncs and unlinks a file
   probes.push_back(clockMs);
   healthy=probeResult;
   return healthy;
 }
 int syncDescriptor(int) { CHECK(admitted()); ++syncs; return 0; }
 void markDiagnosticsSdUnavailable() { healthy=false; ++unavailable; }
} instance;
StorageMock *storage=&instance;

std::vector<uint32_t> persisted;
unsigned discarded=0;
bool writeQueuedEvent(const QueuedEvent &event) {
 CHECK(lockDepth==0);
 if (!storage->healthy) { ++discarded; return false; } // loss is counted, no I/O
 CHECK(admitted()); // a record write may allocate SDMMC bounces
 if (storage->failNextWrite) {
   storage->failNextWrite=false;
   storage->markDiagnosticsSdUnavailable();
   ++discarded;
   return false;
 }
 persisted.push_back(event.sequence);
 clockMs+=2;
 return true;
}
bool completeSealIfReady() { return false; }
enum class ActiveFileCloseResult { Ready };
ActiveFileCloseResult closeAndAdvanceActiveChunk() { return ActiveFileCloseResult::Ready; }
void abandonActiveChunkAfterUncertainWrite() { activeDescriptor=-1; }
unsigned faults=0;
void updateFaultCapsule(Level,const char*,const char*,bool) { ++faults; }
bool flushFaultCapsulesIfPossible() { return false; }
unsigned allowedQueries=0;
bool transferIdle=true;
bool recoveryAllowed() { ++allowedQueries; return transferIdle; }
bool (*storageRecoveryAllowedProbe)()=recoveryAllowed;
struct SerialMock {
 std::vector<std::string> lines;
 void println(const char *line) { lines.emplace_back(line); }
} Serial;

int xSemaphoreTake(int*,int timeout) {
 CHECK(timeout==1 && lockDepth==0);
 ++lockDepth; return pdTRUE;
}
void xSemaphoreGive(int*) { CHECK(lockDepth==1); --lockDepth; }
unsigned uxQueueMessagesWaiting(QueueHandle_t q) { return q->events.size(); }
unsigned uxQueueSpacesAvailable(QueueHandle_t q) { return q->capacity-q->events.size(); }
unsigned queuedDepth() { return normal.events.size()+critical.events.size(); }
int xQueueSend(QueueHandle_t q,const QueuedEvent *e,int timeout) {
 CHECK(timeout==0 && lockDepth==1);
 if(q->events.size()==q->capacity) return pdFALSE;
 q->events.push_back(*e); return pdTRUE;
}
int xQueuePeek(QueueHandle_t q,QueuedEvent *e,int timeout) {
 CHECK(timeout==0 && lockDepth==1);
 if(q->events.empty()) return pdFALSE;
 *e=q->events.front(); return pdTRUE;
}
int xQueueReceive(QueueHandle_t q,QueuedEvent *e,int timeout) {
 if(xQueuePeek(q,e,timeout)==pdFALSE) return pdFALSE;
 q->events.pop_front(); return pdTRUE;
}
void xTaskNotifyGive(TaskHandle_t handle) {
 CHECK(handle==writerTaskHandle && lockDepth==0); ++notifications;
}
int xTaskCreatePinnedToCore(void(*)(void*),const char*,unsigned,void*,unsigned,
 TaskHandle_t*,unsigned) { return pdPASS; }
// The memory wait is the only bounded sleep beside a backlog.
void vTaskDelay(unsigned ticks) {
 CHECK(ticks==storage_policy::kBackgroundIoRetryMs);
 CHECK(queuedDepth()!=0 && storage->healthy && !admitted() && lockDepth==0);
 ++delays; clockMs+=ticks;
 if (tick) tick();
}
unsigned ulTaskNotifyTake(int clear,unsigned timeout) {
 CHECK(clear==pdTRUE && timeout==50 && lockDepth==0);
 // Housekeeping never sleeps beside records the writer may drain or discard.
 CHECK(queuedDepth()==0);
 ++waits;
 const unsigned woke=notifications;
 notifications=0;
 clockMs+=woke ? 1 : timeout;
 if (tick) tick();
 return woke;
}
bool enqueue(QueuedEvent&);

// PRODUCTION_FUNCTIONS

uint32_t produced=0;
void produce(bool criticalRecord=false) {
 QueuedEvent event{nextSequence++,clockMs,criticalRecord};
 ++produced;
 (void)enqueue(event);
}
void run() {
 try { writerTask(nullptr); } catch(const Stop&) {}
 CHECK(lockDepth==0);
}
void reset() {
 normal.events.clear(); critical.events.clear();
 instance=StorageMock{};
 persisted.clear(); discarded=0; produced=0; nextSequence=0;
 heap=kReady; samples=waits=delays=notifications=faults=allowedQueries=0;
 clockMs=0; lastCheckpointMs=0; activeDescriptor=-1; checkpointRequested=false;
 memoryDeferrals=0; maximumMemoryDeferralMs=0;
 memoryDeferralMinimumDmaFree=UINT32_MAX; memoryDeferralMinimumDmaLargest=UINT32_MAX;
 for (auto &count : dropsByReason) count=0;
 dropped=0; enqueued=0; normalQueueCriticalCount=0; transferIdle=true;
 Serial.lines.clear(); tick=nullptr;
}
bool inOrder() {
 for (std::size_t i=1;i<persisted.size();++i)
   if (persisted[i]<=persisted[i-1]) return false;
 return true;
}

// A status/auth burst arrives while BLE crypto holds the DMA heap at its
// recorded trough. Nothing touches the medium; every record survives.
void cryptoTroughDefersWithoutLoss() {
 reset();
 clockMs=25680;
 for (int i=0;i<6;++i) produce(i%3==0);
 heap=kTrough;
 const uint32_t troughEnd=clockMs+300;
 tick=[troughEnd]() {
   if (clockMs<troughEnd) { produce(); return; }
   heap=kReady;
   if (queuedDepth()==0) throw Stop{};
 };
 run();
 CHECK(persisted.size()==produced && dropped==0 && inOrder());
 CHECK(delays>=14 && delays<=16 && instance.syncs==0 && instance.probes.empty());
 CHECK(memoryDeferrals==1 && memoryDeferralMinimumDmaFree==451 &&
       memoryDeferralMinimumDmaLargest==40);
 CHECK(maximumMemoryDeferralMs>=300 && maximumMemoryDeferralMs<=300+20);
 // One heap sample per deferred pass, not one per producer notification.
 CHECK(samples<=delays+produced+4);
 CHECK(Serial.lines.size()==1);
 CHECK(Serial.lines[0].find("RIDE_DIAGNOSTICS: memory_deferred durationMs=")==0);
 CHECK(Serial.lines[0].find("dmaFree=451 dmaLargest=40")!=std::string::npos);
}

// A trough longer than the bounded queue keeps the oldest records and counts
// every refused admission as queue_full; it never writes below the floor.
void longTroughCountsOverflow() {
 reset();
 heap=kTrough;
 produce();
 unsigned ticks=0;
 tick=[&ticks]() {
   if (++ticks<=40) { produce(); return; }
   heap=kReady;
   if (queuedDepth()==0) throw Stop{};
 };
 run();
 const uint32_t full=dropsByReason[static_cast<unsigned>(DropReason::QueueFull)];
 CHECK(full>0 && dropped==full);
 CHECK(persisted.size()+full==produced && persisted.size()==kNormalQueueCapacity);
 CHECK(inOrder() && persisted.front()==0);
 CHECK(memoryDeferrals==1);
}

// The checkpoint waits for headroom and keeps its request meanwhile.
void checkpointWaitsForHeadroom() {
 reset();
 activeDescriptor=3;
 clockMs=6000;
 checkpointRequested=true;
 heap=kTrough;
 unsigned ticks=0;
 tick=[&ticks]() {
   if (++ticks==3) heap=kReady;
   if (instance.syncs==1) throw Stop{};
 };
 run();
 CHECK(instance.syncs==1 && !checkpointRequested && lastCheckpointMs>=6100);
 CHECK(memoryDeferrals==1 && Serial.lines.size()==1);
}

// The 40caf06a sequence: a write fails under pressure. The old writer probed
// at once with stdio. Now the first probe waits a base interval, never starts
// below the floor, backs off while it keeps failing and resets on recovery.
void recoveryIsPacedAndAdmitted() {
 reset();
 clockMs=25860;
 produce();
 instance.failNextWrite=true;
 heap=kReady;
 uint32_t faultAt=0, troughUntil=0;
 bool gated=false, recovered=false;
 tick=[&]() {
   if (faultAt==0 && !instance.healthy) faultAt=clockMs;
   if (troughUntil!=0 && clockMs>=troughUntil) { heap=kReady; troughUntil=0; }
   // Third probe falls due inside a 1 s trough, the fourth during a transfer.
   if (instance.probes.size()==2 && !gated && faultAt!=0 &&
       clockMs>=instance.probes[1]+20000) {
     heap=kTrough; troughUntil=clockMs+1000; gated=true;
   }
   if (instance.probes.size()==3 && clockMs>=instance.probes[2]+40000 &&
       clockMs<instance.probes[2]+42000)
     transferIdle=false;
   else
     transferIdle=true;
   if (instance.probes.size()==6) instance.probeResult=true;
   if (instance.healthy && instance.probes.size()==7 && !recovered) {
     recovered=true;
     instance.markDiagnosticsSdUnavailable(); // a later, unrelated fault
   }
   if (instance.probes.size()==8) throw Stop{};
 };
 run();
 const auto &p=instance.probes;
 CHECK(faultAt!=0 && p.size()==8 && discarded==1);
 // First probe one base interval after the fault, polled at 50 ms.
 CHECK(p[0]>=faultAt+5000 && p[0]<=faultAt+5000+60);
 CHECK(p[1]-p[0]>=10000 && p[1]-p[0]<=10060);
 // Due at +20 s but deferred for the 1 s trough; the wait restarts there.
 CHECK(p[2]-p[1]>=21000 && p[2]-p[1]<=21060);
 // Due at +40 s while a transfer owns the medium; probed when it ended.
 CHECK(p[3]-p[2]>=42000 && p[3]-p[2]<=42060);
 CHECK(p[4]-p[3]>=60000 && p[4]-p[3]<=60060); // capped
 CHECK(p[5]-p[4]>=60000 && p[5]-p[4]<=60060);
 CHECK(p[6]-p[5]>=60000 && p[6]-p[5]<=60060); // this probe succeeds
 // A new fault starts again from the base interval.
 CHECK(p[7]-p[6]>=5000 && p[7]-p[6]<=5060);
 CHECK(memoryDeferrals==1 && memoryDeferralMinimumDmaFree==451);
 // The transfer gate is asked only when a probe is due, not every pass.
 CHECK(allowedQueries<=p.size()+20+40+4);
 CHECK(waits>allowedQueries*10);
}

// An unavailable recorder discards without I/O, so memory never blocks it.
void unavailableRecorderStillDrains() {
 reset();
 instance.healthy=false;
 instance.mounted=false;
 heap=kTrough;
 for (int i=0;i<5;++i) produce();
 tick=[]() { if (queuedDepth()==0) throw Stop{}; };
 run();
 CHECK(discarded==5 && delays==0 && memoryDeferrals==0 && samples==0);
}

int main() {
 cryptoTroughDefersWithoutLoss();
 longTroughCountsOverflow();
 checkpointWaitsForHeadroom();
 recoveryIsPacedAndAdmitted();
 unavailableRecorderStillDrains();
 std::puts("Writer defers medium I/O below the DMA floor without loss, paces and admits recovery");
}
