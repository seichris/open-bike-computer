// Production transfer seal against a recorder whose queue never drains.
// Fault capsules coalesce during ordinary recording; a seal cutoff must still
// admit them, because waiting for an idle queue can starve under load.
#include "ride_diagnostics_transfer_policy.hpp"
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#define PERSISTENT_RIDE_DIAGNOSTICS 1
#define pdMS_TO_TICKS(ms) (ms)
constexpr int pdTRUE=1, pdFALSE=0;
namespace transfer_policy = ride_diagnostics::transfer_policy;
int producer=0, complete=0, task=0;
int *producerMutex=&producer, *sealComplete=&complete, *writerTaskHandle=&task;
struct StorageMock { bool getDiagnosticsSdLoaded() const { return true; } } storageObject;
StorageMock *storage=&storageObject;
std::atomic<uint32_t> faultCapsuleGeneration{0}, faultCapsuleQueuedGeneration{0};
std::atomic<uint32_t> nextSequence{0}, sealSequenceCutoff{0};
std::atomic<bool> sealRequested{false};
std::atomic<transfer_policy::SealPreparation> sealPreparationResult{
    transfer_policy::SealPreparation::SealFailed};
uint32_t clockMs=0, notifications=0, ordinaryFlushes=0, cutoffFlushes=0;
uint32_t millis() { return clockMs; }
void vTaskDelay(uint32_t ticks) { clockMs+=ticks; }
bool initializePersistentBootSequenceIfNeeded() { return true; }
void xTaskNotifyGive(int *handle) { assert(handle==writerTaskHandle); ++notifications; }
// Continuous producer traffic: the queue never drains. Ordinary recording
// coalesces the cumulative snapshot; only a seal cutoff admits it.
bool flushFaultCapsulesIfPossible(bool beforeSealCutoff=false) {
  if(!beforeSealCutoff) { ++ordinaryFlushes; return false; }
  ++cutoffFlushes; ++nextSequence;
  faultCapsuleQueuedGeneration.store(faultCapsuleGeneration.load());
  return true;
}
int xSemaphoreTake(int *handle,uint32_t timeout) {
  if(handle==producerMutex) return pdTRUE;
  assert(handle==sealComplete);
  if(timeout==0) return pdFALSE; // no stale completion
  // The writer drains to the published cutoff (bounded) and closes the chunk.
  assert(sealRequested && sealSequenceCutoff==nextSequence);
  clockMs+=40;
  sealPreparationResult.store(transfer_policy::SealPreparation::Ready);
  sealRequested=false;
  return pdTRUE;
}
void xSemaphoreGive(int *) {}
// PRODUCTION_FUNCTIONS
int main() {
  // A capsule is pending while sustained traffic keeps the queue nonempty.
  faultCapsuleGeneration=7; faultCapsuleQueuedGeneration=6; nextSequence=1000;
  const auto result=sealActiveChunkForTransfer(5000);
  assert(result==transfer_policy::SealPreparation::Ready);
  assert(cutoffFlushes==1 && ordinaryFlushes==0 && notifications==1);
  assert(faultCapsuleQueuedGeneration==faultCapsuleGeneration);
  // The capsule precedes the published cutoff and the seal finished promptly.
  assert(sealSequenceCutoff==1001 && clockMs<100);
  puts("Transfer seal admits coalesced capsules before its cutoff under sustained load");
}
