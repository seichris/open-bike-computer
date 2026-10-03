#include "firmware_metadata_compatibility.hpp"
#include "device_operation_owner.hpp"

#include <cstring>
#include <new>
#include <esp_heap_caps.h>
#include <esp_memory_utils.h>
#include <esp_wifi.h>

namespace firmware_update {
namespace {
device_transfer::NetworkMemorySnapshot networkMemory() {
  return {
      static_cast<uint32_t>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)),
      static_cast<uint32_t>(heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)),
      static_cast<uint32_t>(heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_8BIT)),
      static_cast<uint32_t>(heap_caps_get_largest_free_block(MALLOC_CAP_DMA | MALLOC_CAP_8BIT)),
  };
}
} // namespace

void DeviceOperationOwner::configure() {
  if (callMutex_ == nullptr) {
    callMutex_ = xSemaphoreCreateMutexStatic(&callMutexStorage_);
  }
  if (commandQueue_ == nullptr) {
    commandQueue_ = xQueueCreateStatic(
        1, sizeof(Command), commandQueueBuffer_, &commandQueueStorage_);
  }
  if (resultQueue_ == nullptr) {
    resultQueue_ = xQueueCreateStatic(
        1, sizeof(Result), resultQueueBuffer_, &resultQueueStorage_);
  }
  configASSERT(callMutex_ != nullptr);
  configASSERT(commandQueue_ != nullptr);
  configASSERT(resultQueue_ != nullptr);
}

bool DeviceOperationOwner::start() {
  configure();
  if (xSemaphoreTake(callMutex_, kCommandTimeoutTicks) != pdTRUE)
    return false;
  const bool created = startLocked();
  xSemaphoreGive(callMutex_);
  return created;
}

bool DeviceOperationOwner::startLocked() {
  if (!internal_owner_policy::canIssue(
          dispatchState_.load(std::memory_order_acquire)))
    return false;
  if (workerTask_ != nullptr)
    return true;

  // OTA and Wi-Fi can disable the flash/PSRAM cache. Fail closed if this
  // boot-lifetime owner was ever placed outside internal memory.
  if (!esp_ptr_internal(workerStack_) ||
      !esp_ptr_internal(&workerTaskStorage_) ||
      !esp_ptr_internal(writeBuffer_))
    return false;
  TaskHandle_t worker = xTaskCreateStatic(
      taskThunk, "device_operation", kWorkerStackBytes, this, 2,
      workerStack_, &workerTaskStorage_);
  if (worker == nullptr)
    return false;
  workerTask_ = worker;
  return true;
}

bool DeviceOperationOwner::release() {
  configure();
  if (xSemaphoreTake(callMutex_, kCommandTimeoutTicks) != pdTRUE)
    return false;
  if (workerTask_ == nullptr) {
    xSemaphoreGive(callMutex_);
    return true;
  }
  if (!internal_owner_policy::canIssue(
          dispatchState_.load(std::memory_order_acquire))) {
    xSemaphoreGive(callMutex_);
    return false;
  }
  Command command{Operation::Quiesce};
  command.id = nextCommandId_++;
  if (command.id == 0)
    command.id = nextCommandId_++;
  Result result;
  const bool sent = xQueueSend(commandQueue_, &command, kCommandTimeoutTicks) == pdTRUE;
  const bool received = sent &&
      xQueueReceive(resultQueue_, &result, kCommandTimeoutTicks) == pdTRUE;
  const bool matched = received && result.commandId == command.id &&
                       result.error == ESP_OK;
  if (!matched) {
    dispatchState_.store(internal_owner_policy::DispatchState::Poisoned,
                         std::memory_order_release);
    xSemaphoreGive(callMutex_);
    return false;
  }
  // The matching result proves that staging credentials/data were cleared.
  // Keep the one static task blocked on its queue. Reusing a deleted static
  // TCB before another core's idle cleanup would be unsafe.
  xQueueReset(commandQueue_);
  xQueueReset(resultQueue_);
  xSemaphoreGive(callMutex_);
  return true;
}

bool DeviceOperationOwner::started() const { return workerTask_ != nullptr; }

bool DeviceOperationOwner::healthy() const {
  return started() && internal_owner_policy::canIssue(
                          dispatchState_.load(std::memory_order_acquire));
}

uint32_t DeviceOperationOwner::stackHighWaterBytes() const {
  return lastStackHighWaterBytes_.load(std::memory_order_acquire);
}

FirmwarePartitionSnapshot DeviceOperationOwner::partitionSnapshot() {
  Result result;
  if (execute(Command{Operation::Snapshot}, result) != ESP_OK)
    return {};
  return result.snapshot;
}

bool DeviceOperationOwner::startStation(const std::string &ssid,
                                      const std::string &password) {
  return startStationDetailed(ssid, password).ok();
}

device_transfer::NetworkStartResult DeviceOperationOwner::startStationDetailed(
    const std::string &ssid, const std::string &password) {
  Result result;
  const auto before = networkMemory();
  const esp_err_t dispatch = execute(Command{Operation::StartStation}, result,
                                     nullptr, &ssid, &password);
  if (dispatch != ESP_OK) {
    device_transfer::NetworkStartResult failed;
    failed.failedStep = dispatch == ESP_ERR_NO_MEM
        ? device_transfer::NetworkStartStep::OwnerCreate
        : device_transfer::NetworkStartStep::OwnerDispatch;
    failed.espError = dispatch;
    failed.before = before;
    failed.after = networkMemory();
    return failed;
  }
  return result.networkStart;
}

bool DeviceOperationOwner::disconnectStation(bool wifiOff) {
  Result result;
  Command command{Operation::DisconnectStation};
  command.wifiOff = wifiOff;
  return execute(command, result) == ESP_OK && result.error == ESP_OK;
}

bool DeviceOperationOwner::startAccessPoint(
    const std::string &ssid, const std::string &passphrase) {
  return startAccessPointDetailed(ssid, passphrase).ok();
}

device_transfer::NetworkStartResult DeviceOperationOwner::startAccessPointDetailed(
    const std::string &ssid, const std::string &passphrase) {
  Result result;
  const auto before = networkMemory();
  const esp_err_t dispatch = execute(Command{Operation::StartAccessPoint}, result,
                                     nullptr, &ssid, &passphrase);
  if (dispatch != ESP_OK) {
    device_transfer::NetworkStartResult failed;
    failed.failedStep = dispatch == ESP_ERR_NO_MEM
        ? device_transfer::NetworkStartStep::OwnerCreate
        : device_transfer::NetworkStartStep::OwnerDispatch;
    failed.espError = dispatch;
    failed.before = before;
    failed.after = networkMemory();
    return failed;
  }
  return result.networkStart;
}

esp_err_t DeviceOperationOwner::runMapActivation(
    MapOperation operation, void *context, const std::string &sessionId,
    bool automaticExit) {
  if (operation == nullptr || sessionId.empty() || sessionId.size() >= sizeof(mapSessionId_))
    return ESP_ERR_INVALID_ARG;
  Result result;
  Command command{Operation::MapActivation};
  command.mapOperation = operation;
  command.mapContext = context;
  command.automaticExit = automaticExit;
  const esp_err_t dispatch = execute(command, result, nullptr, &sessionId,
                                     nullptr, kMapActivationTimeoutTicks);
  return dispatch == ESP_OK ? result.error : dispatch;
}

bool DeviceOperationOwner::stopAccessPoint(bool wifiOff) {
  Result result;
  Command command{Operation::StopAccessPoint};
  command.wifiOff = wifiOff;
  return execute(command, result) == ESP_OK && result.error == ESP_OK;
}

bool DeviceOperationOwner::stopWiFi() {
  Result result;
  return execute(Command{Operation::StopWiFi}, result) == ESP_OK &&
         result.error == ESP_OK;
}

esp_err_t DeviceOperationOwner::begin(const esp_partition_t *partition,
                                    std::size_t imageSize,
                                    esp_ota_handle_t &handle) {
  Result result;
  const esp_err_t dispatch = execute(
      Command{Operation::Begin, partition, 0, imageSize}, result);
  handle = dispatch == ESP_OK ? result.handle : 0;
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t DeviceOperationOwner::write(esp_ota_handle_t handle,
                                    const uint8_t *data,
                                    std::size_t size) {
  if (data == nullptr || size == 0 || size > kMaximumWriteBytes)
    return ESP_ERR_INVALID_ARG;
  Result result;
  const esp_err_t dispatch = execute(
      Command{Operation::Write, nullptr, handle, size}, result, data);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t DeviceOperationOwner::end(esp_ota_handle_t handle) {
  Result result;
  const esp_err_t dispatch =
      execute(Command{Operation::End, nullptr, handle}, result);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t DeviceOperationOwner::abort(esp_ota_handle_t handle) {
  Result result;
  const esp_err_t dispatch =
      execute(Command{Operation::Abort, nullptr, handle}, result);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t DeviceOperationOwner::description(
    const esp_partition_t *partition, esp_app_desc_t &description) {
  Result result;
  const esp_err_t dispatch = execute(
      Command{Operation::Description, partition}, result);
  if (dispatch == ESP_OK && result.error == ESP_OK)
    description = result.description;
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t DeviceOperationOwner::selectBootPartition(
    const esp_partition_t *partition) {
  Result result;
  const esp_err_t dispatch =
      execute(Command{Operation::SelectBoot, partition}, result);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t DeviceOperationOwner::protectMetadataReaderFloor(uint32_t reader) {
  // Read-only fast path avoids allocating an idle 16 KiB owner on every boot.
  if (metadata_compatibility::floorAlreadyProtected(reader)) return ESP_OK;
  Command command;
  command.operation = Operation::ProtectMetadataReaderFloor;
  command.receiptRevision = reader;
  Result result;
  const auto dispatch = execute(command, result);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t DeviceOperationOwner::acceptFirmwareOperation(const receipt::Record &record, uint32_t revision) {
  Command command; command.operation = Operation::AcceptFirmwareOperation;
  command.firmwareReceipt = record; command.receiptRevision = revision;
  Result result; const auto dispatch = execute(command, result);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t DeviceOperationOwner::acknowledgeFirmwareOperation(const receipt::Record &record) {
  Command command; command.operation = Operation::AcknowledgeFirmwareOperation;
  command.firmwareReceipt = record;
  Result result; const auto dispatch = execute(command, result);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t DeviceOperationOwner::execute(
    const Command &command, Result &result, const uint8_t *writeData,
    const std::string *networkSsid,
    const std::string *networkPassword, TickType_t timeoutTicks) {
  configure();
  if (xSemaphoreTake(callMutex_, timeoutTicks) != pdTRUE) {
    return ESP_ERR_TIMEOUT;
  }

  if (!startLocked()) {
    xSemaphoreGive(callMutex_);
    return internal_owner_policy::canIssue(dispatchState_.load())
               ? ESP_ERR_NO_MEM : ESP_ERR_INVALID_STATE;
  }

  esp_err_t dispatch = ESP_FAIL;
  do {
    if (!internal_owner_policy::canIssue(
            dispatchState_.load(std::memory_order_acquire))) {
      dispatch = ESP_ERR_INVALID_STATE;
      break;
    }
    if (command.operation == Operation::Write) {
      if (writeData == nullptr || command.size == 0 ||
          command.size > sizeof(writeBuffer_)) {
        dispatch = ESP_ERR_INVALID_ARG;
        break;
      }
      std::memcpy(writeBuffer_, writeData, command.size);
    }
    if (command.operation == Operation::MapActivation) {
      if (networkSsid == nullptr || networkSsid->empty() ||
          networkSsid->size() >= sizeof(mapSessionId_)) {
        dispatch = ESP_ERR_INVALID_ARG;
        break;
      }
      std::memcpy(mapSessionId_, networkSsid->c_str(), networkSsid->size() + 1);
    } else if (networkSsid != nullptr) {
      if (networkSsid->empty() || networkSsid->size() >= sizeof(networkSsid_) ||
          networkPassword == nullptr ||
          networkPassword->size() >= sizeof(networkPassword_)) {
        dispatch = ESP_ERR_INVALID_ARG;
        break;
      }
      std::memcpy(networkSsid_, networkSsid->c_str(), networkSsid->size() + 1);
      std::memcpy(networkPassword_, networkPassword->c_str(),
                  networkPassword->size() + 1);
    }
    Command queuedCommand = command;
    queuedCommand.id = nextCommandId_++;
    if (queuedCommand.id == 0)
      queuedCommand.id = nextCommandId_++;
    if (xQueueSend(commandQueue_, &queuedCommand,
                   timeoutTicks) != pdTRUE) {
      dispatchState_.store(internal_owner_policy::commandTimedOut(
                               dispatchState_.load(std::memory_order_relaxed)),
                           std::memory_order_release);
      dispatch = ESP_ERR_TIMEOUT;
      break;
    }
    dispatchState_.store(internal_owner_policy::commandIssued(
                             dispatchState_.load(std::memory_order_relaxed)),
                         std::memory_order_release);
    if (xQueueReceive(resultQueue_, &result,
                      timeoutTicks) != pdTRUE) {
      // The issued operation may still be using the staging buffers or may
      // complete later. Permanently reject subsequent commands in this boot
      // so a late result cannot be paired with a new caller and the shared
      // write buffer cannot be overwritten while flash still consumes it.
      dispatchState_.store(internal_owner_policy::commandTimedOut(
                               dispatchState_.load(std::memory_order_relaxed)),
                           std::memory_order_release);
      dispatch = ESP_ERR_TIMEOUT;
      break;
    }
    const bool matchingResult = result.commandId == queuedCommand.id;
    dispatchState_.store(internal_owner_policy::commandCompleted(
                             dispatchState_.load(std::memory_order_relaxed),
                             matchingResult),
                         std::memory_order_release);
    if (!matchingResult) {
      dispatch = ESP_ERR_INVALID_STATE;
      break;
    }
    dispatch = ESP_OK;
  } while (false);

  xSemaphoreGive(callMutex_);
  return dispatch;
}

void DeviceOperationOwner::run() {
  for (;;) {
    Command command;
    if (xQueueReceive(commandQueue_, &command, portMAX_DELAY) != pdTRUE)
      continue;

    Result result;
    result.commandId = command.id;
    switch (command.operation) {
    case Operation::Snapshot:
      result.snapshot.running = esp_ota_get_running_partition();
      result.snapshot.inactive = esp_ota_get_next_update_partition(nullptr);
      if (result.snapshot.running != nullptr) {
        result.snapshot.runningStateResult = esp_ota_get_state_partition(
            result.snapshot.running, &result.snapshot.runningState);
      }
      result.error = ESP_OK;
      break;
    case Operation::Begin:
      result.error = esp_ota_begin(command.partition, command.size,
                                   &result.handle);
      break;
    case Operation::Write:
      result.error = esp_ota_write(command.handle, writeBuffer_, command.size);
      break;
    case Operation::End:
      result.error = esp_ota_end(command.handle);
      break;
    case Operation::Abort:
      result.error = esp_ota_abort(command.handle);
      break;
    case Operation::Description:
      result.error = esp_ota_get_partition_description(
          command.partition, &result.description);
      break;
    case Operation::ProtectMetadataReaderFloor:
      result.error = metadata_compatibility::requireReader(command.receiptRevision) ? ESP_OK : ESP_FAIL;
      break;
    case Operation::SelectBoot:
      result.error = esp_ota_set_boot_partition(command.partition);
      break;
    case Operation::AcceptFirmwareOperation: {
      receipt::Record current{};
      result.error = receipt::load(current) &&
          current.revision == command.receiptRevision &&
          receipt::accept(command.firmwareReceipt) ? ESP_OK : ESP_FAIL;
      break;
    }
    case Operation::AcknowledgeFirmwareOperation:
      result.error = receipt::acknowledge(command.firmwareReceipt.device,
          command.firmwareReceipt.operation, command.firmwareReceipt.image) ? ESP_OK : ESP_FAIL;
      break;
    case Operation::StartStation:
    case Operation::StartAccessPoint:
      result.networkStart = wifi_.start(command.operation == Operation::StartStation,
                                        networkSsid_, networkPassword_, networkMemory);
      result.error = result.networkStart.ok() ? ESP_OK : result.networkStart.espError;
      break;
    case Operation::DisconnectStation:
    case Operation::StopAccessPoint:
    case Operation::StopWiFi:
      result.error = wifi_.stop();
      break;
    case Operation::MapActivation:
      // Map finalization performs long SD transactions. Match the former
      // HTTP worker's priority so the UI/idle tasks keep making progress.
      vTaskPrioritySet(nullptr, 1);
      try {
        command.mapOperation(command.mapContext, mapSessionId_,
                             command.automaticExit);
        result.error = ESP_OK;
      } catch (const std::bad_alloc &) {
        result.error = ESP_ERR_NO_MEM;
      } catch (...) {
        result.error = ESP_FAIL;
      }
      vTaskPrioritySet(nullptr, 2);
      break;
    case Operation::Quiesce:
      result.error = wifi_.stop();
      std::memset(networkSsid_, 0, sizeof(networkSsid_));
      std::memset(networkPassword_, 0, sizeof(networkPassword_));
      std::memset(mapSessionId_, 0, sizeof(mapSessionId_));
      std::memset(writeBuffer_, 0, sizeof(writeBuffer_));
      break;
    }
    lastStackHighWaterBytes_.store(
        static_cast<uint32_t>(uxTaskGetStackHighWaterMark(nullptr)),
        std::memory_order_release);
    stackSampleAvailable_.store(true, std::memory_order_release);
    (void)xQueueSend(resultQueue_, &result, portMAX_DELAY);
  }
}

void DeviceOperationOwner::taskThunk(void *context) {
  static_cast<DeviceOperationOwner *>(context)->run();
}

} // namespace firmware_update
