#pragma once

#include "../../world_radio/world_radio_protocol.hpp"
#include "lvgl.h"

struct WorldRadioScreenCallbacks {
  bool (*sendRequest)(const world_radio_protocol::Request &request) = nullptr;
  void (*cycleScreen)() = nullptr;
  bool (*tapToSwitchScreens)() = nullptr;
  bool (*phoneReady)() = nullptr;
};

void worldRadioScr(lv_obj_t *screen,
                   const WorldRadioScreenCallbacks &callbacks);
void updateWorldRadioScr();
void activateWorldRadioScr();
