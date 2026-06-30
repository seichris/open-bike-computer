#pragma once

#include <Arduino.h>
#include <esp_heap_caps.h>
#include <memory>

/**
 * @brief Custom C++ allocator that forces allocations into PSRAM (SPIRAM)
 *
 * Used for large map data structures (std::vector of points/polygons)
 * to avoid exhausting the limited Internal RAM (SRAM).
 */
template <typename T> struct PsramAllocator {
  using value_type = T;
  using pointer = T *;
  using const_pointer = const T *;
  using reference = T &;
  using const_reference = const T &;
  using size_type = std::size_t;
  using difference_type = std::ptrdiff_t;

  template <typename U> struct rebind {
    using other = PsramAllocator<U>;
  };

  PsramAllocator() = default;

  template <typename U> PsramAllocator(const PsramAllocator<U> &) {}

  T *allocate(std::size_t n) {
    if (n == 0)
      return nullptr;

    // Use MALLOC_CAP_SPIRAM to force allocation to PSRAM.
    // Also use MALLOC_CAP_8BIT to ensure it can be used for general purposes.
    T *p = static_cast<T *>(
        heap_caps_malloc(n * sizeof(T), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));

    if (!p) {
      Serial.printf("PSRAM Allocator: Failed to allocate %u bytes\n",
                    (uint32_t)(n * sizeof(T)));
    }
    return p;
  }

  void deallocate(T *p, std::size_t n) {
    if (p) {
      heap_caps_free(p);
    }
  }
};

template <typename T, typename U>
bool operator==(const PsramAllocator<T> &, const PsramAllocator<U> &) {
  return true;
}

template <typename T, typename U>
bool operator!=(const PsramAllocator<T> &, const PsramAllocator<U> &) {
  return false;
}
