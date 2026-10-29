// Production class, internal-stack call method, stack check and owner switch
// case are inserted by the contract test. The fake owner switches to an
// internal stack only while it runs a queued command; fake flash rejects a
// PSRAM-backed caller stack.
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <new>
#include <string>
#include "../../lib/firmware_update/firmware_internal_owner_policy.hpp"
#include "../../lib/firmware_update/firmware_operation_receipt.hpp"
#include "../../lib/device_transfer/device_transfer_network_owner.hpp"

using TickType_t = unsigned;
using StackType_t = uint8_t;
using TaskHandle_t = void *;
using QueueHandle_t = void *;
using SemaphoreHandle_t = void *;
using esp_err_t = int;
using esp_ota_handle_t = unsigned;
using esp_ota_img_states_t = int;
struct esp_partition_t {};
struct esp_app_desc_t {};
struct StaticTask_t {};
struct StaticQueue_t {};
struct StaticSemaphore_t {};
constexpr int ESP_OK = 0, ESP_FAIL = -1, ESP_OTA_IMG_UNDEFINED = 0;
constexpr int ESP_ERR_NO_MEM = -3, ESP_ERR_INVALID_STATE = -4;
constexpr TickType_t portMAX_DELAY = 0xffffffffU;
#define pdMS_TO_TICKS(n) (n)
namespace firmware_update {
struct DeviceWiFiRuntime {
  device_transfer::StationState stationState() const { return device_transfer::StationState::Connecting; }
  uint32_t stationIPAddress() const { return 0; }
  uint32_t accessPointIPAddress() const { return 0; }
  uint8_t accessPointClientCount() const { return 0; }
  device_transfer::NetworkReadinessSnapshot readiness() const { return {}; }
};
}

bool internalStack = true, ownerRefuses = false;
unsigned dispatches = 0, priority = 2;
TickType_t lastWait = 0;
TaskHandle_t currentTask = reinterpret_cast<void *>(1);
struct UnsafeFlashStack {};
bool esp_ptr_internal(const void *) { return internalStack; }
TaskHandle_t xTaskGetCurrentTaskHandle() { return currentTask; }
void vTaskPrioritySet(TaskHandle_t, unsigned value) { priority = value; }

// PRODUCTION_HEADER
// PRODUCTION_METHODS

namespace firmware_update {
esp_err_t DeviceOperationOwner::execute(const Command &command, Result &result,
    const uint8_t *, const std::string *, const std::string *,
    TickType_t timeoutTicks, bool *issued) {
  if (issued) *issued = false;
  ++dispatches;
  lastWait = timeoutTicks;
  // Queueing from the owner would self-deadlock.
  assert(currentTask != workerTask_);
  if (ownerRefuses) return ESP_ERR_INVALID_STATE;
  if (issued) *issued = true;
  const bool callerInternal = internalStack;
  internalStack = true;
  switch (command.operation) {
  // PRODUCTION_CASE
  default: assert(false);
  }
  internalStack = callerInternal;
  return ESP_OK;
}
}

struct FlashRead {
  unsigned calls = 0;
  unsigned priority = 0;
};

void flashRead(void *context) {
  if (!internalStack) throw UnsafeFlashStack{};
  auto &read = *static_cast<FlashRead *>(context);
  ++read.calls;
  read.priority = priority;
}

void exhaustedRead(void *) { throw std::bad_alloc(); }

int main() {
  try {
    firmware_update::DeviceOperationOwner owner;
    owner.workerTask_ = reinterpret_cast<void *>(2);
    FlashRead read;

    // A PSRAM-stack handler queues the read at its own priority and waits
    // without a timeout, because the call writes into the caller's frame.
    internalStack = false;
    assert(owner.runOnInternalStack(flashRead, &read));
    assert(read.calls == 1 && read.priority == 1 && priority == 2);
    assert(dispatches == 1 && lastWait == portMAX_DELAY && !internalStack);

    // Allocation failure in the call is reported, not thrown across tasks.
    assert(!owner.runOnInternalStack(exhaustedRead, nullptr));
    assert(dispatches == 2 && priority == 2);

    // A refused owner never runs the call on the caller's PSRAM stack.
    ownerRefuses = true;
    assert(!owner.runOnInternalStack(flashRead, &read) && read.calls == 1);
    ownerRefuses = false;
    assert(!owner.runOnInternalStack(nullptr, &read) && dispatches == 3);

    // Internal-stack callers, including the owner itself, run directly.
    internalStack = true;
    assert(owner.runOnInternalStack(flashRead, &read) && read.calls == 2);
    currentTask = owner.workerTask_;
    assert(owner.runOnInternalStack(flashRead, &read) && read.calls == 3);
    assert(dispatches == 3);
  } catch (const UnsafeFlashStack &) {
    return 42;
  }
}
