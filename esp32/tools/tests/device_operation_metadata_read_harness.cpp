// Production class, read methods and owner switch cases are inserted by the
// contract test. Fake flash rejects reads on a PSRAM-backed caller stack.
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include "../../lib/firmware_update/firmware_internal_owner_policy.hpp"
#include "../../lib/firmware_update/firmware_metadata_compatibility.hpp"
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

bool internalStack = true, storageFails = false, dispatchFails = false;
bool ownerBusy = false;
unsigned reads = 0, writes = 0, dispatches = 0;
uint32_t floorValue = 1;
TaskHandle_t currentTask = reinterpret_cast<void *>(1);
struct UnsafeFlashStack {};
bool esp_ptr_internal(const void *) { return internalStack; }
TaskHandle_t xTaskGetCurrentTaskHandle() { return currentTask; }
void noteRead() {
  if (!internalStack) throw UnsafeFlashStack{};
  ++reads;
}
namespace firmware_update::metadata_compatibility {
struct FakeStorage final : Storage {
  bool read(uint32_t &value) override { noteRead(); value = floorValue; return !storageFails; }
  bool write(uint32_t value) override { assert(internalStack); ++writes; floorValue = value; return !storageFails; }
};
bool floorAlreadyProtected(uint32_t reader) {
  FakeStorage storage;
  uint32_t floor = 0;
  return storage.read(floor) && floor >= reader;
}
bool requireReader(uint32_t reader) { FakeStorage storage; Store store(storage); return store.require(reader); }
bool allowsReader(uint32_t reader) { FakeStorage storage; Store store(storage); return store.allows(reader); }
}
namespace firmware_update::receipt {
bool load(Record &record) {
  noteRead();
  if (storageFails) return false;
  record = {};
  record.revision = 17;
  record.phase = Phase::Accepted;
  std::strcpy(record.operation, "0123456789abcdef0123456789abcdef");
  return true;
}
}

// PRODUCTION_HEADER
// PRODUCTION_METHODS

namespace firmware_update {
esp_err_t DeviceOperationOwner::execute(const Command &command, Result &result,
    const uint8_t *, const std::string *, const std::string *, TickType_t) {
  ++dispatches;
  // Queueing from the owner would self-deadlock; BLE reads must not queue
  // behind a long activation. Only the fake owner below changes stack context.
  assert(currentTask != workerTask_);
  if (dispatchFails || ownerBusy) return ESP_FAIL;
  const bool callerInternal = internalStack;
  internalStack = true;
  switch (command.operation) {
  // PRODUCTION_READ_CASES
  default: assert(false);
  }
  internalStack = callerInternal;
  return ESP_OK;
}
}

int main() {
  try {
    firmware_update::DeviceOperationOwner owner;
    owner.workerTask_ = reinterpret_cast<void *>(2);
    internalStack = false;
    assert(owner.protectMetadataReaderFloor(1) == ESP_OK);
    assert(dispatches == 1 && reads == 1 && writes == 0);
    assert(owner.allowsMetadataReader(1));
    assert(!owner.allowsMetadataReader(0));
    firmware_update::receipt::Record record{};
    assert(owner.readFirmwareOperationReceipt(record));
    assert(record.revision == 17 && record.phase == firmware_update::receipt::Phase::Accepted);
    assert(std::strcmp(record.operation, "0123456789abcdef0123456789abcdef") == 0);
    storageFails = true;
    assert(!owner.allowsMetadataReader(1));
    record.revision = 99;
    assert(!owner.readFirmwareOperationReceipt(record) && record.revision == 99);
    assert(owner.protectMetadataReaderFloor(1) == ESP_FAIL);
    storageFails = false;
    dispatchFails = true;
    const unsigned before = reads;
    assert(!owner.allowsMetadataReader(1));
    assert(!owner.readFirmwareOperationReceipt(record));
    assert(owner.protectMetadataReaderFloor(1) == ESP_FAIL && reads == before);
    dispatchFails = false;
    internalStack = true;
    ownerBusy = true;
    const unsigned queued = dispatches;
    assert(owner.allowsMetadataReader(1));
    assert(owner.readFirmwareOperationReceipt(record));
    assert(owner.protectMetadataReaderFloor(1) == ESP_OK && dispatches == queued);
    ownerBusy = false;
    // Reentrant activation must raise a not-yet-protected floor on this owner
    // without synchronously sending a command to the same task.
    currentTask = owner.workerTask_;
    floorValue = 0;
    assert(owner.protectMetadataReaderFloor(1) == ESP_OK);
    assert(floorValue == 1 && writes == 1 && dispatches == queued);
  } catch (const UnsafeFlashStack &) {
    return 42;
  }
}
