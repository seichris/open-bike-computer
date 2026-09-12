#include "worldRadioScr.hpp"

#include "../../bicino_style/bicino_visual_style.hpp"
#include "../../tft/tft.hpp"
#include "../../world_radio/world_radio_runtime.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <esp_heap_caps.h>

namespace {

constexpr int16_t WORLD_WIDTH = 720;
constexpr int16_t WORLD_HEIGHT = 360;
constexpr int32_t LATITUDE_LIMIT_E7 = 850000000;
constexpr int32_t LONGITUDE_HALF_E7 = 1800000000;
constexpr int64_t LONGITUDE_FULL_E7 = 3600000000LL;
constexpr uint32_t OCEAN_COLOR = 0x071421;
constexpr uint32_t GRID_COLOR = 0x173049;
constexpr uint32_t LAND_COLOR = 0x17453B;
constexpr uint32_t COAST_COLOR = 0x63E6BE;
constexpr uint32_t ACCENT_COLOR = 0x8CF58A;
constexpr uint32_t PANEL_COLOR = 0x050708;

struct GeoPoint {
  int16_t longitude;
  int16_t latitude;
};

struct PixelPoint {
  int16_t x;
  int16_t y;
};

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
uint16_t *worldBuffer = nullptr;
uint32_t worldStridePixels = 0;
uint32_t renderedRevision = UINT32_MAX;
bool renderedPhoneReady = false;
int32_t centerLatitudeE7 = 200000000;
int32_t centerLongitudeE7 = 0;
bool dragging = false;
bool dragStarted = false;
int16_t pressX = 0;
int16_t pressY = 0;
int16_t lastX = 0;
int16_t lastY = 0;

constexpr GeoPoint NORTH_AMERICA[] = {
    {-168, 66}, {-150, 72}, {-126, 70}, {-105, 78}, {-82, 72},
    {-60, 55},  {-67, 46},  {-82, 25},  {-97, 17},  {-113, 28},
    {-125, 44}, {-141, 57}, {-168, 66},
};
constexpr GeoPoint SOUTH_AMERICA[] = {
    {-81, 12}, {-66, 8}, {-50, -2}, {-35, -8}, {-45, -24},
    {-55, -38}, {-70, -55}, {-77, -34}, {-81, -5}, {-81, 12},
};
constexpr GeoPoint GREENLAND[] = {
    {-72, 60}, {-48, 58}, {-20, 72}, {-32, 83}, {-58, 82}, {-72, 60},
};
constexpr GeoPoint AFRICA[] = {
    {-17, 35}, {10, 37}, {34, 31}, {51, 12}, {41, -12},
    {28, -34}, {12, -35}, {-2, -20}, {-13, 5}, {-17, 35},
};
constexpr GeoPoint EUROPE_ASIA[] = {
    {-10, 36}, {-10, 58}, {8, 71}, {35, 70}, {58, 76}, {100, 76},
    {160, 66}, {179, 52}, {151, 43}, {139, 34}, {122, 18}, {105, 8},
    {77, 8}, {58, 25}, {39, 36}, {25, 41}, {8, 42}, {-10, 36},
};
constexpr GeoPoint ARABIA_INDIA[] = {
    {34, 31}, {55, 28}, {65, 24}, {77, 8}, {90, 21}, {82, 29},
    {70, 24}, {58, 25}, {51, 12}, {34, 31},
};
constexpr GeoPoint SOUTHEAST_ASIA[] = {
    {94, 22}, {112, 23}, {123, 13}, {119, 2}, {105, -6}, {99, 7},
    {94, 22},
};
constexpr GeoPoint JAPAN[] = {
    {129, 32}, {136, 34}, {142, 45}, {146, 43}, {140, 35}, {129, 32},
};
constexpr GeoPoint AUSTRALIA[] = {
    {112, -11}, {132, -10}, {153, -24}, {146, -40}, {123, -38},
    {112, -25}, {112, -11},
};
constexpr GeoPoint ANTARCTICA[] = {
    {-180, -70}, {-140, -74}, {-95, -72}, {-45, -78}, {0, -72},
    {50, -76}, {105, -71}, {155, -75}, {179, -70}, {179, -88},
    {-180, -88}, {-180, -70},
};

uint16_t canvasColor(uint32_t rgb) {
  return bicino_visual_style::rgb888ToRgb565(rgb);
}

PixelPoint project(const GeoPoint &point) {
  return {static_cast<int16_t>((point.longitude + 180) * 2),
          static_cast<int16_t>((90 - point.latitude) * 2)};
}

void putPixel(int32_t x, int32_t y, uint16_t color) {
  if (worldBuffer == nullptr || x < 0 || y < 0 || x >= WORLD_WIDTH ||
      y >= WORLD_HEIGHT) {
    return;
  }
  worldBuffer[static_cast<uint32_t>(y) * worldStridePixels + x] = color;
}

void drawLine(PixelPoint from, PixelPoint to, uint16_t color,
              int16_t thickness = 1) {
  int32_t x0 = from.x;
  int32_t y0 = from.y;
  const int32_t x1 = to.x;
  const int32_t y1 = to.y;
  const int32_t dx = std::abs(x1 - x0);
  const int32_t sx = x0 < x1 ? 1 : -1;
  const int32_t dy = -std::abs(y1 - y0);
  const int32_t sy = y0 < y1 ? 1 : -1;
  int32_t error = dx + dy;
  while (true) {
    const int16_t radius = thickness / 2;
    for (int16_t oy = -radius; oy <= radius; ++oy) {
      for (int16_t ox = -radius; ox <= radius; ++ox) {
        putPixel(x0 + ox, y0 + oy, color);
      }
    }
    if (x0 == x1 && y0 == y1) {
      break;
    }
    const int32_t doubled = 2 * error;
    if (doubled >= dy) {
      error += dy;
      x0 += sx;
    }
    if (doubled <= dx) {
      error += dx;
      y0 += sy;
    }
  }
}

template <std::size_t Count>
void fillPolygon(const GeoPoint (&points)[Count], uint16_t fill,
                 uint16_t outline) {
  static_assert(Count >= 3, "a polygon needs at least three points");
  std::array<PixelPoint, Count> projected{};
  int16_t minY = WORLD_HEIGHT - 1;
  int16_t maxY = 0;
  for (std::size_t index = 0; index < Count; ++index) {
    projected[index] = project(points[index]);
    minY = std::min(minY, projected[index].y);
    maxY = std::max(maxY, projected[index].y);
  }
  minY = std::max<int16_t>(0, minY);
  maxY = std::min<int16_t>(WORLD_HEIGHT - 1, maxY);

  std::array<int16_t, Count> intersections{};
  for (int16_t y = minY; y <= maxY; ++y) {
    std::size_t intersectionCount = 0;
    for (std::size_t index = 0; index < Count; ++index) {
      const PixelPoint a = projected[index];
      const PixelPoint b = projected[(index + 1) % Count];
      if (!((a.y <= y && b.y > y) || (b.y <= y && a.y > y))) {
        continue;
      }
      const int32_t numerator =
          static_cast<int32_t>(y - a.y) * (b.x - a.x);
      const int32_t denominator = b.y - a.y;
      intersections[intersectionCount++] = static_cast<int16_t>(
          a.x + (denominator == 0 ? 0 : numerator / denominator));
    }
    std::sort(intersections.begin(), intersections.begin() + intersectionCount);
    for (std::size_t index = 0; index + 1 < intersectionCount; index += 2) {
      int16_t start = std::max<int16_t>(0, intersections[index]);
      int16_t end = std::min<int16_t>(WORLD_WIDTH - 1,
                                      intersections[index + 1]);
      for (int16_t x = start; x <= end; ++x) {
        putPixel(x, y, fill);
      }
    }
  }

  for (std::size_t index = 0; index + 1 < Count; ++index) {
    drawLine(projected[index], projected[index + 1], outline, 2);
  }
}

void drawWorld() {
  if (worldBuffer == nullptr) {
    return;
  }
  const uint16_t ocean = canvasColor(OCEAN_COLOR);
  const uint16_t grid = canvasColor(GRID_COLOR);
  const uint16_t land = canvasColor(LAND_COLOR);
  const uint16_t coast = canvasColor(COAST_COLOR);
  for (int16_t y = 0; y < WORLD_HEIGHT; ++y) {
    uint16_t *row = worldBuffer + static_cast<uint32_t>(y) * worldStridePixels;
    std::fill(row, row + WORLD_WIDTH, ocean);
  }
  for (int16_t longitude = -150; longitude <= 150; longitude += 30) {
    const int16_t x = static_cast<int16_t>((longitude + 180) * 2);
    drawLine({x, 0}, {x, WORLD_HEIGHT - 1}, grid);
  }
  for (int16_t latitude = -60; latitude <= 60; latitude += 30) {
    const int16_t y = static_cast<int16_t>((90 - latitude) * 2);
    drawLine({0, y}, {WORLD_WIDTH - 1, y}, grid);
  }

  fillPolygon(NORTH_AMERICA, land, coast);
  fillPolygon(SOUTH_AMERICA, land, coast);
  fillPolygon(GREENLAND, land, coast);
  fillPolygon(AFRICA, land, coast);
  fillPolygon(EUROPE_ASIA, land, coast);
  fillPolygon(ARABIA_INDIA, land, coast);
  fillPolygon(SOUTHEAST_ASIA, land, coast);
  fillPolygon(JAPAN, land, coast);
  fillPolygon(AUSTRALIA, land, coast);
  fillPolygon(ANTARCTICA, land, coast);
}

int32_t wrapLongitude(int64_t value) {
  while (value > LONGITUDE_HALF_E7) {
    value -= LONGITUDE_FULL_E7;
  }
  while (value < -LONGITUDE_HALF_E7) {
    value += LONGITUDE_FULL_E7;
  }
  return static_cast<int32_t>(value);
}

void updateMapPosition() {
  if (mapViewport == nullptr) {
    return;
  }
  const int32_t worldX = static_cast<int32_t>(
      (static_cast<int64_t>(centerLongitudeE7) + LONGITUDE_HALF_E7) *
      WORLD_WIDTH / LONGITUDE_FULL_E7);
  const int32_t worldY = static_cast<int32_t>(
      (static_cast<int64_t>(900000000) - centerLatitudeE7) * WORLD_HEIGHT /
      1800000000LL);
  const int32_t reticleX = TFT_WIDTH / 2;
  const int32_t reticleY = TFT_HEIGHT / 2 - 24;
  const int32_t originX = reticleX - worldX;
  const int32_t originY = reticleY - worldY;
  for (int index = 0; index < 3; ++index) {
    if (mapCanvases[index] != nullptr) {
      lv_obj_set_pos(mapCanvases[index],
                     originX + (index - 1) * WORLD_WIDTH, originY);
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

const char *stateText(world_radio_protocol::PlaybackState state) {
  switch (state) {
  case world_radio_protocol::PlaybackState::Idle:
    return "Drag the map to tune in";
  case world_radio_protocol::PlaybackState::Searching:
    return "Finding stations...";
  case world_radio_protocol::PlaybackState::Connecting:
    return "Connecting...";
  case world_radio_protocol::PlaybackState::Buffering:
    return "Buffering...";
  case world_radio_protocol::PlaybackState::Playing:
    return "Playing on iPhone";
  case world_radio_protocol::PlaybackState::Paused:
    return "Paused";
  case world_radio_protocol::PlaybackState::NoStations:
    return "No stations nearby";
  case world_radio_protocol::PlaybackState::Error:
    return "Station unavailable";
  }
  return "";
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

  if (!phoneReady) {
    lv_label_set_text(stationLabel, "World Radio");
    lv_label_set_text(placeLabel, "Open Bicino on your iPhone");
    lv_label_set_text(stateLabel, "Phone not connected");
    lv_label_set_text(indexLabel, "");
    lv_label_set_text(playLabel, "PLAY");
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
  lv_label_set_text(stateLabel,
                    status.message[0] != '\0' ? status.message
                                              : stateText(status.state));
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
                    status.state == world_radio_protocol::PlaybackState::Playing
                        ? "PAUSE"
                        : "PLAY");

  if (status.hasStation &&
      world_radio_protocol::validCoordinate(status.stationLatitudeE7,
                                            status.stationLongitudeE7)) {
    centerLatitudeE7 = std::max(-LATITUDE_LIMIT_E7,
                               std::min(LATITUDE_LIMIT_E7,
                                        status.stationLatitudeE7));
    centerLongitudeE7 = wrapLongitude(status.stationLongitudeE7);
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
    if (std::abs(dx) > 200 || std::abs(dy) > 200) {
      break;
    }
    centerLongitudeE7 = wrapLongitude(
        static_cast<int64_t>(centerLongitudeE7) -
        static_cast<int64_t>(dx) * LONGITUDE_FULL_E7 / WORLD_WIDTH);
    centerLatitudeE7 = static_cast<int32_t>(std::max<int64_t>(
        -LATITUDE_LIMIT_E7,
        std::min<int64_t>(LATITUDE_LIMIT_E7,
                          static_cast<int64_t>(centerLatitudeE7) +
                              static_cast<int64_t>(dy) * 1800000000LL /
                                  WORLD_HEIGHT)));
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

} // namespace

void worldRadioScr(lv_obj_t *screen,
                   const WorldRadioScreenCallbacks &callbacks) {
  screenRoot = screen;
  screenCallbacks = callbacks;
  lv_obj_set_style_bg_color(screenRoot, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screenRoot, LV_OPA_COVER, 0);
  lv_obj_clear_flag(screenRoot, LV_OBJ_FLAG_SCROLLABLE);

  mapViewport = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(mapViewport);
  lv_obj_set_size(mapViewport, TFT_WIDTH, TFT_HEIGHT);
  lv_obj_set_pos(mapViewport, 0, 0);
  lv_obj_set_style_bg_color(mapViewport, lv_color_hex(OCEAN_COLOR), 0);
  lv_obj_set_style_bg_opa(mapViewport, LV_OPA_COVER, 0);
  lv_obj_add_flag(mapViewport, LV_OBJ_FLAG_CLICKABLE);
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
  if (worldBuffer != nullptr) {
    drawWorld();
    for (int index = 0; index < 3; ++index) {
      mapCanvases[index] = lv_canvas_create(mapViewport);
      lv_canvas_set_buffer(mapCanvases[index], worldBuffer, WORLD_WIDTH,
                           WORLD_HEIGHT, LV_COLOR_FORMAT_RGB565);
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

  lv_obj_t *title = lv_label_create(screenRoot);
  lv_obj_set_style_text_color(title, lv_color_hex(ACCENT_COLOR), 0);
  lv_obj_set_style_text_font(title, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_letter_space(title, 2, 0);
  lv_label_set_text_static(title, "WORLD RADIO");
  lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 14);
  makePassive(title);

  lv_obj_t *cycleButton = makeButton(screenRoot, 54, 42, "NEXT", cycleEvent);
  lv_obj_align(cycleButton, LV_ALIGN_TOP_LEFT, 18, 12);
  lv_obj_t *randomButton =
      makeButton(screenRoot, 64, 42, "RANDOM", randomEvent);
  lv_obj_align(randomButton, LV_ALIGN_TOP_RIGHT, -18, 12);

  coordinateLabel = lv_label_create(screenRoot);
  lv_obj_set_style_text_color(coordinateLabel, lv_color_hex(0xBDD5CB), 0);
  lv_obj_set_style_text_font(coordinateLabel, &lv_font_montserrat_14, 0);
  lv_obj_align(coordinateLabel, LV_ALIGN_CENTER, 0, -67);
  makePassive(coordinateLabel);
  updateCoordinateLabel();

  lv_obj_t *reticle = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(reticle);
  lv_obj_set_size(reticle, 42, 42);
  lv_obj_set_style_radius(reticle, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(reticle, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(reticle, 3, 0);
  lv_obj_set_style_border_color(reticle, lv_color_hex(ACCENT_COLOR), 0);
  lv_obj_align(reticle, LV_ALIGN_CENTER, 0, -24);
  makePassive(reticle);
  lv_obj_t *reticleDot = lv_obj_create(reticle);
  lv_obj_remove_style_all(reticleDot);
  lv_obj_set_size(reticleDot, 8, 8);
  lv_obj_set_style_radius(reticleDot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_color(reticleDot, lv_color_hex(ACCENT_COLOR), 0);
  lv_obj_set_style_bg_opa(reticleDot, LV_OPA_COVER, 0);
  lv_obj_center(reticleDot);
  makePassive(reticleDot);

  lv_obj_t *panel = lv_obj_create(screenRoot);
  lv_obj_remove_style_all(panel);
  lv_obj_set_size(panel, TFT_WIDTH, 150);
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

  lv_obj_t *previousButton = makeButton(panel, 72, 48, "<", previousEvent);
  lv_obj_align(previousButton, LV_ALIGN_BOTTOM_LEFT, 44, -9);
  lv_obj_t *playButton = makeButton(panel, 96, 50, "PLAY", playEvent);
  lv_obj_align(playButton, LV_ALIGN_BOTTOM_MID, 0, -8);
  playLabel = lv_obj_get_child(playButton, 0);
  lv_obj_t *nextButton = makeButton(panel, 72, 48, ">", nextEvent);
  lv_obj_align(nextButton, LV_ALIGN_BOTTOM_RIGHT, -44, -9);

  indexLabel = lv_label_create(panel);
  lv_obj_set_style_text_color(indexLabel, lv_color_hex(0x7D958B), 0);
  lv_obj_set_style_text_font(indexLabel, &lv_font_montserrat_14, 0);
  lv_obj_align(indexLabel, LV_ALIGN_BOTTOM_MID, 0, -61);
  makePassive(indexLabel);

  renderedRevision = UINT32_MAX;
  renderStatus(true);
}

void updateWorldRadioScr() { renderStatus(); }

void activateWorldRadioScr() { renderStatus(true); }
