// Run the production enqueue path with deterministic RTOS failure injection.
#include "../../lib/ride_diagnostics/ride_diagnostics.hpp"
#include "../../lib/ride_diagnostics/ride_diagnostics_queue_policy.hpp"
#include <atomic>
#include <cassert>
#include <deque>

using namespace ride_diagnostics;
using queue_policy::DropReason;
struct QueuedEvent { uint32_t sequence; bool critical; };
struct Queue { unsigned capacity; std::deque<QueuedEvent> events; };
using QueueHandle_t = Queue *;
using BaseType_t = int;
using UBaseType_t = unsigned;
constexpr int pdTRUE = 1, pdFALSE = 0;
Queue normal{kNormalQueueCapacity, {}}, critical{kCriticalQueueCapacity, {}};
QueueHandle_t normalQueue = &normal, criticalQueue = &critical;
bool mutexAvailable = true;
int mutexStorage = 1;
int *queueMutationMutex = &mutexStorage;
std::atomic<uint32_t> enqueued{0}, dropped{0};
std::atomic<uint16_t> normalQueueCriticalCount{0}, maxQueueDepth{0};
constexpr std::size_t kDropReasonCount = static_cast<std::size_t>(DropReason::Count);
std::atomic<uint32_t> dropsByReason[kDropReasonCount]{};
int xSemaphoreTake(int *, int timeout) { assert(timeout == 0); return mutexAvailable ? pdTRUE : pdFALSE; }
void xSemaphoreGive(int *) {}
UBaseType_t uxQueueMessagesWaiting(QueueHandle_t q) { return q->events.size(); }
UBaseType_t uxQueueSpacesAvailable(QueueHandle_t q) { return q->capacity - q->events.size(); }
BaseType_t xQueueSend(QueueHandle_t q, const QueuedEvent *e, int) {
  if (q->events.size() == q->capacity) return pdFALSE;
  q->events.push_back(*e); return pdTRUE;
}
BaseType_t xQueueReceive(QueueHandle_t q, QueuedEvent *e, int) {
  if (q->events.empty()) return pdFALSE;
  *e = q->events.front(); q->events.pop_front(); return pdTRUE;
}
UBaseType_t queuedDepth() { return normal.events.size() + critical.events.size(); }
// PRODUCTION_FUNCTIONS

unsigned count(DropReason reason) { return dropsByReason[static_cast<unsigned>(reason)].load(); }
void reset() {
  normal.events.clear(); critical.events.clear();
  normalQueue = &normal; criticalQueue = &critical;
  queueMutationMutex = &mutexStorage; mutexAvailable = true;
  enqueued = dropped = maxQueueDepth = normalQueueCriticalCount = 0;
  for (auto &counter : dropsByReason) counter = 0;
}
int main() {
  QueuedEvent ordinary{1, false}, important{2, true};
  mutexAvailable = false;
  assert(!enqueue(ordinary) && queuedDepth() == 0);
  assert(dropped == 1 && count(DropReason::QueueBusy) == 1);
  reset(); normalQueue = nullptr;
  assert(!enqueue(ordinary) && count(DropReason::QueueUnavailable) == 1);
  reset();
  for (unsigned i=0; i<kNormalQueueCapacity; ++i) assert(enqueue(ordinary));
  assert(!enqueue(ordinary) && count(DropReason::QueueFull) == 1);
  reset();
  for (unsigned i=0; i<kCriticalQueueCapacity; ++i) assert(enqueue(important));
  assert(enqueue(important));
  assert(normalQueueCriticalCount == 1);
  assert(enqueue(ordinary));
  assert(normal.events.size() == 2 && normal.events.back().critical == false);
  assert(dropped == 0 && count(DropReason::CriticalSpill) == 0);
  assert(count(DropReason::QueueFull) == 0);
  reset();
  for (unsigned i=0; i<kNormalQueueCapacity; ++i) assert(enqueue(ordinary));
  for (unsigned i=0; i<kCriticalQueueCapacity; ++i) assert(enqueue(important));
  assert(enqueue(important));
  assert(count(DropReason::NormalEvicted) == 1 && normal.events.front().critical == false);
  // Mixed spill records must not suppress normal traffic or make the oldest
  // protected head record an eviction victim. Keep survivor sequence order.
  reset();
  for (unsigned i=0; i<kCriticalQueueCapacity; ++i) {
    QueuedEvent e{i+1, true}; assert(enqueue(e));
  }
  for (unsigned i=0; i<kNormalQueueCapacity; ++i) {
    QueuedEvent e{i+9, i % 3 != 1}; assert(enqueue(e));
  }
  QueuedEvent replacement{33, true}; assert(enqueue(replacement));
  assert(normal.events.front().sequence == 9 && normal.events.front().critical);
  assert(normal.events.back().sequence == 33 && normal.events.back().critical);
  assert(normal.events.size() == kNormalQueueCapacity);
  unsigned previous = 0;
  for (const auto &e : normal.events) {
    assert(e.sequence > previous && e.sequence != 10); previous = e.sequence;
  }
  assert(count(DropReason::NormalEvicted) == 1 && dropped == 1);
  assert(normalQueueCriticalCount == 17);
  reset();
  for (unsigned i=0; i<kQueueCapacity; ++i) assert(enqueue(important));
  assert(!enqueue(important) && count(DropReason::QueueFull) == 1);
  assert(count(DropReason::NormalEvicted) == 0);
}
