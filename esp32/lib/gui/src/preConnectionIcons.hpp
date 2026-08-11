#pragma once

#include "preConnectionPresentation.hpp"
#include "lvgl.h"

namespace pre_connection_icons {

using Artwork = pre_connection_presentation::Artwork;

lv_obj_t *create(lv_obj_t *parent, Artwork artwork);

} // namespace pre_connection_icons
