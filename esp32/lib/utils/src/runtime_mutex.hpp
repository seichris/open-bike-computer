#pragma once

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

namespace runtime_ownership {

// No fallible heap allocation and no no-op locking fallback.
class StaticMutex {
public:
  StaticMutex() : handle_(xSemaphoreCreateMutexStatic(&storage_)) {
    configASSERT(handle_ != nullptr);
  }
  StaticMutex(const StaticMutex &) = delete;
  StaticMutex &operator=(const StaticMutex &) = delete;
  ~StaticMutex() { vSemaphoreDelete(handle_); }
  void lock() { xSemaphoreTake(handle_, portMAX_DELAY); }
  void unlock() { xSemaphoreGive(handle_); }
private:
  StaticSemaphore_t storage_{};
  SemaphoreHandle_t handle_;
};

class CriticalSection {
public:
  void lock() { portENTER_CRITICAL(&mux_); }
  void unlock() { portEXIT_CRITICAL(&mux_); }
private:
  portMUX_TYPE mux_ = portMUX_INITIALIZER_UNLOCKED;
};

} // namespace runtime_ownership
