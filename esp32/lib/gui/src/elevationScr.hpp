#pragma once

#include "lvgl.h"

struct ElevationScreenCallbacks {
  bool (*phoneConnected)() = nullptr;
  bool (*profilesSupported)() = nullptr;
};

void elevationScr(lv_obj_t *screen, const ElevationScreenCallbacks &callbacks);
void updateElevationScr();
void activateElevationScr();
