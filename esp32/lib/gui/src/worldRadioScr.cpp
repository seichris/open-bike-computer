#include "worldRadioScr.hpp"
#include "worldRadioPresentation.hpp"
#include "worldRadioViewport.hpp"
#include "worldRadioRaster.hpp"
#include "worldRadioFlags.hpp"

#include "../../tft/tft.hpp"
#include "../../world_radio/world_radio_map.hpp"
#include "../../world_radio/world_radio_runtime.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <esp_heap_caps.h>

LV_FONT_DECLARE(worldRadioFont20);

namespace {

constexpr int16_t WORLD_WIDTH = world_radio_map::WIDTH;
constexpr int16_t WORLD_HEIGHT = world_radio_map::HEIGHT;
constexpr int MAP_SCALE = world_radio_viewport::SCALE;
constexpr uint32_t OCEAN_COLOR = 0x071421;
constexpr uint32_t ACCENT_COLOR = 0x8CF58A;

WorldRadioScreenCallbacks screenCallbacks{};
lv_obj_t *screenRoot = nullptr;
lv_obj_t *mapViewport = nullptr;
lv_obj_t *mapCanvas = nullptr;
uint16_t *viewportBuffer = nullptr;
uint32_t viewportStridePixels = 0;
lv_obj_t *stationLabel = nullptr;
lv_obj_t *stationBoldLabel = nullptr;
lv_obj_t *placeLabel = nullptr;
lv_obj_t *placeRow = nullptr;
lv_obj_t *flagCanvas = nullptr;
alignas(16) uint16_t flagBuffer[world_radio_flags::WIDTH * world_radio_flags::HEIGHT]{};
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
bool randomOnEntryPending = false;
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
  if (mapCanvas != nullptr && viewportBuffer != nullptr) {
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
    const uint32_t startedUs = micros();
#endif
    world_radio_raster::render(worldBuffer, WORLD_WIDTH, worldStridePixels,
        viewportBuffer, TFT_WIDTH, TFT_HEIGHT, viewportStridePixels,
        camera.x(), camera.y());
    lv_obj_invalidate(mapCanvas);
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
    static uint32_t frames = 0, totalUs = 0, maximumUs = 0;
    const uint32_t elapsedUs = micros() - startedUs;
    totalUs += elapsedUs;
    maximumUs = std::max(maximumUs, elapsedUs);
    if (++frames == 32) {
      Serial.printf("World Radio raster frames=32 averageUs=%lu maxUs=%lu\n",
                    static_cast<unsigned long>(totalUs / frames), static_cast<unsigned long>(maximumUs));
      frames = totalUs = maximumUs = 0;
    }
#endif
  }
}

void pulseReticle(void *object, int32_t diameter) {
  auto *ring = static_cast<lv_obj_t *>(object);
  lv_obj_set_size(ring, diameter, diameter);
  lv_obj_align(ring, LV_ALIGN_CENTER, 0, 0);
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
  pulseReticle(reticle, 42);
  if (pulse) {
    lv_anim_t animation;
    lv_anim_init(&animation);
    lv_anim_set_var(&animation, reticle);
    lv_anim_set_exec_cb(&animation, pulseReticle);
    lv_anim_set_values(&animation, 42, 14);
    lv_anim_set_duration(&animation, 1000);
    lv_anim_set_repeat_count(&animation, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&animation, lv_anim_path_ease_in_out);
    lv_anim_start(&animation);
  }
}

void setPlaceText(const char *text) {
  // Measure the original metadata, not LVGL's potentially dot-replaced text.
  // Content-sized DOT labels inside a content-sized flex row can collapse to
  // the ellipsis width and keep that width for subsequent station updates.
  lv_point_t measured{};
  lv_text_get_size(&measured, text, &worldRadioFont20, 0, 0,
                   LV_COORD_MAX, LV_TEXT_FLAG_NONE);
  lv_obj_set_width(placeLabel,
      world_radio_presentation::placeTextWidth(measured.x, TFT_WIDTH - 100));
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
    lv_obj_add_flag(flagCanvas, LV_OBJ_FLAG_HIDDEN);
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
  const auto *flag = status.hasStation ? world_radio_flags::find(status.countryCode) : nullptr;
  if (flag != nullptr) {
    std::memcpy(flagBuffer, flag, sizeof(flagBuffer));
    lv_obj_remove_flag(flagCanvas, LV_OBJ_FLAG_HIDDEN);
    lv_obj_invalidate(flagCanvas);
  } else {
    lv_obj_add_flag(flagCanvas, LV_OBJ_FLAG_HIDDEN);
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
        static_cast<unsigned>(command), static_cast<unsigned long>(request.requestId), sent);
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
    randomOnEntryPending = false;
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
    // Physical touch is calibrated at the driver; keep direct screen-space motion.
    camera.drag(dx, dy);
    lastX = point.x;
    lastY = point.y;
    updateMapPosition();
    break;
  }
  case LV_EVENT_RELEASED:
  case LV_EVENT_PRESS_LOST:
    if (!dragging) {
      break;
    }
    dragging = false;
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
    Serial.printf("World Radio map release start=%d,%d end=%d,%d dragged=%u\n",
                  pressX, pressY, point.x, point.y, dragStarted);
#endif
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

void styleMapLabel(lv_obj_t *label) {
  lv_obj_set_style_bg_opa(label, LV_OPA_TRANSP, 0);
  lv_obj_set_style_text_font(label, &worldRadioFont20, 0);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_width(label, TFT_WIDTH - 64);
  lv_label_set_long_mode(label, LV_LABEL_LONG_DOT);
  makePassive(label);
}

lv_obj_t *makeBottomControl(bool right, const char *icon, lv_event_cb_t callback) {
  using namespace world_radio_presentation;
  // Transparent hit areas reach the physical bottom/side edges. Only their
  // inset icon is painted, so the map remains visible underneath.
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
  lv_obj_set_style_text_color(label, lv_color_black(), 0);
  lv_obj_center(label);
  return button;
}

} // namespace

void worldRadioScr(lv_obj_t *screen,
                   const WorldRadioScreenCallbacks &callbacks) {
  screenRoot = screen;
  screenCallbacks = callbacks;
  const int mapHeight = TFT_HEIGHT;
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
  viewportStridePixels = lv_draw_buf_width_to_stride(TFT_WIDTH, LV_COLOR_FORMAT_RGB565) / sizeof(uint16_t);
  if (worldBuffer != nullptr) {
    viewportBuffer = static_cast<uint16_t *>(heap_caps_aligned_alloc(
        16, viewportStridePixels * TFT_HEIGHT * sizeof(uint16_t),
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  }
  if (viewportBuffer != nullptr) {
    mapCanvas = lv_canvas_create(mapViewport);
    lv_canvas_set_buffer(mapCanvas, viewportBuffer, TFT_WIDTH, TFT_HEIGHT, LV_COLOR_FORMAT_RGB565);
    makePassive(mapCanvas);
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

  stationLabel = lv_label_create(screenRoot);
  styleMapLabel(stationLabel);
  lv_obj_set_style_text_color(stationLabel, lv_color_black(), 0);
  lv_obj_align(stationLabel, LV_ALIGN_TOP_MID, 0, camera.anchorY() - 94);
  // One-pixel overprint emboldens the same multilingual glyphs without a
  // second full CJK font consuming another ~1.8 MiB of flash.
  stationBoldLabel = lv_label_create(screenRoot);
  styleMapLabel(stationBoldLabel);
  lv_obj_set_style_text_color(stationBoldLabel, lv_color_black(), 0);
  lv_obj_align(stationBoldLabel, LV_ALIGN_TOP_MID, 1, camera.anchorY() - 94);

  placeRow = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(placeRow);
  lv_obj_set_size(placeRow, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
  lv_obj_set_flex_flow(placeRow, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(placeRow, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(placeRow, 6, 0);
  lv_obj_align(placeRow, LV_ALIGN_TOP_MID, 0, camera.anchorY() - 66);
  makePassive(placeRow);
  flagCanvas = lv_canvas_create(placeRow);
  lv_canvas_set_buffer(flagCanvas, flagBuffer, world_radio_flags::WIDTH,
                       world_radio_flags::HEIGHT, LV_COLOR_FORMAT_RGB565);
  makePassive(flagCanvas);
  placeLabel = lv_label_create(placeRow);
  styleMapLabel(placeLabel);
  lv_obj_set_size(placeLabel, 1, worldRadioFont20.line_height);
  lv_obj_set_style_text_color(placeLabel, lv_color_hex(0x404040), 0);

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
  dragging = false;
  pendingStationFocus = 0;
  randomOnEntryPending = true;
  updateWorldRadioScr();
  renderStatus(true);
}
