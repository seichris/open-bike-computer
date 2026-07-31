#pragma once

#include "ui_scheduler_policy.hpp"

#include <cstdint>
#include <esp_attr.h>

namespace ui_scheduler {

void bindCurrentTask();
void notify(WakeReason reason);
void IRAM_ATTR notifyFromIsr(WakeReason reason);
uint32_t wait(uint32_t timeoutMs);

} // namespace ui_scheduler
