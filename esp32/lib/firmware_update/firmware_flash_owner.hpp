#pragma once

#include <Arduino.h>
#include <esp_ota_ops.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include <cstddef>
#include <cstdint>

namespace firmware_update {

struct FirmwarePartitionSnapshot {
  const esp_partition_t *running = nullptr;
  const esp_partition_t *inactive = nullptr;
  esp_err_t runningStateResult = ESP_FAIL;
  esp_ota_img_states_t runningState = ESP_OTA_IMG_UNDEFINED;
};

// Owns every cache-disabling OTA operation on one internal-RAM stack. The
// HTTPS/TLS worker can therefore live in PSRAM without ever being the caller
// whose stack must remain accessible while the flash cache is disabled.
class FirmwareFlashOwner {
public:
  static constexpr std::size_t kMaximumWriteBytes = 2048;

  void configure();
  bool start();
  bool started() const;
  uint32_t stackHighWaterBytes() const;

  FirmwarePartitionSnapshot partitionSnapshot();
  esp_err_t begin(const esp_partition_t *partition, std::size_t imageSize,
                  esp_ota_handle_t &handle);
  esp_err_t write(esp_ota_handle_t handle, const uint8_t *data,
                  std::size_t size);
  esp_err_t end(esp_ota_handle_t handle);
  esp_err_t abort(esp_ota_handle_t handle);
  esp_err_t description(const esp_partition_t *partition,
                        esp_app_desc_t &description);
  esp_err_t selectBootPartition(const esp_partition_t *partition);

private:
  enum class Operation : uint8_t {
    Snapshot = 0,
    Begin,
    Write,
    End,
    Abort,
    Description,
    SelectBoot,
  };

  struct Command {
    Operation operation = Operation::Snapshot;
    const esp_partition_t *partition = nullptr;
    esp_ota_handle_t handle = 0;
    std::size_t size = 0;
  };

  struct Result {
    esp_err_t error = ESP_FAIL;
    esp_ota_handle_t handle = 0;
    FirmwarePartitionSnapshot snapshot;
    esp_app_desc_t description{};
  };

  static constexpr uint32_t kWorkerStackBytes = 8192;
  static constexpr TickType_t kCommandTimeoutTicks = pdMS_TO_TICKS(60000);

  mutable SemaphoreHandle_t callMutex_ = nullptr;
  StaticSemaphore_t callMutexStorage_{};
  QueueHandle_t commandQueue_ = nullptr;
  StaticQueue_t commandQueueStorage_{};
  uint8_t commandQueueBuffer_[sizeof(Command)]{};
  QueueHandle_t resultQueue_ = nullptr;
  StaticQueue_t resultQueueStorage_{};
  uint8_t resultQueueBuffer_[sizeof(Result)]{};
  TaskHandle_t workerTask_ = nullptr;
  alignas(4) uint8_t writeBuffer_[kMaximumWriteBytes]{};

  bool execute(const Command &command, Result &result,
               const uint8_t *writeData = nullptr);
  void run();
  static void taskThunk(void *context);
};

} // namespace firmware_update
