#pragma once

#include <cstddef>
#include <cstdint>

struct HostSerial {
  template <typename... Args> void printf(const char *, Args...) {}
};
inline HostSerial Serial;
