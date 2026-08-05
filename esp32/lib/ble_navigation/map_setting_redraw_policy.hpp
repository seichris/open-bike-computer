#pragma once

#include "map_profile_protocol.hpp"

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
  case map_profile_protocol::MAP_NAVIGATION_BIRDS_EYE_SETTING_ID:
  case map_profile_protocol::MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID:
  case map_profile_protocol::MAP_LABEL_DENSITY_SETTING_ID:
  case map_profile_protocol::MAP_LABEL_LANGUAGE_MODE_SETTING_ID:
  case map_profile_protocol::MAP_LABEL_TEXT_SIZE_SETTING_ID:
  case map_profile_protocol::MAP_LABEL_ORIENTATION_SETTING_ID:
  case map_profile_protocol::MAP_NAVIGATION_LABEL_DENSITY_SETTING_ID:
  case map_profile_protocol::MAP_NAVIGATION_LABEL_LANGUAGE_MODE_SETTING_ID:
  case map_profile_protocol::MAP_NAVIGATION_LABEL_TEXT_SIZE_SETTING_ID:
  case map_profile_protocol::MAP_NAVIGATION_LABEL_ORIENTATION_SETTING_ID:
  case map_profile_protocol::MAP_NAVIGATION_3D_BUILDINGS_SETTING_ID:
    return true;
  default:
    return false;
  }
}

constexpr bool changesZoom(uint8_t settingId) {
  return settingId == 7 || settingId == 19;
}

} // namespace map_setting_redraw_policy
