#pragma once

#include <sdkconfig.h>

// Check the effective custom core, not only the tracked PlatformIO override.
// Bluetooth startup needs room for interrupt entry on the interrupted IPC task.
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#if !defined(CONFIG_ESP_IPC_TASK_STACK_SIZE) || CONFIG_ESP_IPC_TASK_STACK_SIZE < 1536
#error "Waveshare Bluetooth IPC stack requires at least 1536 bytes"
#endif
#endif
