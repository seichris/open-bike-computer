/**
 * @file navScr.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  LVGL - Navigation screen 
 * @version 0.2.2
 * @date 2025-05
 */

#include "navScr.hpp"

lv_obj_t *nameNav;
lv_obj_t *latNav;
lv_obj_t *lonNav;
lv_obj_t *distNav;
lv_obj_t *arrowNav;

/**
 * @brief Navigation screen
 *
 * @param screen 
 */
#ifndef TDECK_ESP32S3
void navigationScr(_lv_obj_t *screen) {
  lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

  lv_obj_t * label;
  label = lv_label_create(screen);
  lv_obj_set_style_text_font(label, fontOptions, 0);
  lv_obj_set_style_text_color(label, lv_color_hex(0xAAAAAA), 0);
  lv_label_set_text_static(label, "Next maneuver");
  lv_obj_align(label, LV_ALIGN_TOP_MID, 0, 20);

  nameNav = lv_label_create(screen);
  lv_obj_set_style_text_font(nameNav, fontLargeMedium, 0);
  lv_obj_set_style_text_color(nameNav, lv_color_white(), 0);
  lv_obj_set_style_text_align(nameNav, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(nameNav, LV_LABEL_LONG_WRAP);
  lv_obj_set_width(nameNav, TFT_WIDTH - 32);
  lv_label_set_text_static(nameNav, "Waiting for instruction");
  lv_obj_align(nameNav, LV_ALIGN_TOP_MID, 0, 55);

  latNav = lv_label_create(screen);
  lv_obj_set_style_text_font(latNav, fontOptions, 0);
  lv_label_set_text_fmt(latNav, "%s", "");
  lv_obj_add_flag(latNav, LV_OBJ_FLAG_HIDDEN);
  
  lonNav = lv_label_create(screen);
  lv_obj_set_style_text_font(lonNav, fontOptions, 0);
  lv_label_set_text_fmt(lonNav, "%s", "");
  lv_obj_add_flag(lonNav, LV_OBJ_FLAG_HIDDEN);

  distNav = lv_label_create(screen);
  lv_obj_set_style_text_font(distNav, fontVeryLarge, 0);
  lv_obj_set_style_text_color(distNav, lv_color_white(), 0);
  lv_label_set_text_static(distNav, "--");
  lv_obj_align(distNav, LV_ALIGN_CENTER, 0, -35);

  arrowNav = lv_img_create(screen);
  lv_img_set_zoom(arrowNav, iconScale);
  lv_obj_update_layout(arrowNav);
  lv_obj_align(arrowNav, LV_ALIGN_CENTER, 0, 95);

  LV_IMG_DECLARE(navup);
  lv_img_set_src(arrowNav, &navup);
  lv_img_set_pivot(arrowNav, 50, 50);
}
#endif

#ifdef TDECK_ESP32S3
void navigationScr(_lv_obj_t *screen)
{
  lv_obj_t * label;
  label = lv_label_create(screen);
  lv_obj_set_style_text_font(label, fontOptions, 0);
  lv_label_set_text_static(label, "Navigation to:");
  lv_obj_center(label);
  lv_obj_align(label,LV_ALIGN_TOP_LEFT,10, 20);

  nameNav = lv_label_create(screen);
  lv_obj_set_style_text_font(nameNav, fontLargeMedium, 0);
  //lv_label_set_text_fmt(nameNav, "%s","");
  lv_label_set_long_mode(nameNav, LV_LABEL_LONG_SCROLL_CIRCULAR);
  lv_obj_set_width(nameNav,TFT_WIDTH-10);
  lv_obj_set_pos(nameNav,10, 37);

  label = lv_label_create(screen);
  lv_obj_set_style_text_font(label, fontOptions, 0);
  lv_label_set_text_static(label, "Lat:");
  lv_obj_set_pos(label, 10, 70);

  label = lv_label_create(screen);
  lv_obj_set_style_text_font(label, fontOptions, 0);
  lv_label_set_text_static(label, "Lon:");
  lv_obj_set_pos(label, 10, 90);

  latNav = lv_label_create(screen);
  lv_obj_set_style_text_font(latNav, fontOptions, 0);
  lv_label_set_text_fmt(latNav, "%s", "");
  lv_obj_set_pos(latNav, 60, 70);

  lonNav = lv_label_create(screen);
  lv_obj_set_style_text_font(lonNav, fontOptions, 0);
  lv_label_set_text_fmt(lonNav, "%s", "");
  lv_obj_set_pos(lonNav, 60, 90);

  label = lv_label_create(screen);
  lv_obj_set_style_text_font(label, fontOptions, 0);
  lv_label_set_text_static(label, "Distance");
  lv_obj_set_pos(label,10, 120);

  distNav = lv_label_create(screen);
  lv_obj_set_style_text_font(distNav, fontVeryLarge, 0);
  lv_label_set_text_fmt(distNav,"%d m.", 0);
  lv_obj_set_pos(distNav,10, 140);

  arrowNav = lv_img_create(screen);
  lv_obj_set_pos(arrowNav,TFT_WIDTH - 100, 35);

  LV_IMG_DECLARE(navup);
  lv_img_set_src(arrowNav, &navup);
  lv_img_set_pivot(arrowNav, 50, 50) ;
}
#endif
