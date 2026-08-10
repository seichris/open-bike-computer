#include "preConnectionIcons.hpp"

#include "../../bicino_style/bicino_visual_style.hpp"

namespace pre_connection_icons {
namespace {

lv_color_t color(uint32_t rgb) { return lv_color_hex(rgb); }

void makeTransparent(lv_obj_t *object) {
  lv_obj_set_style_bg_opa(object, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(object, 0, 0);
  lv_obj_set_style_pad_all(object, 0, 0);
  lv_obj_clear_flag(object, LV_OBJ_FLAG_SCROLLABLE);
}

lv_obj_t *shape(lv_obj_t *parent, int16_t x, int16_t y, int16_t width,
                int16_t height) {
  lv_obj_t *object = lv_obj_create(parent);
  lv_obj_set_pos(object, x, y);
  lv_obj_set_size(object, width, height);
  lv_obj_clear_flag(object, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_pad_all(object, 0, 0);
  return object;
}

lv_obj_t *circle(lv_obj_t *parent, int16_t x, int16_t y, int16_t diameter,
                 lv_color_t fill, lv_opa_t fillOpacity = LV_OPA_COVER) {
  lv_obj_t *object = shape(parent, x, y, diameter, diameter);
  lv_obj_set_style_radius(object, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_color(object, fill, 0);
  lv_obj_set_style_bg_opa(object, fillOpacity, 0);
  lv_obj_set_style_border_width(object, 0, 0);
  return object;
}

lv_obj_t *symbol(lv_obj_t *parent, const char *text, const lv_font_t *font,
                 lv_color_t textColor) {
  lv_obj_t *label = lv_label_create(parent);
  lv_obj_set_style_text_font(label, font, 0);
  lv_obj_set_style_text_color(label, textColor, 0);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(label, text);
  return label;
}

void addPhone(lv_obj_t *parent, int16_t x, lv_color_t stroke) {
  lv_obj_t *phone = shape(parent, x, 17, 50, 78);
  lv_obj_set_style_bg_opa(phone, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_color(phone, stroke, 0);
  lv_obj_set_style_border_width(phone, 5, 0);
  lv_obj_set_style_radius(phone, 11, 0);
  circle(phone, 20, 62, 6, stroke);
}

void addCheck(lv_obj_t *parent, int16_t x, int16_t y, int16_t diameter,
              const lv_font_t *font) {
  const lv_color_t success =
      color(bicino_visual_style::SUCCESS_GREEN_RGB888);
  lv_obj_t *ring = circle(parent, x, y, diameter, success, LV_OPA_TRANSP);
  lv_obj_set_style_border_color(ring, success, 0);
  lv_obj_set_style_border_width(ring, 5, 0);
  lv_obj_t *check = symbol(ring, LV_SYMBOL_OK, font, success);
  lv_obj_center(check);
}

void addLock(lv_obj_t *parent) {
  const lv_color_t blue =
      color(bicino_visual_style::NAVIGATION_BLUE_RGB888);
  lv_obj_t *shackle = shape(parent, 69, 25, 31, 35);
  lv_obj_set_style_bg_opa(shackle, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_color(shackle, blue, 0);
  lv_obj_set_style_border_width(shackle, 5, 0);
  lv_obj_set_style_radius(shackle, 16, 0);
  lv_obj_t *body = shape(parent, 60, 47, 49, 40);
  lv_obj_set_style_bg_color(body, blue, 0);
  lv_obj_set_style_bg_opa(body, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(body, 0, 0);
  lv_obj_set_style_radius(body, 8, 0);
  circle(body, 21, 13, 7, lv_color_black());
}

} // namespace

lv_obj_t *create(lv_obj_t *parent, Artwork artwork) {
  lv_obj_t *root = lv_obj_create(parent);
  lv_obj_set_size(root, 112, 112);
  makeTransparent(root);

  const lv_color_t blue =
      color(bicino_visual_style::NAVIGATION_BLUE_RGB888);
  const lv_color_t gray = color(bicino_visual_style::WAITING_GRAY_RGB888);
  switch (artwork) {
  case Artwork::PairingConfirmed:
    addCheck(root, 10, 10, 92, &lv_font_montserrat_48);
    break;
  case Artwork::WaitingForIPhone: {
    addPhone(root, 7, gray);
    lv_obj_t *wifi =
        symbol(root, LV_SYMBOL_WIFI, &lv_font_montserrat_42, blue);
    lv_obj_set_pos(wifi, 65, 34);
    break;
  }
  case Artwork::Connecting:
    addPhone(root, 3, blue);
    addLock(root);
    break;
  case Artwork::GettingLocation: {
    addCheck(root, 2, 25, 60, &lv_font_montserrat_24);
    lv_obj_t *dot = circle(root, 67, 38, 43, blue);
    lv_obj_set_style_border_color(dot, lv_color_white(), 0);
    lv_obj_set_style_border_width(dot, 5, 0);
    break;
  }
  }
  return root;
}

} // namespace pre_connection_icons
