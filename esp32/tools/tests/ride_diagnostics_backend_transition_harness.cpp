
#include "ride_diagnostics.hpp"
#include "ride_diagnostics_queue_policy.hpp"
#include <deque>
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <unistd.h>
namespace fs=std::filesystem;
using namespace ride_diagnostics;
using queue_policy::DropReason;
struct StorageMock {
 std::string root;
 unsigned generation=0;
 unsigned mountGeneration() const { return generation; }
 bool loaded=true;
 bool getDiagnosticsSdLoaded() const { return loaded; }
 bool mkdir(const char *path) { return fs::create_directories(path); }
 uint64_t size(const char *path) { return fs::exists(path)?fs::file_size(path):0; }
 int openDescriptor(const char *path,int flags) { return ::open(path,flags,0644); }
} object;
StorageMock *storage=&object;
const char *diagnosticsRoot() { return storage->root.c_str(); }
std::atomic<unsigned> bootSequence{1},activeChunkSnapshot{2};
std::atomic<bool> persistentBootSequenceReady{false};
unsigned runtimeBootSequence=1, activeChunk=2, activeFileBytes=0;
int activeDescriptor=-1;
constexpr unsigned kMaximumRetainedFiles=256;
char activePath[192]{};
int activeHash{}; bool activeHashValid=false;
void mbedtls_sha256_free(int*) {}
void mbedtls_sha256_init(int*) {}
int mbedtls_sha256_starts(int*,int) { return 0; }

#define PERSISTENT_RIDE_DIAGNOSTICS 1
unsigned storageBootFloor=1, transitionMountGeneration=0;
std::atomic<bool> storageTransitionRequested{true}, storageTransitionIdle{true}, retentionPrunedThisBoot{false};
int *producerMutex=nullptr;
struct SemaphoreGuard { explicit SemaphoreGuard(int*) {} };
std::atomic<bool> sealRequested{false};
unsigned closeCalls=0;
int closeAndAdvanceActiveChunk() { ++closeCalls; return 0; }
unsigned pdMS_TO_TICKS(unsigned value) { return value; }
void writerPauseIteration();
void vTaskDelay(unsigned) {
 static bool inside=false;
 if (inside) return;
 inside=true; writerPauseIteration(); inside=false;
}
unsigned tick=0;
unsigned millis() { return tick++; }
int *writerTaskHandle=nullptr, *queueMutationMutex=nullptr;
struct QueuedEvent { bool clearsFaultCapsule; };
struct Queue { std::deque<QueuedEvent> events; } normal, critical;
using QueueHandle_t=Queue*;
QueueHandle_t normalQueue=&normal, criticalQueue=&critical;
constexpr int pdTRUE=1;
int xQueueReceive(QueueHandle_t queue, QueuedEvent *event, int) {
  if (queue->events.empty()) return 0;
  *event=queue->events.front(); queue->events.pop_front(); return pdTRUE;
}
std::atomic<unsigned> normalQueueCriticalCount{0};
unsigned losses=0, capsules=0, released=0, seals=0;
void noteDrop(queue_policy::DropReason) { ++losses; }
void updateFaultCapsule(Level,const char*,const char*,bool) { ++capsules; }
struct FaultCapsuleWriteReceipt {
 const QueuedEvent &event;
 ~FaultCapsuleWriteReceipt() { if (event.clearsFaultCapsule) ++released; }
};
bool ride_diagnostics::sealActiveChunk(uint32_t) { ++seals; return true; }

// PRODUCTION_FUNCTIONS


int main(int argc,char **argv) {
 assert(argc==2); fs::path base=argv[1];
 fs::create_directories(base/"ffat"); storage->root=(base/"ffat").string();
 assert(initializePersistentBootSequenceIfNeeded() && bootSequence==1);
 auto sd=base/"sd";
 auto old=sd/"BICINO/DIAGNOSTICS/v1/boots/1/events-000002.jsonl";
 fs::create_directories(old.parent_path());
 fs::create_directories(sd/"BICINO/DIAGNOSTICS/v1/boots/10");
 std::ofstream(old) << "old-evidence"; const auto oldBytes=fs::file_size(old);
 storageTransitionRequested=false;
 int writer=1; writerTaskHandle=&writer;
 assert(::beginStorageTransition(100));
 writerPauseIteration(); writerPauseIteration();
 assert(closeCalls==1 && storageTransitionIdle);
 storage->root=sd.string(); storage->generation=1;
 ::endStorageTransition();
 assert(bootSequence==11 && activeChunk==1 && !storageTransitionRequested);
 writerPauseIteration(); assert(closeCalls==1);
 assert(::isClosedChunk(10,1));
 assert(openActiveFile()); assert(activeFileBytes==0);
 assert(::write(activeDescriptor,"new-evidence",12)==12); ::close(activeDescriptor); activeDescriptor=-1;
 assert(fs::file_size(old)==oldBytes);
 assert(openActiveFile()); assert(activeChunk==2 && activeFileBytes==0);
 ::close(activeDescriptor); activeDescriptor=-1;
 // No old-medium JSONL may survive into the next namespace when storage
 // was already unavailable. Account each discarded queue entry explicitly.
 storage->loaded=false; normal.events.push_back({false}); critical.events.push_back({true});
 writerTaskHandle=nullptr;
 assert(::beginStorageTransition(100));
 assert(losses==2 && capsules==2 && released==1);
 assert(normal.events.empty() && critical.events.empty());
 storage->loaded=true; storage->generation=2; ::endStorageTransition();
 assert(bootSequence==12);
 printf("New backend allocated boot11; boot10 remains visible and old bytes unchanged\n");
}
