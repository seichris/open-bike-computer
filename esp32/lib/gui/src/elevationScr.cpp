#include "elevationScr.hpp"

#include "elevationPresentation.hpp"

#include "../../route_elevation/route_elevation_runtime.hpp"
#include "../../tft/tft.hpp"

#include <cstring>
#include <esp_heap_caps.h>

namespace {

namespace ep = elevation_presentation;
namespace rep = route_elevation_protocol;

constexpr uint32_t TITLE_COLOR = 0x999999;
constexpr uint32_t VALUE_COLOR = 0xFFFFFF;
constexpr uint32_t MUTED_COLOR = 0x6B7280;
constexpr uint32_t BASELINE_COLOR = 0x30343C;
constexpr uint32_t MARKER_COLOR = 0x0088FF;
constexpr uint8_t TRAVELED_OPA = 90;
constexpr uint8_t ESTIMATED_OPA = 150;

struct Metric {
  lv_obj_t *title = nullptr;
  lv_obj_t *value = nullptr;
};

ElevationScreenCallbacks screenCallbacks{};
lv_obj_t *root = nullptr;
lv_obj_t *canvas = nullptr;
uint16_t *canvasPixels = nullptr;
lv_obj_t *markerLine = nullptr;
lv_obj_t *markerDot = nullptr;
lv_obj_t *headline = nullptr;
lv_obj_t *detail = nullptr;
lv_obj_t *footer = nullptr;
Metric routeElevation;
Metric routeGrade;
Metric totalAscent;
Metric ascentRemaining;

ep::Layout layout{};
ep::Chart chart{};
// Copies of the published snapshot; the LVGL task owns these exclusively.
route_elevation_runtime::Snapshot current{};
uint32_t renderedRevision = UINT32_MAX;
uint32_t chartRouteToken = 0;
uint16_t chartRevision = 0;
bool chartValid = false;
int32_t paintedMarker = INT32_MIN;
bool paintedOnRoute = false;
bool renderedConnected = false;
bool renderedSupported = false;

void makePassive(lv_obj_t *object) {
  lv_obj_clear_flag(object, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(object, LV_OBJ_FLAG_SCROLLABLE);
}

lv_obj_t *makeLabel(lv_obj_t *parent, const lv_font_t *font, uint32_t color, const ep::Rect &rect,
                    const char *text) {
  lv_obj_t *label = lv_label_create(parent);
  lv_obj_set_style_text_font(label, font, 0);
  lv_obj_set_style_text_color(label, lv_color_hex(color), 0);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(label, LV_LABEL_LONG_CLIP);
  lv_obj_set_size(label, rect.width, rect.height);
  lv_obj_set_pos(label, rect.x, rect.y);
  lv_label_set_text(label, text);
  makePassive(label);
  return label;
}

Metric makeMetric(lv_obj_t *parent, const ep::Rect &rect, const char *title, const lv_font_t *valueFont) {
  Metric metric;
  metric.title = makeLabel(parent, &lv_font_montserrat_18, TITLE_COLOR, {rect.x, rect.y, rect.width, 22}, title);
  metric.value = makeLabel(parent, valueFont, VALUE_COLOR, {rect.x, rect.y + 22, rect.width, rect.height - 22},
                           "--");
  return metric;
}

void setText(lv_obj_t *label, const char *text) {
  if (label != nullptr && std::strcmp(lv_label_get_text(label), text) != 0) {
    lv_label_set_text(label, text);
  }
}

void setHidden(lv_obj_t *object, bool hidden) {
  if (object == nullptr) return;
  if (hidden) {
    lv_obj_add_flag(object, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_clear_flag(object, LV_OBJ_FLAG_HIDDEN);
  }
}

uint16_t rgb565(uint32_t rgb, uint8_t opa) {
  const uint32_t red = ((rgb >> 16) & 0xFF) * opa / 255;
  const uint32_t green = ((rgb >> 8) & 0xFF) * opa / 255;
  const uint32_t blue = (rgb & 0xFF) * opa / 255;
  return static_cast<uint16_t>(((red & 0xF8) << 8) | ((green & 0xFC) << 3) | (blue >> 3));
}

// Repaint the whole chart buffer: only on a new profile or when the marker
// crosses a pixel column, so the full-frame renderer redraws at most ~1 Hz.
void paintCanvas(int32_t marker) {
  if (canvasPixels == nullptr) return;
  const int32_t width = layout.chart.width;
  const int32_t height = layout.chart.height;
  std::memset(canvasPixels, 0, static_cast<std::size_t>(width * height) * sizeof(uint16_t));
  const uint16_t baseline = rgb565(BASELINE_COLOR, LV_OPA_COVER);
  for (int32_t x = 0; x < width; ++x) {
    canvasPixels[(height - 1) * width + x] = baseline;
  }
  if (chartValid) {
    int32_t previousTop = -1;
    for (int32_t x = 0; x < chart.width; ++x) {
      const ep::Column &column = chart.columns[static_cast<std::size_t>(x)];
      if (column.style == ep::ColumnStyle::Unknown) {
        // A dashed baseline marks unknown elevation; it is never drawn as zero.
        if ((x / 4) % 2 == 0) canvasPixels[(height - 2) * width + x] = rgb565(MUTED_COLOR, LV_OPA_COVER);
        previousTop = -1;
        continue;
      }
      const bool traveled = marker >= 0 && x < marker;
      const uint32_t color =
          column.style == ep::ColumnStyle::LowConfidence ? MUTED_COLOR : ep::gradeColor(column.gradeBand);
      const uint8_t opacity = traveled ? TRAVELED_OPA
                              : column.style == ep::ColumnStyle::Estimated ? ESTIMATED_OPA
                                                                           : LV_OPA_COVER;
      const uint16_t fill = rgb565(color, opacity);
      const uint16_t hatch = rgb565(color, opacity / 2);
      const uint16_t edge = rgb565(0xFFFFFF, traveled ? 120 : 235);
      const int32_t top = column.top < 0 ? 0 : (column.top >= height ? height - 1 : column.top);
      for (int32_t y = top; y < height - 1; ++y) {
        const bool hatched = column.style == ep::ColumnStyle::Estimated && (x + y) % 6 == 0;
        canvasPixels[y * width + x] = hatched ? hatch : fill;
      }
      const int32_t from = previousTop < 0 ? top : (previousTop < top ? previousTop : top);
      const int32_t to = previousTop < 0 ? top + 1 : (previousTop > top ? previousTop : top + 1);
      for (int32_t y = from; y <= to && y < height - 1; ++y) {
        canvasPixels[y * width + x] = edge;
      }
      previousTop = top;
    }
  }
  lv_obj_invalidate(canvas);
}

void placeMarker(int32_t marker, bool onRoute) {
  if (marker < 0 || !chartValid || markerLine == nullptr || markerDot == nullptr) {
    setHidden(markerLine, true);
    setHidden(markerDot, true);
    return;
  }
  const ep::Column &column = chart.columns[static_cast<std::size_t>(marker)];
  lv_obj_set_pos(markerLine, layout.chart.x + marker - 1, layout.chart.y);
  setHidden(markerLine, false);
  if (column.style == ep::ColumnStyle::Unknown) {
    setHidden(markerDot, true);
    return;
  }
  lv_obj_set_pos(markerDot, layout.chart.x + marker - 8, layout.chart.y + column.top - 8);
  lv_obj_set_style_bg_color(markerDot, lv_color_hex(onRoute ? MARKER_COLOR : MUTED_COLOR), 0);
  setHidden(markerDot, false);
}

void renderValues(bool ready) {
  char text[32];
  const rep::Progress &progress = current.progress;
  const bool onRoute = current.hasProgress && (progress.flags & rep::PROGRESS_ON_ROUTE) != 0;
  if (ready && onRoute && (progress.flags & rep::PROGRESS_ELEVATION_VALID) != 0) {
    ep::formatMeters(text, sizeof(text), progress.elevationM,
                     (progress.flags & rep::PROGRESS_ELEVATION_ESTIMATED) != 0, false);
    setText(routeElevation.value, text);
  } else {
    setText(routeElevation.value, "--");
  }
  if (ready && onRoute && (progress.flags & rep::PROGRESS_GRADE_VALID) != 0) {
    ep::formatGrade(text, sizeof(text), progress.gradeDeciPercent,
                    (progress.flags & rep::PROGRESS_GRADE_ESTIMATED) != 0);
    setText(routeGrade.value, text);
  } else {
    setText(routeGrade.value, "--");
  }
  if (ready && (current.profile.flags & rep::BODY_FLAG_ASCENT_VALID) != 0) {
    ep::formatMeters(text, sizeof(text), static_cast<int32_t>(current.profile.totalAscentM), false,
                     (current.profile.flags & rep::BODY_FLAG_STATS_COMPLETE) == 0);
    setText(totalAscent.value, text);
  } else {
    setText(totalAscent.value, "--");
  }
  if (ready && current.hasProgress && (progress.flags & rep::PROGRESS_ASCENT_REMAINING_VALID) != 0) {
    ep::formatMeters(text, sizeof(text), progress.ascentRemainingM, false,
                     (progress.flags & rep::PROGRESS_ASCENT_REMAINING_LOWER_BOUND) != 0);
    setText(ascentRemaining.value, text);
  } else {
    setText(ascentRemaining.value, "--");
  }
}

void render(bool force) {
  const bool connected = screenCallbacks.phoneConnected != nullptr && screenCallbacks.phoneConnected();
  const bool supported = screenCallbacks.profilesSupported != nullptr && screenCallbacks.profilesSupported();
  const bool changed = route_elevation_runtime::snapshotIfChanged(renderedRevision, current);
  if (!force && !changed && connected == renderedConnected && supported == renderedSupported) {
    return;
  }
  if (changed) {
    renderedRevision = current.revision;
  }
  renderedConnected = connected;
  renderedSupported = supported;

  const ep::Status status = ep::status(connected, supported, current.binding, current.hasProfile);
  const bool ready = status.state == ep::ScreenState::Ready;
  bool rebuilt = false;
  if (!ready) {
    rebuilt = chartValid;
    chartValid = false;
  } else if (!chartValid || chartRouteToken != current.profile.routeToken ||
             chartRevision != current.profile.revision) {
    // A new route revision always arrives as a new binding; progress updates
    // for the same profile only move the marker.
    ep::buildChart(current.profile, layout.chart.width, layout.chart.height, chart);
    chartRouteToken = current.profile.routeToken;
    chartRevision = current.profile.revision;
    chartValid = true;
    rebuilt = true;
  }

  int32_t marker = -1;
  bool onRoute = false;
  if (ready && current.hasProgress) {
    marker = ep::markerX(current.progress.progressM, current.profile.totalDistanceM, chart.width);
    onRoute = (current.progress.flags & rep::PROGRESS_ON_ROUTE) != 0;
  }
  const bool markerMoved = marker != paintedMarker;
  if (force || rebuilt || markerMoved) {
    paintCanvas(marker);
  }
  if (force || rebuilt || markerMoved || onRoute != paintedOnRoute) {
    placeMarker(marker, onRoute);
  }
  paintedMarker = marker;
  paintedOnRoute = onRoute;

  renderValues(ready);
  setHidden(headline, ready);
  setHidden(detail, ready);
  setHidden(footer, !ready);
  if (ready) {
    char text[64];
    ep::footerText(text, sizeof(text), current.profile);
    setText(footer, text);
  } else {
    setText(headline, status.headline);
    setText(detail, status.detail);
  }
}

} // namespace

void elevationScr(lv_obj_t *screen, const ElevationScreenCallbacks &callbacks) {
  root = screen;
  screenCallbacks = callbacks;
  layout = ep::makeLayout(TFT_WIDTH, TFT_HEIGHT);
  lv_obj_set_style_bg_color(root, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(root, LV_OPA_COVER, 0);
  lv_obj_clear_flag(root, LV_OBJ_FLAG_SCROLLABLE);

  routeElevation = makeMetric(root, layout.primaryLeft, "ROUTE ELEV", &lv_font_montserrat_48);
  routeGrade = makeMetric(root, layout.primaryRight, "ROUTE GRADE", &lv_font_montserrat_48);
  totalAscent = makeMetric(root, layout.secondaryLeft, "TOTAL ASCENT", &lv_font_montserrat_32);
  ascentRemaining = makeMetric(root, layout.secondaryRight, "TO CLIMB", &lv_font_montserrat_32);

  const std::size_t bytes =
      static_cast<std::size_t>(layout.chart.width) * static_cast<std::size_t>(layout.chart.height) * sizeof(uint16_t);
  canvasPixels = static_cast<uint16_t *>(heap_caps_aligned_alloc(4, bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (canvasPixels != nullptr) {
    std::memset(canvasPixels, 0, bytes);
    canvas = lv_canvas_create(root);
    lv_canvas_set_buffer(canvas, canvasPixels, layout.chart.width, layout.chart.height, LV_COLOR_FORMAT_RGB565);
    lv_obj_set_pos(canvas, layout.chart.x, layout.chart.y);
    makePassive(canvas);
  }

  markerLine = lv_obj_create(root);
  lv_obj_remove_style_all(markerLine);
  lv_obj_set_size(markerLine, 2, layout.chart.height);
  lv_obj_set_style_bg_color(markerLine, lv_color_white(), 0);
  lv_obj_set_style_bg_opa(markerLine, LV_OPA_70, 0);
  makePassive(markerLine);
  markerDot = lv_obj_create(root);
  lv_obj_remove_style_all(markerDot);
  lv_obj_set_size(markerDot, 16, 16);
  lv_obj_set_style_radius(markerDot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(markerDot, LV_OPA_COVER, 0);
  lv_obj_set_style_bg_color(markerDot, lv_color_hex(MARKER_COLOR), 0);
  lv_obj_set_style_border_color(markerDot, lv_color_white(), 0);
  lv_obj_set_style_border_width(markerDot, 3, 0);
  makePassive(markerDot);

  headline = makeLabel(root, &lv_font_montserrat_24, VALUE_COLOR,
                       {layout.message.x, layout.message.y, layout.message.width, 30}, "");
  detail = makeLabel(root, &lv_font_montserrat_18, TITLE_COLOR,
                     {layout.message.x, layout.message.y + 32, layout.message.width, 26}, "");
  footer = makeLabel(root, &lv_font_montserrat_14, MUTED_COLOR, layout.footer, "");

  renderedRevision = UINT32_MAX;
  chartValid = false;
  paintedMarker = INT32_MIN;
  render(true);
}

void updateElevationScr() { render(false); }

void activateElevationScr() { render(true); }
