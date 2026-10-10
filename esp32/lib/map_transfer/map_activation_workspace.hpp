#pragma once

#include <cstdlib>
#include <memory>
#include <new>
#include <utility>

#if defined(ARDUINO) && defined(BOARD_HAS_PSRAM)
#include <esp_heap_caps.h>
#endif

namespace map_transfer {
// Per-call ownership keeps concurrent status readers independent. Fixed-size
// activation scratch must not consume the internal stack or its heap reserve.
// No internal-memory fallback is allowed on PSRAM-equipped boards.
struct ActivationWorkspaceDeleter {
  template <typename T> void operator()(T *value) const noexcept {
    if (!value) return;
    value->~T();
#if defined(ARDUINO) && defined(BOARD_HAS_PSRAM)
    heap_caps_free(value);
#else
    std::free(value);
#endif
  }
};

template <typename T, typename... Args>
std::unique_ptr<T, ActivationWorkspaceDeleter> makeActivationWorkspace(Args &&...args) {
#if defined(ARDUINO) && defined(BOARD_HAS_PSRAM)
  void *memory = heap_caps_malloc(sizeof(T), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#else
  void *memory = std::malloc(sizeof(T));
#endif
  if (!memory) throw std::bad_alloc();
  try {
    return std::unique_ptr<T, ActivationWorkspaceDeleter>(
        new (memory) T(std::forward<Args>(args)...));
  } catch (...) {
#if defined(ARDUINO) && defined(BOARD_HAS_PSRAM)
    heap_caps_free(memory);
#else
    std::free(memory);
#endif
    throw;
  }
}
} // namespace map_transfer
