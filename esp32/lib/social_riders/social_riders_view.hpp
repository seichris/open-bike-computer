#pragma once
#include "social_riders.hpp"
#include <lvgl.h>
namespace social_riders {
// All methods run on the existing LVGL owner task.
void hideView();
void addClusterMember(size_t slot);
void draw(size_t slot, lv_obj_t *parent, double x, double y, const Rider &rider,
          bool edge, double meters, uint32_t now);
}
