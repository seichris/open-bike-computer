#include "firmware_flash_owner.hpp"

#include <cstring>
#include <esp_heap_caps.h>
#include <esp_wifi.h>
#include <WiFi.h>

namespace firmware_update {

void FirmwareFlashOwner::configure() {
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

bool FirmwareFlashOwner::start() {
  configure();
  if (workerTask_ != nullptr)
    return true;

  TaskHandle_t worker = nullptr;
  const BaseType_t created = xTaskCreateWithCaps(
      taskThunk, "firmware_flash", kWorkerStackBytes, this, 2, &worker,
      static_cast<UBaseType_t>(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
  if (created != pdPASS)
    return false;
  workerTask_ = worker;
  return true;
}

bool FirmwareFlashOwner::started() const { return workerTask_ != nullptr; }

bool FirmwareFlashOwner::healthy() const {
  return started() && internal_owner_policy::canIssue(
                          dispatchState_.load(std::memory_order_acquire));
}

uint32_t FirmwareFlashOwner::stackHighWaterBytes() const {
  const TaskHandle_t worker = workerTask_;
  if (worker == nullptr)
    return 0;
  return static_cast<uint32_t>(uxTaskGetStackHighWaterMark(worker)) *
         sizeof(StackType_t);
}

FirmwarePartitionSnapshot FirmwareFlashOwner::partitionSnapshot() {
  Result result;
  if (execute(Command{Operation::Snapshot}, result) != ESP_OK)
    return {};
  return result.snapshot;
}

bool FirmwareFlashOwner::startStation(const std::string &ssid,
                                      const std::string &password) {
  Result result;
  return execute(Command{Operation::StartStation}, result, nullptr, &ssid,
                 &password) == ESP_OK &&
         result.error == ESP_OK;
}

bool FirmwareFlashOwner::disconnectStation(bool wifiOff) {
  Result result;
  Command command{Operation::DisconnectStation};
  command.wifiOff = wifiOff;
  return execute(command, result) == ESP_OK && result.error == ESP_OK;
}

bool FirmwareFlashOwner::startAccessPoint(
    const std::string &ssid, const std::string &passphrase) {
  Result result;
  return execute(Command{Operation::StartAccessPoint}, result, nullptr, &ssid,
                 &passphrase) == ESP_OK &&
         result.error == ESP_OK;
}

bool FirmwareFlashOwner::stopAccessPoint(bool wifiOff) {
  Result result;
  Command command{Operation::StopAccessPoint};
  command.wifiOff = wifiOff;
  return execute(command, result) == ESP_OK && result.error == ESP_OK;
}

bool FirmwareFlashOwner::stopWiFi() {
  Result result;
  return execute(Command{Operation::StopWiFi}, result) == ESP_OK &&
         result.error == ESP_OK;
}

esp_err_t FirmwareFlashOwner::begin(const esp_partition_t *partition,
                                    std::size_t imageSize,
                                    esp_ota_handle_t &handle) {
  Result result;
  const esp_err_t dispatch = execute(
      Command{Operation::Begin, partition, 0, imageSize}, result);
  handle = dispatch == ESP_OK ? result.handle : 0;
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t FirmwareFlashOwner::write(esp_ota_handle_t handle,
                                    const uint8_t *data,
                                    std::size_t size) {
  if (data == nullptr || size == 0 || size > kMaximumWriteBytes)
    return ESP_ERR_INVALID_ARG;
  Result result;
  const esp_err_t dispatch = execute(
      Command{Operation::Write, nullptr, handle, size}, result, data);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t FirmwareFlashOwner::end(esp_ota_handle_t handle) {
  Result result;
  const esp_err_t dispatch =
      execute(Command{Operation::End, nullptr, handle}, result);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t FirmwareFlashOwner::abort(esp_ota_handle_t handle) {
  Result result;
  const esp_err_t dispatch =
      execute(Command{Operation::Abort, nullptr, handle}, result);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t FirmwareFlashOwner::description(
    const esp_partition_t *partition, esp_app_desc_t &description) {
  Result result;
  const esp_err_t dispatch = execute(
      Command{Operation::Description, partition}, result);
  if (dispatch == ESP_OK && result.error == ESP_OK)
    description = result.description;
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t FirmwareFlashOwner::selectBootPartition(
    const esp_partition_t *partition) {
  Result result;
  const esp_err_t dispatch =
      execute(Command{Operation::SelectBoot, partition}, result);
  return dispatch == ESP_OK ? result.error : dispatch;
}

esp_err_t FirmwareFlashOwner::execute(
    const Command &command, Result &result, const uint8_t *writeData,
    const std::string *networkSsid,
    const std::string *networkPassword) {
  if (!start())
    return ESP_ERR_NO_MEM;
  if (xSemaphoreTake(callMutex_, kCommandTimeoutTicks) != pdTRUE) {
    return ESP_ERR_TIMEOUT;
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
    if (networkSsid != nullptr) {
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
                   kCommandTimeoutTicks) != pdTRUE) {
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
                      kCommandTimeoutTicks) != pdTRUE) {
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

void FirmwareFlashOwner::run() {
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
    case Operation::StartAccessPoint:
      WiFi.persistent(false);
      if (!WiFi.mode(WIFI_AP) ||
          esp_wifi_set_storage(WIFI_STORAGE_RAM) != ESP_OK) {
        result.error = ESP_FAIL;
        break;
      }
      result.error = WiFi.softAP(networkSsid_, networkPassword_) ? ESP_OK
                                                                  : ESP_FAIL;
      break;
    case Operation::StopAccessPoint:
      result.error = WiFi.softAPdisconnect(command.wifiOff) ? ESP_OK
                                                             : ESP_FAIL;
      break;
    case Operation::StopWiFi:
      result.error = WiFi.mode(WIFI_OFF) ? ESP_OK : ESP_FAIL;
      break;
    }
    (void)xQueueSend(resultQueue_, &result, portMAX_DELAY);
  }
}

void FirmwareFlashOwner::taskThunk(void *context) {
  static_cast<FirmwareFlashOwner *>(context)->run();
}

} // namespace firmware_update
