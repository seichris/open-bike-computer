#pragma once
#include <cstdint>
namespace world_radio_flags {
constexpr int WIDTH = 24;
constexpr int HEIGHT = 16;
const uint16_t *find(const char *countryCode);
}
