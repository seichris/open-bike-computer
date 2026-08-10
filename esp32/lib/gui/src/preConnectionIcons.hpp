#pragma once

#include "lvgl.h"

#include <cstdint>

namespace pre_connection_icons {

enum class Artwork : uint8_t {
  PairingConfirmed,
  WaitingForIPhone,
  Connecting,
  GettingLocation,
};

lv_obj_t *create(lv_obj_t *parent, Artwork artwork);

} // namespace pre_connection_icons
