// Production writer, startup and admission against a deterministic RTOS model.
// No filesystem model is used here: SD latency is injected into the write step.
#include "ride_diagnostics.hpp"
#include "ride_diagnostics_queue_policy.hpp"
#include <atomic>
#include <cassert>
#include <cstdio>
#include <deque>
#include <vector>
using namespace ride_diagnostics;
using queue_policy::DropReason;
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
TaskHandle_t writerTaskHandle=nullptr;
std::atomic<bool> storageTransitionRequested{false}, sealRequested{false},
 storageTransitionIdle{false}, checkpointRequested{false}, lastStorageAvailable{true},
 recorderResourcesReady{true}, recorderWriterReady{false};
std::atomic<unsigned> nextSequence{0}, enqueued{0}, dropped{0}, storageErrors{0},
 faultCapsuleGeneration{0}, faultCapsuleQueuedGeneration{0},
 maximumWriterDelayMs{0}, maximumWriteDurationMs{0};
std::atomic<uint16_t> normalQueueCriticalCount{0}, maxQueueDepth{0};
constexpr unsigned kDropReasonCount=static_cast<unsigned>(DropReason::Count);
std::atomic<unsigned> dropsByReason[kDropReasonCount]{};
unsigned clockMs=0, notifications=0, waits=0, injected=0, faults=0, created=0;
unsigned createPriority=0, createCore=0, lockDepth=0;
bool createSucceeds=false, pauseTest=false;
std::vector<unsigned> persisted;
struct Stop {};
struct StorageMock {
 bool getDiagnosticsSdLoaded() { return true; }
 bool canRetryDiagnosticsSd() { return false; }
 void ensureDiagnosticsSdMounted() { assert(false); }
 int sync(FILE*) { return 0; }
 void markDiagnosticsSdUnavailable() { assert(false); }
} instance;
StorageMock *storage=&instance;
FILE *activeFile=nullptr;
unsigned lastCheckpointMs=0;
bool (*storageRecoveryAllowedProbe)()=nullptr;
enum class ActiveFileCloseResult { Ready };
ActiveFileCloseResult closeAndAdvanceActiveChunk() { return ActiveFileCloseResult::Ready; }
void abandonActiveChunkAfterUncertainWrite() { assert(false); }
struct SerialMock { void println(const char*) {} } Serial;
void updateFaultCapsule(Level,const char*,const char*,bool) { ++faults; }
bool flushFaultCapsulesIfPossible() { return false; }
bool completeSealIfReady() { return false; }
unsigned millis() { return clockMs; }
int xSemaphoreTake(int*,int timeout) { assert(timeout==1 && lockDepth==0); ++lockDepth; return pdTRUE; }
void xSemaphoreGive(int*) { assert(lockDepth==1); --lockDepth; }
unsigned uxQueueMessagesWaiting(QueueHandle_t q) { return q->events.size(); }
unsigned uxQueueSpacesAvailable(QueueHandle_t q) { return q->capacity-q->events.size(); }
unsigned queuedDepth() { return normal.events.size()+critical.events.size(); }
int xQueueSend(QueueHandle_t q,const QueuedEvent *e,int timeout) {
 assert(timeout==0 && lockDepth==1);
 if(q->events.size()==q->capacity) return pdFALSE;
 q->events.push_back(*e); return pdTRUE;
}
int xQueuePeek(QueueHandle_t q,QueuedEvent *e,int timeout) {
 assert(timeout==0 && lockDepth==1);
 if(q->events.empty()) return pdFALSE;
 *e=q->events.front(); return pdTRUE;
}
int xQueueReceive(QueueHandle_t q,QueuedEvent *e,int timeout) {
 if(xQueuePeek(q,e,timeout)==pdFALSE) return pdFALSE;
 q->events.pop_front(); return pdTRUE;
}
void xTaskNotifyGive(TaskHandle_t handle) {
 assert(handle==writerTaskHandle && lockDepth==0); ++notifications;
}
bool enqueue(QueuedEvent&);
unsigned ulTaskNotifyTake(int clear,unsigned timeout) {
 assert(clear==pdTRUE && timeout==50 && lockDepth==0);
 ++waits;
 if(notifications) { notifications=0; return 1; }
 if(pauseTest) return 0;
 if(injected==100) throw Stop{};
 // Eight records arrive while the writer is blocked. Admission must wake it
 // immediately, even with a perpetually runnable priority-1 UI task.
 ++clockMs; ++injected;
 for(unsigned i=0;i<8;++i) {
   QueuedEvent e{nextSequence++,clockMs,i%4==0};
   assert(enqueue(e));
 }
 assert(notifications==8);
 notifications=0;
 return 8;
}
void vTaskDelay(unsigned ticks) {
 if(pauseTest) { assert(ticks==10 && storageTransitionIdle); throw Stop{}; }
 // The writer must use notifications, never the old 50-ms polling delay.
 assert(false);
}
bool writeQueuedEvent(const QueuedEvent &e) {
 assert(lockDepth==0 && !pauseTest);
 assert(e.sequence==persisted.size());
 persisted.push_back(e.sequence);
 clockMs+=3; // controlled SD/retention latency, not a physical performance claim
 return true;
}
int xTaskCreatePinnedToCore(void(*)(void*),const char*,unsigned,void*,unsigned priority,
 TaskHandle_t *handle,unsigned core) {
 ++created; createPriority=priority; createCore=core;
 if(!createSucceeds) return pdFALSE;
 *handle=&task; return pdPASS;
}
// PRODUCTION_FUNCTIONS
int main() {
 storageTransitionRequested=true;
 startWriterTask(); assert(created==0);
 storageTransitionRequested=false;
 startWriterTask();
 assert(created==1 && !recorderWriterReady && writerTaskHandle==nullptr && faults==1);
 createSucceeds=true;
 startWriterTask();
 assert(created==2 && recorderWriterReady && writerTaskHandle==&task);
 // Idle-priority writer cannot run while the priority-1 UI stays runnable.
 assert(createPriority==1 && createCore==1);
 startWriterTask(); assert(created==2);
 try { writerTask(nullptr); } catch(const Stop&) {}
 assert(injected==100 && persisted.size()==800 && enqueued==800 && dropped==0);
 assert(queuedDepth()==0 && maxQueueDepth==8 && maximumWriterDelayMs==21);
 assert(maximumWriteDurationMs==3 && waits>=100);
 // Unsigned elapsed time must survive the monotonic clock wrapping.
 maximumWriterDelayMs=maximumWriteDurationMs=0;
 clockMs=1;
 normal.events.push_back({800,0xfffffffcU,false});
 injected=100;
 try { writerTask(nullptr); } catch(const Stop&) {}
 assert(persisted.size()==801 && maximumWriterDelayMs==5 && maximumWriteDurationMs==3);
 // No queued record may be consumed while a storage transition owns the medium.
 normal.events.push_back({801,clockMs,false});
 pauseTest=true; storageTransitionRequested=true;
 try { writerTask(nullptr); } catch(const Stop&) {}
 assert(queuedDepth()==1 && persisted.size()==801 && storageTransitionIdle);
 puts("Writer drains 100 reconnect bursts, wakes on admission, preserves order and transition fences");
}
