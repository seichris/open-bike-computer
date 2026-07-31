#pragma once

#include <cstdint>

namespace map_setting_redraw_policy {

constexpr bool invalidatesMap(uint8_t settingId) {
  switch (settingId) {
  case 1:
  case 2:
  case 3:
  case 6:
  case 7:
  case 8:
  case 9:
  case 10:
  case 16:
  case 17:
  case 18:
  case 19:
  case 20:
  case 21:
  case 22:
    return true;
  default:
    return false;
  }
}

} // namespace map_setting_redraw_policy
