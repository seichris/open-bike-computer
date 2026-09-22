#include "firmware_flash_owner.hpp"

#include <cstring>
#include <esp_heap_caps.h>

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

uint32_t FirmwareFlashOwner::stackHighWaterBytes() const {
  const TaskHandle_t worker = workerTask_;
  if (worker == nullptr)
    return 0;
  return static_cast<uint32_t>(uxTaskGetStackHighWaterMark(worker)) *
         sizeof(StackType_t);
}

FirmwarePartitionSnapshot FirmwareFlashOwner::partitionSnapshot() {
  Result result;
  if (!execute(Command{Operation::Snapshot}, result))
    return {};
  return result.snapshot;
}

esp_err_t FirmwareFlashOwner::begin(const esp_partition_t *partition,
                                    std::size_t imageSize,
                                    esp_ota_handle_t &handle) {
  Result result;
  const bool completed = execute(
      Command{Operation::Begin, partition, 0, imageSize}, result);
  handle = completed ? result.handle : 0;
  return completed ? result.error : ESP_FAIL;
}

esp_err_t FirmwareFlashOwner::write(esp_ota_handle_t handle,
                                    const uint8_t *data,
                                    std::size_t size) {
  if (data == nullptr || size == 0 || size > kMaximumWriteBytes)
    return ESP_ERR_INVALID_ARG;
  Result result;
  return execute(Command{Operation::Write, nullptr, handle, size}, result,
                 data)
             ? result.error
             : ESP_FAIL;
}

esp_err_t FirmwareFlashOwner::end(esp_ota_handle_t handle) {
  Result result;
  return execute(Command{Operation::End, nullptr, handle}, result)
             ? result.error
             : ESP_FAIL;
}

esp_err_t FirmwareFlashOwner::abort(esp_ota_handle_t handle) {
  Result result;
  return execute(Command{Operation::Abort, nullptr, handle}, result)
             ? result.error
             : ESP_FAIL;
}

esp_err_t FirmwareFlashOwner::description(
    const esp_partition_t *partition, esp_app_desc_t &description) {
  Result result;
  const bool completed = execute(
      Command{Operation::Description, partition}, result);
  if (completed && result.error == ESP_OK)
    description = result.description;
  return completed ? result.error : ESP_FAIL;
}

esp_err_t FirmwareFlashOwner::selectBootPartition(
    const esp_partition_t *partition) {
  Result result;
  return execute(Command{Operation::SelectBoot, partition}, result)
             ? result.error
             : ESP_FAIL;
}

bool FirmwareFlashOwner::execute(const Command &command, Result &result,
                                 const uint8_t *writeData) {
  if (!start() ||
      xSemaphoreTake(callMutex_, kCommandTimeoutTicks) != pdTRUE) {
    return false;
  }

  bool completed = false;
  do {
    if (command.operation == Operation::Write) {
      if (writeData == nullptr || command.size == 0 ||
          command.size > sizeof(writeBuffer_)) {
        break;
      }
      std::memcpy(writeBuffer_, writeData, command.size);
    }
    if (xQueueSend(commandQueue_, &command, kCommandTimeoutTicks) != pdTRUE)
      break;
    completed =
        xQueueReceive(resultQueue_, &result, kCommandTimeoutTicks) == pdTRUE;
  } while (false);

  xSemaphoreGive(callMutex_);
  return completed;
}

void FirmwareFlashOwner::run() {
  for (;;) {
    Command command;
    if (xQueueReceive(commandQueue_, &command, portMAX_DELAY) != pdTRUE)
      continue;

    Result result;
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
    }
    (void)xQueueSend(resultQueue_, &result, portMAX_DELAY);
  }
}

void FirmwareFlashOwner::taskThunk(void *context) {
  static_cast<FirmwareFlashOwner *>(context)->run();
}

} // namespace firmware_update
