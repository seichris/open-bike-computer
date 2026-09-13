#include "worldRadioScr.hpp"
#include "worldRadioPresentation.hpp"
#include "worldRadioViewport.hpp"

#include "../../tft/tft.hpp"
#include "../../world_radio/world_radio_map.hpp"
#include "../../world_radio/world_radio_runtime.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <esp_heap_caps.h>

namespace {

constexpr int16_t WORLD_WIDTH = world_radio_map::WIDTH;
constexpr int16_t WORLD_HEIGHT = world_radio_map::HEIGHT;
constexpr int MAP_SCALE = world_radio_viewport::SCALE;
constexpr uint32_t OCEAN_COLOR = 0x071421;
constexpr uint32_t ACCENT_COLOR = 0x8CF58A;
constexpr uint32_t PANEL_COLOR = 0x050708;

WorldRadioScreenCallbacks screenCallbacks{};
lv_obj_t *screenRoot = nullptr;
lv_obj_t *mapViewport = nullptr;
lv_obj_t *mapCanvases[3]{};
lv_obj_t *coordinateLabel = nullptr;
lv_obj_t *stationLabel = nullptr;
lv_obj_t *placeLabel = nullptr;
lv_obj_t *stateLabel = nullptr;
lv_obj_t *indexLabel = nullptr;
lv_obj_t *playLabel = nullptr;
lv_obj_t *reticle = nullptr;
lv_obj_t *reticleDot = nullptr;
bool reticlePulsing = false;
uint16_t *worldBuffer = nullptr;
uint32_t worldStridePixels = 0;
uint32_t renderedRevision = UINT32_MAX;
bool renderedPhoneReady = false;
int32_t centerLatitudeE7 = 200000000;
int32_t centerLongitudeE7 = 0;
world_radio_viewport::Camera camera;
uint32_t pendingStationFocus = 0;
uint32_t pendingStationFocusRevision = 0;
bool dragging = false;
bool dragStarted = false;
int16_t pressX = 0;
int16_t pressY = 0;
int16_t lastX = 0;
int16_t lastY = 0;

void updateMapPosition() {
  if (mapViewport == nullptr) {
    return;
  }
  centerLatitudeE7 = camera.latitude();
  centerLongitudeE7 = camera.longitude();
  for (int index = 0; index < 3; ++index) {
    if (mapCanvases[index] != nullptr) {
      lv_obj_set_pos(mapCanvases[index],
                     camera.x() + (index - 1) * WORLD_WIDTH * MAP_SCALE,
                     camera.y());
    }
  }
}

void formatCoordinate(char *output, std::size_t capacity) {
  auto tenths = [](int32_t value) {
    const int64_t magnitude = value < 0 ? -static_cast<int64_t>(value) : value;
    return static_cast<int32_t>((magnitude + 500000) / 1000000);
  };
  const int32_t latitudeTenths = tenths(centerLatitudeE7);
  const int32_t longitudeTenths = tenths(centerLongitudeE7);
  std::snprintf(output, capacity, "%ld.%ld %c  %ld.%ld %c",
                static_cast<long>(latitudeTenths / 10),
                static_cast<long>(latitudeTenths % 10),
                centerLatitudeE7 < 0 ? 'S' : 'N',
                static_cast<long>(longitudeTenths / 10),
                static_cast<long>(longitudeTenths % 10),
                centerLongitudeE7 < 0 ? 'W' : 'E');
}

void updateCoordinateLabel() {
  if (coordinateLabel == nullptr) {
    return;
  }
  char coordinate[48];
  formatCoordinate(coordinate, sizeof(coordinate));
  lv_label_set_text(coordinateLabel, coordinate);
}

void pulseReticle(void *object, int32_t opacity) {
  lv_obj_set_style_border_opa(static_cast<lv_obj_t *>(object), opacity, 0);
}

void updateReticle(world_radio_protocol::PlaybackState state, bool phoneReady) {
  using Appearance = world_radio_presentation::Reticle;
  const auto appearance = world_radio_presentation::reticleState(state, phoneReady);
  const auto color = lv_color_hex(appearance == Appearance::Gray ? 0x8A9298 : ACCENT_COLOR);
  lv_obj_set_style_border_color(reticle, color, 0);
  lv_obj_set_style_bg_color(reticleDot, color, 0);
  const bool pulse = appearance == Appearance::PulsingGreen;
  if (pulse == reticlePulsing) return;
  reticlePulsing = pulse;
  lv_anim_delete(reticle, pulseReticle);
  lv_obj_set_style_border_opa(reticle, LV_OPA_COVER, 0);
  if (pulse) {
    lv_anim_t animation;
    lv_anim_init(&animation);
    lv_anim_set_var(&animation, reticle);
    lv_anim_set_exec_cb(&animation, pulseReticle);
    lv_anim_set_values(&animation, LV_OPA_COVER, LV_OPA_30);
    lv_anim_set_duration(&animation, 700);
    lv_anim_set_playback_duration(&animation, 700);
    lv_anim_set_repeat_count(&animation, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&animation, lv_anim_path_ease_in_out);
    lv_anim_start(&animation);
  }
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
    lv_label_set_text(placeLabel, "Open Bicino on your iPhone");
    lv_label_set_text(stateLabel, "");
    lv_label_set_text(indexLabel, "");
    lv_label_set_text(playLabel, LV_SYMBOL_PLAY);
    updateCoordinateLabel();
    return;
  }

  const world_radio_protocol::Status &status = snapshot.status;
  lv_label_set_text(stationLabel,
                    status.hasStation && status.stationName[0] != '\0'
                        ? status.stationName
                        : "Choose a place");
  char place[72]{};
  if (status.hasStation) {
    if (status.place[0] != '\0' && status.countryCode[0] != '\0') {
      std::snprintf(place, sizeof(place), "%s  %s", status.place,
                    status.countryCode);
    } else if (status.place[0] != '\0') {
      std::snprintf(place, sizeof(place), "%s", status.place);
    } else {
      std::snprintf(place, sizeof(place), "%s", status.countryCode);
    }
    lv_label_set_text(placeLabel, place);
  } else {
    char coordinate[48];
    formatCoordinate(coordinate, sizeof(coordinate));
    lv_label_set_text(placeLabel, coordinate);
  }
  lv_label_set_text(stateLabel, world_radio_presentation::statusText(status));
  if (status.stationCount > 0) {
    char index[20];
    std::snprintf(index, sizeof(index), "%u / %u",
                  static_cast<unsigned>(status.stationIndex + 1),
                  static_cast<unsigned>(status.stationCount));
    lv_label_set_text(indexLabel, index);
  } else {
    lv_label_set_text(indexLabel, "");
  }
  lv_label_set_text(playLabel,
                    world_radio_presentation::showPauseIcon(status.state)
                        ? LV_SYMBOL_PAUSE
                        : LV_SYMBOL_PLAY);

  if (world_radio_viewport::mayFocusStation(
          dragging, pendingStationFocus, pendingStationFocusRevision,
          status.requestId, snapshot.revision) && status.hasStation &&
      (status.state == world_radio_protocol::PlaybackState::Connecting ||
       status.state == world_radio_protocol::PlaybackState::Buffering ||
       status.state == world_radio_protocol::PlaybackState::Playing) &&
      world_radio_protocol::validCoordinate(status.stationLatitudeE7,
                                            status.stationLongitudeE7)) {
    pendingStationFocus = 0;
    camera.centerOn(status.stationLatitudeE7, status.stationLongitudeE7);
    updateMapPosition();
    updateCoordinateLabel();
  }
}

bool sendCommand(world_radio_protocol::Command command) {
  world_radio_protocol::Request request{};
  request.command = command;
  request.requestId = world_radio_runtime::nextRequestId();
  request.latitudeE7 = centerLatitudeE7;
  request.longitudeE7 = centerLongitudeE7;
  const bool sent = screenCallbacks.sendRequest != nullptr &&
                    screenCallbacks.sendRequest(request);
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

void mapEvent(lv_event_t *event) {
  const lv_event_code_t code = lv_event_get_code(event);
  lv_indev_t *indev = lv_event_get_indev(event);
  if (indev == nullptr) {
    return;
  }
  lv_point_t point{};
  lv_indev_get_point(indev, &point);
  switch (code) {
  case LV_EVENT_PRESSED:
    pendingStationFocus = 0;
    dragging = true;
    dragStarted = false;
    pressX = lastX = point.x;
    pressY = lastY = point.y;
    break;
  case LV_EVENT_PRESSING: {
    if (!dragging) {
      break;
    }
    const int16_t dx = point.x - lastX;
    const int16_t dy = point.y - lastY;
    if (std::abs(point.x - pressX) + std::abs(point.y - pressY) >= 10) {
      dragStarted = true;
    }
    // Screen-space deltas move the map in the finger's direction, exactly 1:1.
    camera.pan(dx, dy);
    lastX = point.x;
    lastY = point.y;
    updateMapPosition();
    updateCoordinateLabel();
    break;
  }
  case LV_EVENT_RELEASED:
  case LV_EVENT_PRESS_LOST:
    if (!dragging) {
      break;
    }
    dragging = false;
    if (!dragStarted && screenCallbacks.tapToSwitchScreens != nullptr &&
        screenCallbacks.tapToSwitchScreens() &&
        screenCallbacks.cycleScreen != nullptr) {
      screenCallbacks.cycleScreen();
      break;
    }
    sendCommand(world_radio_protocol::Command::SelectLocation);
    break;
  default:
    break;
  }
}

void randomEvent(lv_event_t *event) {
  if (lv_event_get_code(event) == LV_EVENT_CLICKED) {
    sendCommand(world_radio_protocol::Command::RandomStation);
  }
}

void previousEvent(lv_event_t *event) {
  if (lv_event_get_code(event) == LV_EVENT_CLICKED) {
    sendCommand(world_radio_protocol::Command::PreviousStation);
  }
}

void playEvent(lv_event_t *event) {
  if (lv_event_get_code(event) == LV_EVENT_CLICKED) {
    sendCommand(world_radio_protocol::Command::PlayPause);
  }
}

void nextEvent(lv_event_t *event) {
  if (lv_event_get_code(event) == LV_EVENT_CLICKED) {
    sendCommand(world_radio_protocol::Command::NextStation);
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

void styleMapLabel(lv_obj_t *label) {
  // Readable over pale terrain, deserts and polar ice without dimming the map.
  lv_obj_set_style_bg_color(label, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(label, 190, 0);
  lv_obj_set_style_pad_hor(label, 8, 0);
  lv_obj_set_style_pad_ver(label, 3, 0);
  lv_obj_set_style_radius(label, 6, 0);
}

} // namespace

void worldRadioScr(lv_obj_t *screen,
                   const WorldRadioScreenCallbacks &callbacks) {
  screenRoot = screen;
  screenCallbacks = callbacks;
  const int mapHeight = TFT_HEIGHT - world_radio_presentation::PANEL_HEIGHT;
  camera.configure(TFT_WIDTH, mapHeight, WORLD_WIDTH * MAP_SCALE,
                    WORLD_HEIGHT * MAP_SCALE);
  pendingStationFocus = 0;
  lv_obj_set_style_bg_color(screenRoot, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screenRoot, LV_OPA_COVER, 0);
  lv_obj_clear_flag(screenRoot, LV_OBJ_FLAG_SCROLLABLE);

  mapViewport = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(mapViewport);
  lv_obj_set_size(mapViewport, TFT_WIDTH, mapHeight);
  lv_obj_set_pos(mapViewport, 0, 0);
  lv_obj_set_style_bg_color(mapViewport, lv_color_hex(OCEAN_COLOR), 0);
  lv_obj_set_style_bg_opa(mapViewport, LV_OPA_COVER, 0);
  lv_obj_add_flag(mapViewport, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(mapViewport, LV_OBJ_FLAG_PRESS_LOCK);
  lv_obj_clear_flag(mapViewport, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_event_cb(mapViewport, mapEvent, LV_EVENT_ALL, nullptr);

  worldStridePixels =
      lv_draw_buf_width_to_stride(WORLD_WIDTH, LV_COLOR_FORMAT_RGB565) /
      sizeof(uint16_t);
  const std::size_t worldBytes =
      static_cast<std::size_t>(worldStridePixels) * WORLD_HEIGHT *
      sizeof(uint16_t);
  worldBuffer = static_cast<uint16_t *>(heap_caps_aligned_alloc(
      16, worldBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (worldBuffer != nullptr &&
      !world_radio_map::render(worldBuffer, worldBytes / sizeof(uint16_t),
                               worldStridePixels)) {
    heap_caps_free(worldBuffer);
    worldBuffer = nullptr;
  }
  if (worldBuffer != nullptr) {
    for (int index = 0; index < 3; ++index) {
      mapCanvases[index] = lv_canvas_create(mapViewport);
      lv_canvas_set_buffer(mapCanvases[index], worldBuffer, WORLD_WIDTH,
                           WORLD_HEIGHT, LV_COLOR_FORMAT_RGB565);
      lv_image_set_pivot(mapCanvases[index], 0, 0);
      lv_image_set_scale(mapCanvases[index], LV_SCALE_NONE * MAP_SCALE);
      makePassive(mapCanvases[index]);
    }
    updateMapPosition();
  } else {
    lv_obj_t *failure = lv_label_create(mapViewport);
    lv_obj_set_style_text_color(failure, lv_color_hex(0xF6B73C), 0);
    lv_obj_set_style_text_font(failure, &lv_font_montserrat_18, 0);
    lv_label_set_text_static(failure, "World map unavailable");
    lv_obj_align(failure, LV_ALIGN_CENTER, 0, -40);
  }

  lv_obj_t *cycleButton = makeButton(screenRoot, 54, 42, "NEXT", cycleEvent);
  lv_obj_align(cycleButton, LV_ALIGN_TOP_LEFT, 18, 12);
  lv_obj_t *randomButton =
      makeButton(screenRoot, 64, 42, "RANDOM", randomEvent);
  lv_obj_align(randomButton, LV_ALIGN_TOP_RIGHT, -18, 12);

  coordinateLabel = lv_label_create(screenRoot);
  styleMapLabel(coordinateLabel);
  lv_obj_set_style_text_color(coordinateLabel, lv_color_hex(0xBDD5CB), 0);
  lv_obj_set_style_text_font(coordinateLabel, &lv_font_montserrat_14, 0);
  lv_obj_align(coordinateLabel, LV_ALIGN_TOP_MID, 0, camera.anchorY() - 53);
  makePassive(coordinateLabel);
  updateCoordinateLabel();

  reticlePulsing = false;
  reticle = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(reticle);
  lv_obj_set_size(reticle, 42, 42);
  lv_obj_set_style_radius(reticle, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(reticle, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(reticle, 3, 0);
  lv_obj_set_style_border_color(reticle, lv_color_hex(ACCENT_COLOR), 0);
  lv_obj_set_style_shadow_color(reticle, lv_color_black(), 0);
  lv_obj_set_style_shadow_width(reticle, 5, 0);
  lv_obj_set_style_shadow_opa(reticle, LV_OPA_COVER, 0);
  lv_obj_align(reticle, LV_ALIGN_TOP_MID, 0, camera.anchorY() - 21);
  makePassive(reticle);
  reticleDot = lv_obj_create(reticle);
  lv_obj_remove_style_all(reticleDot);
  lv_obj_set_size(reticleDot, 8, 8);
  lv_obj_set_style_radius(reticleDot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_color(reticleDot, lv_color_hex(ACCENT_COLOR), 0);
  lv_obj_set_style_bg_opa(reticleDot, LV_OPA_COVER, 0);
  lv_obj_center(reticleDot);
  makePassive(reticleDot);

  lv_obj_t *panel = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(panel);
  lv_obj_set_size(panel, TFT_WIDTH, world_radio_presentation::PANEL_HEIGHT);
  lv_obj_align(panel, LV_ALIGN_BOTTOM_MID, 0, 0);
  lv_obj_set_style_bg_color(panel, lv_color_hex(PANEL_COLOR), 0);
  lv_obj_set_style_bg_opa(panel, 238, 0);
  lv_obj_set_style_pad_top(panel, 10, 0);
  lv_obj_clear_flag(panel, LV_OBJ_FLAG_SCROLLABLE);

  stationLabel = lv_label_create(panel);
  lv_obj_set_width(stationLabel, TFT_WIDTH - 56);
  lv_obj_set_style_text_color(stationLabel, lv_color_white(), 0);
  lv_obj_set_style_text_font(stationLabel, &lv_font_montserrat_24, 0);
  lv_obj_set_style_text_align(stationLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(stationLabel, LV_LABEL_LONG_DOT);
  lv_obj_align(stationLabel, LV_ALIGN_TOP_MID, 0, 5);

  placeLabel = lv_label_create(panel);
  lv_obj_set_width(placeLabel, TFT_WIDTH - 60);
  lv_obj_set_style_text_color(placeLabel, lv_color_hex(0xBDD5CB), 0);
  lv_obj_set_style_text_font(placeLabel, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_align(placeLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(placeLabel, LV_LABEL_LONG_DOT);
  lv_obj_align(placeLabel, LV_ALIGN_TOP_MID, 0, 38);

  stateLabel = lv_label_create(panel);
  lv_obj_set_width(stateLabel, TFT_WIDTH - 60);
  lv_obj_set_style_text_color(stateLabel, lv_color_hex(ACCENT_COLOR), 0);
  lv_obj_set_style_text_font(stateLabel, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_align(stateLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(stateLabel, LV_LABEL_LONG_DOT);
  lv_obj_align(stateLabel, LV_ALIGN_TOP_MID, 0, 59);

  using namespace world_radio_presentation;
  lv_obj_t *previousButton = makeButton(
      panel, SIDE_CONTROL_WIDTH, CONTROL_HEIGHT, LV_SYMBOL_PREV, previousEvent);
  lv_obj_align(previousButton, LV_ALIGN_BOTTOM_MID, -SIDE_CONTROL_OFFSET,
               -CONTROL_BOTTOM_INSET);
  lv_obj_t *playButton = makeButton(
      panel, PLAY_CONTROL_WIDTH, CONTROL_HEIGHT, LV_SYMBOL_PLAY, playEvent);
  lv_obj_align(playButton, LV_ALIGN_BOTTOM_MID, 0, -CONTROL_BOTTOM_INSET);
  playLabel = lv_obj_get_child(playButton, 0);
  lv_obj_t *nextButton = makeButton(
      panel, SIDE_CONTROL_WIDTH, CONTROL_HEIGHT, LV_SYMBOL_NEXT, nextEvent);
  lv_obj_align(nextButton, LV_ALIGN_BOTTOM_MID, SIDE_CONTROL_OFFSET,
               -CONTROL_BOTTOM_INSET);
  for (lv_obj_t *button : {previousButton, playButton, nextButton}) {
    lv_obj_set_style_text_font(lv_obj_get_child(button, 0),
                               &lv_font_montserrat_24, 0);
  }

  indexLabel = lv_label_create(panel);
  lv_obj_set_style_text_color(indexLabel, lv_color_hex(0x7D958B), 0);
  lv_obj_set_style_text_font(indexLabel, &lv_font_montserrat_14, 0);
  lv_obj_align(indexLabel, LV_ALIGN_BOTTOM_MID, 0, -19);
  makePassive(indexLabel);

  renderedRevision = UINT32_MAX;
  renderStatus(true);
}

void updateWorldRadioScr() { renderStatus(); }

void activateWorldRadioScr() { renderStatus(true); }
