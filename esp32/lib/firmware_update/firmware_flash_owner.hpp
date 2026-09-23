#pragma once

#include <Arduino.h>
#include <esp_ota_ops.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include <cstddef>
#include <cstdint>
#include <atomic>
#include <string>

#include "../device_transfer/device_transfer_network_owner.hpp"
#include "firmware_internal_owner_policy.hpp"

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
class FirmwareFlashOwner : public device_transfer::NetworkOperationOwner {
public:
  static constexpr std::size_t kMaximumWriteBytes = 2048;

  void configure();
  bool start();
  bool started() const;
  bool healthy() const override;
  uint32_t stackHighWaterBytes() const override;

  bool startStation(const std::string &ssid,
                    const std::string &password) override;
  bool disconnectStation(bool wifiOff) override;
  bool startAccessPoint(const std::string &ssid,
                        const std::string &passphrase) override;
  bool stopAccessPoint(bool wifiOff) override;
  bool stopWiFi() override;

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
    StartStation,
    DisconnectStation,
    StartAccessPoint,
    StopAccessPoint,
    StopWiFi,
  };

  struct Command {
    Operation operation = Operation::Snapshot;
    const esp_partition_t *partition = nullptr;
    esp_ota_handle_t handle = 0;
    std::size_t size = 0;
    uint32_t id = 0;
    bool wifiOff = false;
  };

  struct Result {
    esp_err_t error = ESP_FAIL;
    esp_ota_handle_t handle = 0;
    FirmwarePartitionSnapshot snapshot;
    esp_app_desc_t description{};
    uint32_t commandId = 0;
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
  char networkSsid_[33]{};
  char networkPassword_[65]{};
  uint32_t nextCommandId_ = 1;
  std::atomic<internal_owner_policy::DispatchState> dispatchState_{
      internal_owner_policy::DispatchState::Ready};

  esp_err_t execute(const Command &command, Result &result,
                    const uint8_t *writeData = nullptr,
                    const std::string *networkSsid = nullptr,
                    const std::string *networkPassword = nullptr);
  void run();
  static void taskThunk(void *context);
};

} // namespace firmware_update
