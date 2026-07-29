/**
 * @file bikeIcon.cpp
 * @brief Reusable Lucide-style bicycle icon for firmware screens.
 */

#include "bikeIcon.hpp"

#include <algorithm>
#include <cstddef>

namespace bike_icon {
namespace {

// Lucide Bike's 24x24 geometry. Coordinates are doubled so the half-unit
// wheel centers stay precise without floating point. Source and license:
// https://lucide.dev/icons/bike, LICENSES/Lucide-ISC.txt
constexpr lv_point_precise_t BIKE_PATH_X2[] = {
    {24, 35}, {24, 28}, {18, 22}, {26, 16}, {30, 22}, {34, 22}};

int32_t scaledCoordinate(int32_t origin, int32_t inset, int32_t usableSize,
                         int32_t doubledCoordinate) {
  return origin + inset +
         (usableSize * doubledCoordinate + 24) / 48;
}

int32_t scaledLength(int32_t usableSize, int32_t doubledLength) {
  return std::max<int32_t>(1, (usableSize * doubledLength + 24) / 48);
}

void drawBikeIcon(lv_event_t *event) {
  if (lv_event_get_code(event) != LV_EVENT_DRAW_POST_END) {
    return;
  }

  lv_obj_t *icon = static_cast<lv_obj_t *>(lv_event_get_target(event));
  lv_layer_t *layer = lv_event_get_layer(event);
  lv_area_t bounds{};
  lv_obj_get_coords(icon, &bounds);
  const int32_t size =
      std::min(lv_area_get_width(&bounds), lv_area_get_height(&bounds));
  const int32_t strokeWidth = std::max<int32_t>(2, size / 12);
  const int32_t inset = strokeWidth / 2;
  const int32_t usableSize = std::max<int32_t>(1, size - 2 * inset);
  const lv_color_t color =
      lv_obj_get_style_text_color(icon, LV_PART_MAIN);

  lv_draw_arc_dsc_t wheel{};
  lv_draw_arc_dsc_init(&wheel);
  wheel.color = color;
  wheel.width = strokeWidth;
  wheel.start_angle = 0;
  wheel.end_angle = 360;
  wheel.rounded = true;
  wheel.radius = static_cast<uint16_t>(scaledLength(usableSize, 7));
  wheel.center.y = scaledCoordinate(bounds.y1, inset, usableSize, 35);
  wheel.center.x = scaledCoordinate(bounds.x1, inset, usableSize, 11);
  lv_draw_arc(layer, &wheel);
  wheel.center.x = scaledCoordinate(bounds.x1, inset, usableSize, 37);
  lv_draw_arc(layer, &wheel);

  lv_draw_line_dsc_t line{};
  lv_draw_line_dsc_init(&line);
  line.color = color;
  line.width = strokeWidth;
  line.round_start = true;
  line.round_end = true;
  for (std::size_t index = 1;
       index < sizeof(BIKE_PATH_X2) / sizeof(BIKE_PATH_X2[0]); ++index) {
    const lv_point_precise_t &from = BIKE_PATH_X2[index - 1];
    const lv_point_precise_t &to = BIKE_PATH_X2[index];
    line.p1 = {
        scaledCoordinate(bounds.x1, inset, usableSize, from.x),
        scaledCoordinate(bounds.y1, inset, usableSize, from.y),
    };
    line.p2 = {
        scaledCoordinate(bounds.x1, inset, usableSize, to.x),
        scaledCoordinate(bounds.y1, inset, usableSize, to.y),
    };
    lv_draw_line(layer, &line);
  }

  const int32_t headRadius = scaledLength(usableSize, 4);
  const int32_t headCenterX =
      scaledCoordinate(bounds.x1, inset, usableSize, 30);
  const int32_t headCenterY =
      scaledCoordinate(bounds.y1, inset, usableSize, 10);
  lv_draw_rect_dsc_t head{};
  lv_draw_rect_dsc_init(&head);
  head.bg_color = color;
  head.bg_opa = LV_OPA_COVER;
  head.radius = LV_RADIUS_CIRCLE;
  lv_area_t headBounds = {
      headCenterX - headRadius,
      headCenterY - headRadius,
      headCenterX + headRadius,
      headCenterY + headRadius,
  };
  lv_draw_rect(layer, &head, &headBounds);
}

} // namespace

lv_obj_t *create(lv_obj_t *parent, lv_coord_t size, uint32_t colorHex) {
  lv_obj_t *icon = lv_obj_create(parent);
  lv_obj_remove_style_all(icon);
  lv_obj_set_size(icon, size, size);
  lv_obj_set_style_text_color(icon, lv_color_hex(colorHex), 0);
  lv_obj_add_event_cb(icon, drawBikeIcon, LV_EVENT_DRAW_POST_END, nullptr);
  lv_obj_clear_flag(
      icon, static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_CLICKABLE |
                                       LV_OBJ_FLAG_SCROLLABLE));
  return icon;
}

} // namespace bike_icon
