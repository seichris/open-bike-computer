#include "ui_scheduler.hpp"

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace ui_scheduler {
namespace {

TaskHandle_t uiTask = nullptr;

} // namespace

void bindCurrentTask() { uiTask = xTaskGetCurrentTaskHandle(); }

void notify(WakeReason reason) {
  if (uiTask == nullptr || reason == WakeReason::None) {
    return;
  }
  xTaskNotify(uiTask, reasonBits(reason), eSetBits);
}

void notifyFromIsr(WakeReason reason) {
  if (uiTask == nullptr || reason == WakeReason::None) {
    return;
  }
  BaseType_t higherPriorityTaskWoken = pdFALSE;
  xTaskNotifyFromISR(uiTask, reasonBits(reason), eSetBits,
                     &higherPriorityTaskWoken);
  if (higherPriorityTaskWoken == pdTRUE) {
    portYIELD_FROM_ISR();
  }
}

uint32_t wait(uint32_t timeoutMs) {
  uint32_t reasons = 0;
  TickType_t timeoutTicks = timeoutMs == 0 ? 0 : pdMS_TO_TICKS(timeoutMs);
  if (timeoutMs > 0 && timeoutTicks == 0) {
    timeoutTicks = 1;
  }
  xTaskNotifyWait(0, std::numeric_limits<uint32_t>::max(), &reasons,
                  timeoutTicks);
  return reasons;
}

} // namespace ui_scheduler
