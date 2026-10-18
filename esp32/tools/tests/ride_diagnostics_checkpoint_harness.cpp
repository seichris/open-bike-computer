#include "ride_diagnostics.hpp"
#include "ride_diagnostics_queue_policy.hpp"
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
using namespace ride_diagnostics;
struct QueuedEvent {
 unsigned sequence=1, length=10;
 bool critical=false, rotateBeforeWrite=false, rotateAfterWrite=false, clearsFaultCapsule=false;
 unsigned faultCapsuleBoot=1, faultCapsuleEventCount=1, faultCapsuleChecksum=123;
 char line[128]{};
};
enum class ActiveFileCloseResult { Ready, FlushFailed, CloseFailed };
bool failSync=false, failClose=false, cleared=false;
unsigned nowMs=100, syncs=0, faults=0, persisted=0, pending=0;
struct StorageMock {
 bool getDiagnosticsSdLoaded() { return true; }
 void markDiagnosticsSdUnavailable() {}
 size_t write(FILE*,const uint8_t*,size_t length) { pending+=length; return length; }
 int sync(FILE*) { ++syncs; if(failSync) return -1; persisted=pending; return 0; }
} instance;
StorageMock *storage=&instance;
FILE *activeFile=nullptr;
unsigned activeFileBytes=0,activeFirstSequence=0,activeLastSequence=0,lastCheckpointMs=0;
bool activeHashValid=false;
int activeHash=0;
std::atomic<unsigned> written{0}, storageErrors{0},faultCapsuleGeneration{0},faultCapsuleQueuedGeneration{0},
 pendingFaultCapsuleQueuedChecksum{123}, currentFaultCapsuleQueuedChecksum{123};
std::atomic<bool> retentionPrunedThisBoot{false};
void abandonActiveChunkAfterUncertainWrite(){ activeFile=nullptr; }
void updateFaultCapsule(Level,const char*,const char*,bool){++faults;}
const char *closeFailureEvent(ActiveFileCloseResult) { return "close_failed"; }
ActiveFileCloseResult closeAndAdvanceActiveChunk() {
 activeFile=nullptr; return failClose ? ActiveFileCloseResult::CloseFailed : ActiveFileCloseResult::Ready;
}
bool prepareChunkWriteReserve() { return true; }
bool openActiveFile() { activeFile=reinterpret_cast<FILE*>(1); return true; }
int mbedtls_sha256_update(int*, const uint8_t*, size_t) { return 0; }
unsigned millis() { return nowMs; }
void pruneRetention() {}
void clearFaultCapsule(unsigned,unsigned) { assert(persisted==pending); cleared=true; }
bool flushFaultCapsulesIfPossible() { return true; }
// PRODUCTION_FUNCTIONS
void reset() {
 failSync=failClose=cleared=false; syncs=faults=persisted=pending=activeFileBytes=lastCheckpointMs=0;
 activeFile=nullptr; nowMs=100; pendingFaultCapsuleQueuedChecksum=123; currentFaultCapsuleQueuedChecksum=123;
}
int main() {
 QueuedEvent event; event.clearsFaultCapsule=true;
 reset(); assert(writeQueuedEvent(event) && cleared && syncs==1 && persisted==10);
 reset(); failSync=true; assert(!writeQueuedEvent(event) && !cleared && faults==1);
 assert(pendingFaultCapsuleQueuedChecksum==0 && currentFaultCapsuleQueuedChecksum==0);
 reset(); event.rotateAfterWrite=true; failClose=true;
 assert(!writeQueuedEvent(event) && !cleared);
 reset(); event.rotateAfterWrite=false; event.clearsFaultCapsule=false;
 assert(writeQueuedEvent(event) && syncs==0); // bounded cadence, no per-event sync
 nowMs=5100; assert(writeQueuedEvent(event) && syncs==1 && persisted==20);
 reset(); event.critical=true; assert(writeQueuedEvent(event) && syncs==1);
 puts("Capsules clear only after checked sync/close; failures preserve retry; normal events keep bounded cadence");
}
