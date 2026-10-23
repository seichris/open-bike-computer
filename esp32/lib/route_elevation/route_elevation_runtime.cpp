#include "route_elevation_runtime.hpp"

#if ROUTE_ELEVATION_SCREEN_ENABLED

#include "../utils/src/runtime_mutex.hpp"

#include <esp_heap_caps.h>
#include <mutex>
#include <new>

namespace route_elevation_runtime {
namespace {

constexpr std::size_t ACK_QUEUE_CAPACITY = 4;

// About 5 KiB of staging/active/candidate profile state: allocate once in
// PSRAM, like the social rider state, rather than in internal BSS.
struct State {
  route_elevation_protocol::Session session;
  Snapshot published;
  std::array<std::array<uint8_t, route_elevation_protocol::ACK_BYTES>, ACK_QUEUE_CAPACITY> acknowledgements{};
  std::size_t acknowledgementCount = 0;
};

runtime_ownership::StaticMutex sessionMutex;
runtime_ownership::CriticalSection publishLock;
State *state = nullptr;
uint32_t publishedRevision = 0;

State *ensureState() {
  if (state == nullptr) {
    void *memory = heap_caps_malloc(sizeof(State), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (memory != nullptr) {
      state = new (memory) State();
    }
  }
  return state;
}

void publishLocked(State &current) {
  std::lock_guard<runtime_ownership::CriticalSection> guard(publishLock);
  ++publishedRevision;
  if (publishedRevision == 0) {
    publishedRevision = 1;
  }
  current.published.revision = publishedRevision;
  current.published.binding = current.session.binding();
  current.published.hasProfile = current.session.hasProfile();
  if (current.published.hasProfile) {
    current.published.profile = current.session.profile();
  }
  current.published.hasProgress = current.session.hasProgress();
  current.published.progress = current.session.progress();
}

} // namespace

bool ready() {
  std::lock_guard<runtime_ownership::StaticMutex> lock(sessionMutex);
  return ensureState() != nullptr;
}

bool ingest(const uint8_t *data, std::size_t length, uint32_t nowMs) {
  if (!route_elevation_protocol::hasFrameMagic(data, length)) {
    return false;
  }
  std::lock_guard<runtime_ownership::StaticMutex> lock(sessionMutex);
  State *current = ensureState();
  if (current == nullptr) {
    return true;
  }
  const auto outcome = current->session.handle(data, length, nowMs);
  if (outcome.hasAck) {
    std::lock_guard<runtime_ownership::CriticalSection> guard(publishLock);
    if (current->acknowledgementCount < ACK_QUEUE_CAPACITY) {
      current->acknowledgements[current->acknowledgementCount++] = outcome.ack;
    } else {
      // Keep the newest result; the phone retries any transfer whose
      // acknowledgement was dropped.
      for (std::size_t index = 1; index < ACK_QUEUE_CAPACITY; ++index) {
        current->acknowledgements[index - 1] = current->acknowledgements[index];
      }
      current->acknowledgements[ACK_QUEUE_CAPACITY - 1] = outcome.ack;
    }
  }
  if (outcome.changed) {
    publishLocked(*current);
  }
  return true;
}

bool takeAcknowledgement(std::array<uint8_t, route_elevation_protocol::ACK_BYTES> &out) {
  std::lock_guard<runtime_ownership::CriticalSection> guard(publishLock);
  if (state == nullptr || state->acknowledgementCount == 0) {
    return false;
  }
  out = state->acknowledgements[0];
  for (std::size_t index = 1; index < state->acknowledgementCount; ++index) {
    state->acknowledgements[index - 1] = state->acknowledgements[index];
  }
  --state->acknowledgementCount;
  return true;
}

bool snapshotIfChanged(uint32_t known, Snapshot &out) {
  std::lock_guard<runtime_ownership::CriticalSection> guard(publishLock);
  if (state == nullptr || publishedRevision == known) {
    return false;
  }
  out = state->published;
  return true;
}

uint32_t revision() {
  std::lock_guard<runtime_ownership::CriticalSection> guard(publishLock);
  return publishedRevision;
}

void reset() {
  std::lock_guard<runtime_ownership::StaticMutex> lock(sessionMutex);
  if (state == nullptr) {
    return;
  }
  state->session.reset();
  {
    std::lock_guard<runtime_ownership::CriticalSection> guard(publishLock);
    state->acknowledgementCount = 0;
  }
  publishLocked(*state);
}

} // namespace route_elevation_runtime

#endif // ROUTE_ELEVATION_SCREEN_ENABLED
