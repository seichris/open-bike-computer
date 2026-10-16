
#include "ride_diagnostics.hpp"
#include "ride_diagnostics_format.hpp"
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>
using namespace ride_diagnostics;
using namespace ride_diagnostics::detail;
#define portENTER_CRITICAL(p) ((void)0)
#define portEXIT_CRITICAL(p) ((void)0)
constexpr int pdTRUE=1;
int mutexStorage=1; int *faultCapsuleFlushMutex=&mutexStorage;
int xSemaphoreTake(int*,int) { return pdTRUE; }
void xSemaphoreGive(int*) {}
struct StorageMock { bool getDiagnosticsSdLoaded() const { return true; } } storageObject;
StorageMock *storage=&storageObject;
FaultCapsuleState currentFaultCapsule{}, pendingFaultCapsule{}, retainedFaultCapsule{};
bool pendingFaultCapsuleValid=true;
std::atomic<bool> faultCapsulesInitialized{true};
std::atomic<unsigned> bootSequence{52}, dropped{0}, faultCapsuleGeneration{0}, faultCapsuleQueuedGeneration{UINT32_MAX}, pendingFaultCapsuleQueuedChecksum{0}, currentFaultCapsuleQueuedChecksum{0};
unsigned millis() { return 10000; }
std::vector<unsigned> admittedBoots;
bool accept = true;
bool recordInternal(Level,const char*,const char*,const char*,bool,unsigned boot,unsigned,unsigned) {
 if (accept) { admittedBoots.push_back(boot); }
 return accept;
}
struct QueuedEvent { bool clearsFaultCapsule; unsigned faultCapsuleChecksum; };
// PRODUCTION_FUNCTIONS

int main() {
 pendingFaultCapsule.bootSequence=51; pendingFaultCapsule.eventCount=3;
 sealFaultCapsule(pendingFaultCapsule); retainedFaultCapsule=pendingFaultCapsule;
 const auto oldChecksum=pendingFaultCapsule.checksum;
 faultCapsulesInitialized=false;
 updateFaultCapsule(Level::Info,"ble","maintenance_event",true);
 assert(faultCapsuleIdentityMatches(retainedFaultCapsule,51,oldChecksum));
 assert(currentFaultCapsule.eventCount==0);
 faultCapsulesInitialized=true;
 assert(flushFaultCapsulesIfPossible());
 assert(admittedBoots.size()==1 && admittedBoots[0]==51);
 {
   QueuedEvent failed{true, oldChecksum};
   FaultCapsuleWriteReceipt receipt{failed};
   updateFaultCapsule(Level::Error,"storage","write_failed",true);
 }
 assert(pendingFaultCapsuleQueuedChecksum==0);
 assert(faultCapsuleIdentityMatches(retainedFaultCapsule,51,oldChecksum));
 assert(flushFaultCapsulesIfPossible());
 assert(admittedBoots.size()==3 && admittedBoots[1]==51 && admittedBoots[2]==52);
 clearFaultCapsule(52,currentFaultCapsule.checksum);
 assert(pendingFaultCapsuleValid && validFaultCapsule(retainedFaultCapsule));
 clearFaultCapsule(51,oldChecksum);
 assert(!pendingFaultCapsuleValid && !validFaultCapsule(retainedFaultCapsule));
 updateFaultCapsule(Level::Error,"storage","write_failed",true);
 accept=false;
 assert(!flushFaultCapsulesIfPossible() && currentFaultCapsuleQueuedChecksum==0);
 accept=true;
 assert(flushFaultCapsulesIfPossible());
 printf("Old capsule retried after terminal write failure; RTC survives reversed acknowledgements\n");
}
