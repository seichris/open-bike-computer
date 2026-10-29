#pragma once
#include "social_riders.hpp"
#include <lvgl.h>
namespace social_riders {
// All methods run on the existing LVGL owner task.
void hideView();
void beginFrame();
void endFrame();
void addClusterMember(size_t slot);
void showFallbackOrientation(lv_obj_t *parent, bool courseUp);
// `scale` is the friend-marker size percent (100 normal, up to 300); every
// part of the badge stays centred on (x, y).
void draw(size_t slot, lv_obj_t *parent, double x, double y, const Rider &rider,
          bool edge, double meters, uint32_t now, uint16_t scale = MIN_MARKER_SCALE);
}
