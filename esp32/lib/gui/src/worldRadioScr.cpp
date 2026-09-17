#include "worldRadioScr.hpp"
#include "worldRadioGlobe.hpp"
#include "worldRadioPresentation.hpp"

#include "../../tft/tft.hpp"
#include "../../world_radio/world_radio_runtime.hpp"

#include <algorithm>
#include <array>
#include <cstdio>

namespace {

constexpr int16_t GLOBE_SIZE = 156;
constexpr uint32_t OCEAN_COLOR = 0x0A3555;
constexpr uint32_t LAND_COLOR = 0x6ECF75;
constexpr uint32_t GRID_COLOR = 0x75AFC9;
constexpr uint32_t ACCENT_COLOR = 0x8CF58A;

struct GlobeVertex {
  int8_t x;
  int8_t y;
};

// Deliberately low-detail continent silhouettes. They are rendered as LVGL
// geometry and replace the former 1024x512 embedded relief texture.
constexpr std::array<GlobeVertex, 11> NORTH_AMERICA{{
    {-42, -25}, {-34, -37}, {-18, -38}, {-7, -29}, {-12, -19},
    {-5, -12}, {-18, -8}, {-25, -15}, {-32, -10}, {-40, -17}, {-42, -25},
}};
constexpr std::array<GlobeVertex, 8> SOUTH_AMERICA{{
    {-20, -7}, {-7, -3}, {-3, 8}, {-9, 17}, {-10, 29}, {-17, 40},
    {-22, 23}, {-20, -7},
}};
constexpr std::array<GlobeVertex, 12> EURASIA{{
    {-4, -30}, {7, -39}, {24, -36}, {42, -26}, {45, -14}, {33, -10},
    {25, -17}, {15, -12}, {8, -19}, {0, -14}, {-8, -21}, {-4, -30},
}};
constexpr std::array<GlobeVertex, 8> AFRICA{{
    {0, -12}, {15, -13}, {24, -4}, {18, 16}, {9, 31}, {1, 20},
    {-5, 3}, {0, -12},
}};
constexpr std::array<GlobeVertex, 7> AUSTRALIA{{
    {27, 22}, {40, 18}, {46, 26}, {40, 35}, {29, 33}, {23, 27}, {27, 22},
}};

WorldRadioScreenCallbacks screenCallbacks{};
lv_obj_t *screenRoot = nullptr;
lv_obj_t *globe = nullptr;
lv_obj_t *stationLabel = nullptr;
lv_obj_t *stationBoldLabel = nullptr;
lv_obj_t *placeLabel = nullptr;
lv_obj_t *countryLabel = nullptr;
lv_obj_t *playLabel = nullptr;
lv_obj_t *reticle = nullptr;
lv_obj_t *reticleDot = nullptr;
bool reticlePulsing = false;
uint32_t renderedRevision = UINT32_MAX;
bool renderedPhoneReady = false;
int32_t centerLatitudeE7 = 200000000;
int32_t centerLongitudeE7 = 0;
uint32_t pendingStationFocus = 0;
uint32_t pendingStationFocusRevision = 0;
bool randomOnEntryPending = false;

lv_point_precise_t drawPoint(const lv_area_t &bounds, GlobeVertex vertex) {
  const int32_t centerX = (bounds.x1 + bounds.x2) / 2;
  const int32_t centerY = (bounds.y1 + bounds.y2) / 2;
  const int32_t radius = std::min(lv_area_get_width(&bounds),
                                  lv_area_get_height(&bounds)) /
                         2;
  return {centerX + radius * vertex.x / 50,
          centerY + radius * vertex.y / 50};
}

template <std::size_t N>
void fillPolygon(lv_layer_t *layer, const lv_area_t &bounds,
                 const std::array<GlobeVertex, N> &vertices,
                 lv_color_t color) {
  std::array<lv_point_precise_t, N> points{};
  lv_value_precise_t minimumY = bounds.y2;
  lv_value_precise_t maximumY = bounds.y1;
  for (std::size_t index = 0; index < N; ++index) {
    points[index] = drawPoint(bounds, vertices[index]);
    minimumY = std::min(minimumY, points[index].y);
    maximumY = std::max(maximumY, points[index].y);
  }

  lv_draw_line_dsc_t fill{};
  lv_draw_line_dsc_init(&fill);
  fill.color = color;
  fill.opa = LV_OPA_COVER;
  fill.width = 1;
  for (lv_value_precise_t y = minimumY; y <= maximumY; ++y) {
    std::array<lv_value_precise_t, N> intersections{};
    std::size_t count = 0;
    for (std::size_t index = 0; index < N; ++index) {
      const auto &start = points[index];
      const auto &end = points[(index + 1U) % N];
      if (!((start.y <= y && end.y > y) ||
            (end.y <= y && start.y > y))) {
        continue;
      }
      intersections[count++] = start.x +
          static_cast<int64_t>(end.x - start.x) * (y - start.y) /
              (end.y - start.y);
    }
    std::sort(intersections.begin(), intersections.begin() + count);
    for (std::size_t index = 1; index < count; index += 2U) {
      fill.p1 = {intersections[index - 1U], y};
      fill.p2 = {intersections[index], y};
      lv_draw_line(layer, &fill);
    }
  }
}

void drawGlobe(lv_event_t *event) {
  if (lv_event_get_code(event) != LV_EVENT_DRAW_POST_END) {
    return;
  }
  lv_obj_t *object = static_cast<lv_obj_t *>(lv_event_get_target(event));
  lv_layer_t *layer = lv_event_get_layer(event);
  lv_area_t bounds{};
  lv_obj_get_coords(object, &bounds);

  lv_draw_rect_dsc_t ocean{};
  lv_draw_rect_dsc_init(&ocean);
  ocean.bg_color = lv_color_hex(OCEAN_COLOR);
  ocean.bg_opa = LV_OPA_COVER;
  ocean.border_color = lv_color_hex(GRID_COLOR);
  ocean.border_opa = LV_OPA_COVER;
  ocean.border_width = 2;
  ocean.radius = LV_RADIUS_CIRCLE;
  lv_draw_rect(layer, &ocean, &bounds);

  fillPolygon(layer, bounds, NORTH_AMERICA, lv_color_hex(LAND_COLOR));
  fillPolygon(layer, bounds, SOUTH_AMERICA, lv_color_hex(LAND_COLOR));
  fillPolygon(layer, bounds, EURASIA, lv_color_hex(LAND_COLOR));
  fillPolygon(layer, bounds, AFRICA, lv_color_hex(LAND_COLOR));
  fillPolygon(layer, bounds, AUSTRALIA, lv_color_hex(LAND_COLOR));

  const int32_t centerX = (bounds.x1 + bounds.x2) / 2;
  const int32_t centerY = (bounds.y1 + bounds.y2) / 2;
  const int32_t radius = lv_area_get_width(&bounds) / 2;
  lv_draw_line_dsc_t grid{};
  lv_draw_line_dsc_init(&grid);
  grid.color = lv_color_hex(GRID_COLOR);
  grid.opa = LV_OPA_60;
  grid.width = 1;
  for (int32_t latitude : {-1, 0, 1}) {
    const int32_t y = centerY + latitude * radius / 3;
    const int32_t halfWidth = latitude == 0 ? radius - 3 : radius * 9 / 10;
    grid.p1 = {centerX - halfWidth, y};
    grid.p2 = {centerX + halfWidth, y};
    lv_draw_line(layer, &grid);
  }
  for (int32_t meridian : {-1, 0, 1}) {
    lv_point_precise_t previous{centerX, bounds.y1 + 3};
    for (int32_t step = 1; step <= 8; ++step) {
      const int32_t y = bounds.y1 + 3 + step * (2 * radius - 6) / 8;
      const int32_t distanceFromEquator = std::abs(y - centerY);
      const int32_t xOffset = meridian * radius / 2 *
                              (radius - distanceFromEquator) / radius;
      lv_point_precise_t next{centerX + xOffset, y};
      grid.p1 = previous;
      grid.p2 = next;
      lv_draw_line(layer, &grid);
      previous = next;
    }
  }
}

void positionReticle(int32_t diameter = -1) {
  if (reticle == nullptr) {
    return;
  }
  if (diameter < 0) {
    diameter = lv_obj_get_width(reticle);
  }
  const auto point = world_radio_globe::pointForCoordinate(
      centerLatitudeE7, centerLongitudeE7, GLOBE_SIZE);
  lv_obj_set_size(reticle, diameter, diameter);
  lv_obj_set_pos(reticle, point.x - diameter / 2, point.y - diameter / 2);
}

void pulseReticle(void *, int32_t diameter) { positionReticle(diameter); }

void updateReticle(world_radio_protocol::PlaybackState state, bool phoneReady) {
  using Appearance = world_radio_presentation::Reticle;
  const auto appearance = world_radio_presentation::reticleState(state, phoneReady);
  const auto color = lv_color_hex(appearance == Appearance::Gray ? 0x8A9298 : ACCENT_COLOR);
  lv_obj_set_style_border_color(reticle, color, 0);
  lv_obj_set_style_bg_color(reticleDot, color, 0);
  const bool pulse = appearance == Appearance::PulsingGreen;
  if (pulse == reticlePulsing) {
    positionReticle();
    return;
  }
  reticlePulsing = pulse;
  lv_anim_delete(reticle, pulseReticle);
  positionReticle(30);
  if (pulse) {
    lv_anim_t animation;
    lv_anim_init(&animation);
    lv_anim_set_var(&animation, reticle);
    lv_anim_set_exec_cb(&animation, pulseReticle);
    lv_anim_set_values(&animation, 30, 12);
    lv_anim_set_duration(&animation, 1000);
    lv_anim_set_repeat_count(&animation, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&animation, lv_anim_path_ease_in_out);
    lv_anim_start(&animation);
  }
}

void setPlaceText(const char *text) {
  lv_point_t measured{};
  lv_text_get_size(&measured, text, &lv_font_montserrat_18, 0, 0,
                   LV_COORD_MAX, LV_TEXT_FLAG_NONE);
  lv_obj_set_width(placeLabel,
      world_radio_presentation::placeTextWidth(measured.x, TFT_WIDTH - 116));
  lv_label_set_text(placeLabel, text);
}

void renderStatus(bool force = false) {
  const bool phoneReady =
      screenCallbacks.phoneReady != nullptr && screenCallbacks.phoneReady();
  const world_radio_runtime::Snapshot snapshot = world_radio_runtime::snapshot();
  if (!force && renderedRevision == snapshot.revision &&
      renderedPhoneReady == phoneReady) {
    return;
  }
  renderedRevision = snapshot.revision;
  renderedPhoneReady = phoneReady;
  updateReticle(snapshot.status.state, phoneReady);

  if (!phoneReady) {
    lv_label_set_text(stationLabel, "Connect iPhone");
    lv_label_set_text(stationBoldLabel, "Connect iPhone");
    setPlaceText("Open Bicino on your iPhone");
    lv_label_set_text(countryLabel, "");
    lv_label_set_text(playLabel, LV_SYMBOL_PLAY);
    return;
  }

  const world_radio_protocol::Status &status = snapshot.status;
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
  Serial.printf("World Radio status id=%lu state=%u country=%.2s station=%u/%u\n",
                static_cast<unsigned long>(status.requestId),
                static_cast<unsigned>(status.state), status.countryCode,
                static_cast<unsigned>(status.stationIndex),
                static_cast<unsigned>(status.stationCount));
#endif
  lv_label_set_text(stationLabel, world_radio_presentation::stationText(status));
  lv_label_set_text(stationBoldLabel, world_radio_presentation::stationText(status));
  setPlaceText(status.hasStation ? status.place : "");
  lv_label_set_text(countryLabel, status.hasStation ? status.countryCode : "");
  lv_label_set_text(playLabel,
                    world_radio_presentation::showPauseIcon(status.state)
                        ? LV_SYMBOL_PAUSE
                        : LV_SYMBOL_PLAY);

  if (pendingStationFocus != 0 &&
      pendingStationFocus == status.requestId &&
      pendingStationFocusRevision != snapshot.revision && status.hasStation &&
      world_radio_protocol::validCoordinate(status.stationLatitudeE7,
                                            status.stationLongitudeE7)) {
    pendingStationFocus = 0;
    centerLatitudeE7 = status.stationLatitudeE7;
    centerLongitudeE7 = status.stationLongitudeE7;
    positionReticle();
  }
}

bool sendCommand(world_radio_protocol::Command command) {
  randomOnEntryPending = false;
  world_radio_protocol::Request request{};
  request.command = command;
  request.requestId = world_radio_runtime::nextRequestId();
  request.latitudeE7 = centerLatitudeE7;
  request.longitudeE7 = centerLongitudeE7;
  const bool sent = screenCallbacks.sendRequest != nullptr &&
                    screenCallbacks.sendRequest(request);
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
  Serial.printf("World Radio request command=%u id=%lu sent=%u\n",
                static_cast<unsigned>(command),
                static_cast<unsigned long>(request.requestId), sent);
#endif
  if (sent) {
    world_radio_runtime::noteRequest(request);
  } else {
    world_radio_runtime::noteTransportUnavailable(request);
  }
  renderStatus(true);
  if (sent && (command == world_radio_protocol::Command::RandomStation ||
               command == world_radio_protocol::Command::PreviousStation ||
               command == world_radio_protocol::Command::NextStation)) {
    pendingStationFocus = request.requestId;
    pendingStationFocusRevision = renderedRevision;
  }
  return sent;
}

void globeEvent(lv_event_t *event) {
  if (lv_event_get_code(event) != LV_EVENT_CLICKED) {
    return;
  }
  if (screenCallbacks.tapToSwitchScreens != nullptr &&
      screenCallbacks.tapToSwitchScreens() &&
      screenCallbacks.cycleScreen != nullptr) {
    screenCallbacks.cycleScreen();
    return;
  }
  lv_indev_t *indev = lv_event_get_indev(event);
  if (indev == nullptr) {
    return;
  }
  lv_point_t point{};
  lv_area_t bounds{};
  lv_indev_get_point(indev, &point);
  lv_obj_get_coords(globe, &bounds);
  world_radio_globe::Coordinate coordinate{};
  if (!world_radio_globe::coordinateForPoint(
          point.x - bounds.x1, point.y - bounds.y1, GLOBE_SIZE, coordinate)) {
    return;
  }
  centerLatitudeE7 = coordinate.latitudeE7;
  centerLongitudeE7 = coordinate.longitudeE7;
  positionReticle();
  sendCommand(world_radio_protocol::Command::SelectLocation);
}

void randomEvent(lv_event_t *event) {
  if (lv_event_get_code(event) == LV_EVENT_CLICKED) {
    sendCommand(world_radio_protocol::Command::RandomStation);
  }
}

void playEvent(lv_event_t *event) {
  if (lv_event_get_code(event) == LV_EVENT_CLICKED) {
    sendCommand(world_radio_protocol::Command::PlayPause);
  }
}

void cycleEvent(lv_event_t *event) {
  if (lv_event_get_code(event) == LV_EVENT_CLICKED &&
      screenCallbacks.cycleScreen != nullptr) {
    screenCallbacks.cycleScreen();
  }
}

lv_obj_t *makeButton(lv_obj_t *parent, int16_t width, int16_t height,
                     const char *text, lv_event_cb_t callback) {
  lv_obj_t *button = lv_btn_create(parent);
  lv_obj_set_size(button, width, height);
  lv_obj_set_style_radius(button, height / 2, 0);
  lv_obj_set_style_bg_color(button, lv_color_hex(0x15201B), 0);
  lv_obj_set_style_bg_opa(button, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(button, 1, 0);
  lv_obj_set_style_border_color(button, lv_color_hex(0x48725D), 0);
  lv_obj_clear_flag(button, LV_OBJ_FLAG_EVENT_BUBBLE);
  lv_obj_add_event_cb(button, callback, LV_EVENT_CLICKED, nullptr);
  lv_obj_t *label = lv_label_create(button);
  lv_obj_set_style_text_color(label, lv_color_white(), 0);
  lv_obj_set_style_text_font(label, &lv_font_montserrat_14, 0);
  lv_label_set_text_static(label, text);
  lv_obj_center(label);
  return button;
}

void makePassive(lv_obj_t *object) {
  lv_obj_clear_flag(object, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(object, LV_OBJ_FLAG_SCROLLABLE);
}

void styleMetadataLabel(lv_obj_t *label) {
  lv_obj_set_style_bg_opa(label, LV_OPA_TRANSP, 0);
  lv_obj_set_style_text_font(label, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_width(label, TFT_WIDTH - 64);
  lv_label_set_long_mode(label, LV_LABEL_LONG_DOT);
  makePassive(label);
}

lv_obj_t *makeBottomControl(bool right, const char *icon, lv_event_cb_t callback) {
  using namespace world_radio_presentation;
  lv_obj_t *target = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(target);
  lv_obj_set_size(target, TFT_WIDTH / 2, CONTROL_HIT_HEIGHT);
  lv_obj_align(target, right ? LV_ALIGN_BOTTOM_RIGHT : LV_ALIGN_BOTTOM_LEFT, 0, 0);
  lv_obj_add_flag(target, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(target, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_event_cb(target, callback, LV_EVENT_CLICKED, nullptr);
  lv_obj_t *button = makeButton(target, CONTROL_ICON_SIZE, CONTROL_ICON_SIZE, icon, callback);
  lv_obj_remove_style_all(button);
  lv_obj_set_size(button, CONTROL_ICON_SIZE, CONTROL_ICON_SIZE);
  lv_obj_align(button, LV_ALIGN_BOTTOM_MID, 0, -CONTROL_ICON_BOTTOM);
  lv_obj_t *label = lv_obj_get_child(button, 0);
  lv_obj_set_style_text_font(label, &lv_font_montserrat_32, 0);
  lv_obj_set_style_text_color(label, lv_color_white(), 0);
  lv_obj_center(label);
  return button;
}

} // namespace

void worldRadioScr(lv_obj_t *screen,
                   const WorldRadioScreenCallbacks &callbacks) {
  screenRoot = screen;
  screenCallbacks = callbacks;
  pendingStationFocus = 0;
  lv_obj_set_style_bg_color(screenRoot, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screenRoot, LV_OPA_COVER, 0);
  lv_obj_clear_flag(screenRoot, LV_OBJ_FLAG_SCROLLABLE);

  lv_obj_t *cycleButton = makeButton(screenRoot, 54, 42, "NEXT", cycleEvent);
  lv_obj_align(cycleButton, LV_ALIGN_TOP_LEFT, 18, 12);

  stationLabel = lv_label_create(screenRoot);
  styleMetadataLabel(stationLabel);
  lv_obj_set_style_text_color(stationLabel, lv_color_white(), 0);
  lv_obj_align(stationLabel, LV_ALIGN_TOP_MID, 0, 76);
  stationBoldLabel = lv_label_create(screenRoot);
  styleMetadataLabel(stationBoldLabel);
  lv_obj_set_style_text_color(stationBoldLabel, lv_color_white(), 0);
  lv_obj_align(stationBoldLabel, LV_ALIGN_TOP_MID, 1, 76);

  globe = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(globe);
  lv_obj_set_size(globe, GLOBE_SIZE, GLOBE_SIZE);
  lv_obj_align(globe, LV_ALIGN_CENTER, 0, -6);
  lv_obj_add_flag(globe, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(globe, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_event_cb(globe, drawGlobe, LV_EVENT_DRAW_POST_END, nullptr);
  lv_obj_add_event_cb(globe, globeEvent, LV_EVENT_CLICKED, nullptr);

  reticlePulsing = false;
  reticle = lv_obj_create(globe);
  lv_obj_remove_style_all(reticle);
  lv_obj_set_size(reticle, 30, 30);
  lv_obj_set_style_radius(reticle, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(reticle, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(reticle, 3, 0);
  lv_obj_set_style_border_color(reticle, lv_color_hex(ACCENT_COLOR), 0);
  lv_obj_set_style_shadow_color(reticle, lv_color_black(), 0);
  lv_obj_set_style_shadow_width(reticle, 4, 0);
  lv_obj_set_style_shadow_opa(reticle, LV_OPA_COVER, 0);
  makePassive(reticle);
  reticleDot = lv_obj_create(reticle);
  lv_obj_remove_style_all(reticleDot);
  lv_obj_set_size(reticleDot, 7, 7);
  lv_obj_set_style_radius(reticleDot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_color(reticleDot, lv_color_hex(ACCENT_COLOR), 0);
  lv_obj_set_style_bg_opa(reticleDot, LV_OPA_COVER, 0);
  lv_obj_center(reticleDot);
  makePassive(reticleDot);
  positionReticle();

  lv_obj_t *placeRow = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(placeRow);
  lv_obj_set_size(placeRow, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
  lv_obj_set_flex_flow(placeRow, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(placeRow, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER,
                        LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(placeRow, 8, 0);
  lv_obj_align(placeRow, LV_ALIGN_CENTER, 0, GLOBE_SIZE / 2 + 24);
  makePassive(placeRow);
  countryLabel = lv_label_create(placeRow);
  lv_obj_set_style_text_font(countryLabel, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_color(countryLabel, lv_color_hex(ACCENT_COLOR), 0);
  lv_obj_set_width(countryLabel, 22);
  lv_obj_set_style_text_align(countryLabel, LV_TEXT_ALIGN_CENTER, 0);
  makePassive(countryLabel);
  placeLabel = lv_label_create(placeRow);
  styleMetadataLabel(placeLabel);
  lv_obj_set_size(placeLabel, 1, lv_font_montserrat_18.line_height);
  lv_obj_set_style_text_color(placeLabel, lv_color_hex(0xB8C0C5), 0);

  makeBottomControl(false, LV_SYMBOL_SHUFFLE, randomEvent);
  lv_obj_t *playButton = makeBottomControl(true, LV_SYMBOL_PLAY, playEvent);
  playLabel = lv_obj_get_child(playButton, 0);

  renderedRevision = UINT32_MAX;
  renderStatus(true);
}

void updateWorldRadioScr() {
  if (randomOnEntryPending && screenCallbacks.phoneReady != nullptr &&
      screenCallbacks.phoneReady()) {
    sendCommand(world_radio_protocol::Command::RandomStation);
  }
  renderStatus();
}

void activateWorldRadioScr() {
  pendingStationFocus = 0;
  randomOnEntryPending = true;
  updateWorldRadioScr();
  renderStatus(true);
}
