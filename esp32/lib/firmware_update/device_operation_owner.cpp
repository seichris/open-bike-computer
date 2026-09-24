#include "device_operation_owner.hpp"

#include <cstring>
#include <new>
#include <esp_heap_caps.h>
#include <esp_wifi.h>
#include <WiFi.h>

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

  TaskHandle_t worker = nullptr;
  const BaseType_t created = xTaskCreateWithCaps(
      taskThunk, "device_operation", kWorkerStackBytes, this, 2, &worker,
      static_cast<UBaseType_t>(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  if (created != pdPASS)
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
  Command command{Operation::Shutdown};
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
  // The owner sent its terminal result and then parks forever. It cannot
  // touch a staging buffer after this point; reclaim its capability stack.
  vTaskDeleteWithCaps(workerTask_);
  workerTask_ = nullptr;
  xQueueReset(commandQueue_);
  xQueueReset(resultQueue_);
  std::memset(networkSsid_, 0, sizeof(networkSsid_));
  std::memset(networkPassword_, 0, sizeof(networkPassword_));
  std::memset(mapSessionId_, 0, sizeof(mapSessionId_));
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
  Result result;
  return execute(Command{Operation::StartStation}, result, nullptr, &ssid,
                 &password) == ESP_OK &&
         result.error == ESP_OK;
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
    case Operation::SelectBoot:
      result.error = esp_ota_set_boot_partition(command.partition);
      break;
    case Operation::StartStation:
      WiFi.persistent(false);
      if (!WiFi.mode(WIFI_STA)) {
        result.error = ESP_FAIL;
        break;
      }
      if (esp_wifi_set_storage(WIFI_STORAGE_RAM) != ESP_OK) {
        result.error = ESP_FAIL;
        break;
      }
      WiFi.setAutoReconnect(false);
      (void)WiFi.begin(networkSsid_, networkPassword_);
      result.error = ESP_OK;
      break;
    case Operation::DisconnectStation:
      result.error = WiFi.disconnect(command.wifiOff, false) ? ESP_OK
                                                              : ESP_FAIL;
      break;
    case Operation::StartAccessPoint: {
      result.networkStart.mode.attempted = true;
      result.networkStart.mode.before = networkMemory();
      WiFi.persistent(false);
      const bool modeStarted = WiFi.mode(WIFI_AP);
      result.networkStart.mode.after = networkMemory();
      if (!modeStarted) {
        result.networkStart.failedStep = device_transfer::NetworkStartStep::Mode;
        result.error = ESP_FAIL;
        break;
      }
      result.networkStart.ramStorage.attempted = true;
      result.networkStart.ramStorage.before = networkMemory();
      result.error = esp_wifi_set_storage(WIFI_STORAGE_RAM);
      result.networkStart.ramStorage.after = networkMemory();
      if (result.error != ESP_OK) {
        result.networkStart.failedStep = device_transfer::NetworkStartStep::RamStorage;
        result.networkStart.espError = result.error;
        break;
      }
      result.networkStart.accessPoint.attempted = true;
      result.networkStart.accessPoint.before = networkMemory();
      result.error = WiFi.softAP(networkSsid_, networkPassword_) ? ESP_OK
                                                                  : ESP_FAIL;
      result.networkStart.accessPoint.after = networkMemory();
      if (result.error != ESP_OK)
        result.networkStart.failedStep = device_transfer::NetworkStartStep::AccessPoint;
      break;
    }
    case Operation::StopAccessPoint:
      result.error = WiFi.softAPdisconnect(command.wifiOff) ? ESP_OK
                                                             : ESP_FAIL;
      break;
    case Operation::StopWiFi:
      result.error = WiFi.mode(WIFI_OFF) ? ESP_OK : ESP_FAIL;
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
    case Operation::Shutdown:
      result.error = ESP_OK;
      break;
    }
    if (command.operation == Operation::StartAccessPoint) {
      const auto *step = result.networkStart.failedStep ==
                                 device_transfer::NetworkStartStep::Mode
                             ? &result.networkStart.mode
                         : result.networkStart.failedStep ==
                                 device_transfer::NetworkStartStep::RamStorage
                             ? &result.networkStart.ramStorage
                             : &result.networkStart.accessPoint;
      result.networkStart.before = step->before;
      result.networkStart.after = step->after;
    }
    lastStackHighWaterBytes_.store(
        static_cast<uint32_t>(uxTaskGetStackHighWaterMark(nullptr)) *
            sizeof(StackType_t),
        std::memory_order_release);
    (void)xQueueSend(resultQueue_, &result, portMAX_DELAY);
    if (command.operation == Operation::Shutdown)
      (void)ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
  }
}

void DeviceOperationOwner::taskThunk(void *context) {
  static_cast<DeviceOperationOwner *>(context)->run();
}

} // namespace firmware_update
