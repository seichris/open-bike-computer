/**
 * @file navScr.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  LVGL - Navigation screen 
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include "globalGuiDef.h"
#include "navup.h"
#include <cstddef>

/**
 * @brief Navigation Tile screen objects
 *
 */
extern lv_obj_t *nameNav;
extern lv_obj_t *latNav;
extern lv_obj_t *lonNav;
extern lv_obj_t *distNav;
extern lv_obj_t *arrowNav;

void navigationScr(_lv_obj_t *screen);
void applyNavigationArrowStyle(lv_obj_t *arrow);
void formatNavigationInstruction(const char *instruction, char *buffer,
                                 size_t bufferSize);
