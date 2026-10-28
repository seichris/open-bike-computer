#pragma once

// Large, bounded task-only workspaces do not need scarce internal/DMA RAM.
// Never apply this to ISR data, RTOS control blocks, DMA buffers, or anything
// accessed while the flash/PSRAM cache is disabled. The SDK initializes and
// zeroes external BSS before C++ constructors, preserving StartupConstructed
// defaults without a late heap allocation or an internal-memory fallback.
#if defined(ESP_PLATFORM) && \
    (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206))
#include <sdkconfig.h>
#include <esp_attr.h>
#if !CONFIG_SPIRAM_BOOT_HW_INIT || !CONFIG_SPIRAM_BOOT_INIT || \
    !CONFIG_SPIRAM_MEMTEST || !CONFIG_SPIRAM_ALLOW_BSS_SEG_EXTERNAL_MEMORY
#error "Waveshare task data requires tested boot-initialized external BSS"
#endif
#define BICINO_TASK_DATA EXT_RAM_BSS_ATTR
#else
// Other boards and host behavioral tests retain their existing storage.
#define BICINO_TASK_DATA
#endif
