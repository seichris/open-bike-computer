// Production storage and methods are inserted by the contract test. Platform
// calls are deterministic fakes; no second implementation of owner admission.
#include <atomic>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include "../../lib/firmware_update/firmware_internal_owner_policy.hpp"
#include "../../lib/firmware_update/firmware_operation_receipt.hpp"
#include "../../lib/device_transfer/device_transfer_network_owner.hpp"

using BaseType_t = int;
using UBaseType_t = unsigned;
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
struct StaticTask_t { int value = 0; };
struct StaticQueue_t { int value = 0; };
struct StaticSemaphore_t { int value = 0; };
constexpr int pdTRUE = 1, ESP_OK = 0, ESP_FAIL = -1;
constexpr int ESP_OTA_IMG_UNDEFINED = 0;
#define pdMS_TO_TICKS(n) (n)
#define configASSERT(n) assert(n)

int creates = 0, sends = 0, resets = 0;
bool createFails = false, mutexFails = false, sendFails = false;
bool receiveFails = false, mismatched = false, resultFails = false;
bool radioStopFails = false;
const void *externalPointer = nullptr;
void *context = nullptr;
SemaphoreHandle_t xSemaphoreCreateMutexStatic(StaticSemaphore_t *s) { return s; }
QueueHandle_t xQueueCreateStatic(unsigned count, unsigned, uint8_t *, StaticQueue_t *q) {
  assert(count == 1);
  return q;
}
bool esp_ptr_internal(const void *p) { return p != externalPointer; }
BaseType_t xSemaphoreTake(SemaphoreHandle_t, TickType_t) { return !mutexFails; }
void xSemaphoreGive(SemaphoreHandle_t) {}
TaskHandle_t xTaskCreateStatic(void (*)(void *), const char *, uint32_t bytes,
                             void *arg, unsigned priority, StackType_t *stack,
                             StaticTask_t *task);
BaseType_t xQueueSend(QueueHandle_t, const void *, TickType_t);
BaseType_t xQueueReceive(QueueHandle_t, void *, TickType_t);
void xQueueReset(QueueHandle_t) { ++resets; }
namespace firmware_update {
struct DeviceWiFiRuntime {
  esp_err_t stop() { return radioStopFails ? ESP_FAIL : ESP_OK; }
  device_transfer::StationState stationState() const { return device_transfer::StationState::Connecting; }
  uint32_t stationIPAddress() const { return 0; }
  uint32_t accessPointIPAddress() const { return 0; }
  uint8_t accessPointClientCount() const { return 0; }
};
}

// PRODUCTION_HEADER
// PRODUCTION_METHODS

using Owner = firmware_update::DeviceOperationOwner;
Owner::Result reply;
void Owner::taskThunk(void *) {}
TaskHandle_t xTaskCreateStatic(void (*)(void *), const char *, uint32_t bytes,
                             void *arg, unsigned priority, StackType_t *stack,
                             StaticTask_t *task) {
  ++creates;
  auto *owner = static_cast<Owner *>(arg);
  assert(bytes == 16384 && sizeof(owner->workerStack_) == bytes);
  assert(stack == owner->workerStack_ && task == &owner->workerTaskStorage_);
  assert(priority == 2 && esp_ptr_internal(stack));
  context = arg;
  return createFails ? nullptr : task;
}
BaseType_t xQueueSend(QueueHandle_t, const void *data, TickType_t) {
  ++sends;
  if (sendFails) return 0;
  auto *owner = static_cast<Owner *>(context);
  const auto &command = *static_cast<const Owner::Command *>(data);
  Owner::Result result;
  switch (command.operation) {
  // PRODUCTION_QUIESCE
  default: assert(false);
  }
  assert(result.error == (radioStopFails ? ESP_FAIL : ESP_OK));
  reply = result;
  reply.commandId = command.id + (mismatched ? 1 : 0);
  if (resultFails) reply.error = ESP_FAIL;
  return pdTRUE;
}
BaseType_t xQueueReceive(QueueHandle_t, void *data, TickType_t) {
  if (receiveFails) return 0;
  *static_cast<Owner::Result *>(data) = reply;
  return pdTRUE;
}

int main() {
  Owner owner;
  assert(owner.release() && creates == 0);
  createFails = true;
  assert(!owner.start() && owner.workerTask_ == nullptr);
  createFails = false;
  for (const void *p : {static_cast<const void *>(owner.workerStack_),
                        static_cast<const void *>(&owner.workerTaskStorage_),
                        static_cast<const void *>(owner.writeBuffer_)}) {
    externalPointer = p;
    assert(!owner.start() && creates == 1);
  }
  externalPointer = nullptr;
  assert(owner.start());
  const TaskHandle_t identity = owner.workerTask_.load();
  for (int session = 0; session < 100; ++session) {
    std::memset(owner.networkSsid_, 0x11, sizeof(owner.networkSsid_));
    std::memset(owner.networkPassword_, 0x22, sizeof(owner.networkPassword_));
    std::memset(owner.mapSessionId_, 0x33, sizeof(owner.mapSessionId_));
    std::memset(owner.writeBuffer_, 0x44, sizeof(owner.writeBuffer_));
    assert(owner.start() && owner.release());
    assert(owner.workerTask_ == identity && creates == 2);
    for (uint8_t b : owner.writeBuffer_) assert(b == 0);
    assert(owner.networkSsid_[0] == 0 && owner.networkPassword_[0] == 0);
    assert(owner.mapSessionId_[0] == 0);
  }
  assert(sends == 100 && resets == 200);
  mutexFails = true;
  assert(!owner.start() && !owner.release());
  mutexFails = false;
  // A bad/late reply cannot revive an owner poisoned during quiescence.
  mismatched = true;
  assert(!owner.release());
  mismatched = false;
  assert(!owner.start() && !owner.release() && resets == 200);
  assert(owner.workerTask_ == identity && creates == 2);
  for (int fault = 0; fault < 3; ++fault) {
    Owner failed;
    assert(failed.start());
    sendFails = fault == 0;
    receiveFails = fault == 1;
    resultFails = fault == 2;
    const int before = resets;
    assert(!failed.release());
    sendFails = receiveFails = resultFails = false;
    assert(!failed.start() && !failed.release() && resets == before);
  }
  Owner radioFailure;
  assert(radioFailure.start());
  radioStopFails = true;
  assert(!radioFailure.release());
  radioStopFails = false;
  assert(!radioFailure.start() && !radioFailure.release());
}
