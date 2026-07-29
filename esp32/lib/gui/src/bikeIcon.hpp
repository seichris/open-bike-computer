/**
 * @file bikeIcon.hpp
 * @brief Reusable Lucide-style bicycle icon for firmware screens.
 */

#pragma once

#include "globalGuiDef.h"

namespace bike_icon {

lv_obj_t *create(lv_obj_t *parent, lv_coord_t size, uint32_t colorHex);

} // namespace bike_icon
