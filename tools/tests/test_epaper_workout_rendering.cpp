// Replay the production configurable workout renderer with real pinned LVGL.
// Geometry/font mocks cannot catch text alignment or glyph placement errors.
#define RIDE_STATS_PREVIEW_NO_MAIN
#include "../ride_stats_preview/emit_preview.cpp"
#include <climits>
#include <vector>

struct Cell {
  const lv_font_t *font;
  lv_area_t bounds;
  bool operator==(const Cell &other) const {
    return font == other.font && bounds.x1 == other.bounds.x1 &&
           bounds.x2 == other.bounds.x2 && bounds.y1 == other.bounds.y1 &&
           bounds.y2 == other.bounds.y2;
  }
};

static Cell cell(lv_obj_t *object) {
  lv_obj_update_layout(ridePage);
  Cell result{lv_obj_get_style_text_font(object, LV_PART_MAIN), {}};
  lv_obj_get_coords(object, &result.bounds);
  return result;
}

static void render(const ride_telemetry_presenter::ViewModel &model) {
  updateConfigurableSlots(model);
  lv_obj_update_layout(ridePage);
  for (std::size_t i = 0; i < configurableSlots.size(); ++i) {
    const auto *label = configurableSlots[i].labels.value;
    if (lv_obj_has_flag(label, LV_OBJ_FLAG_HIDDEN)) continue;
    const auto *font = lv_obj_get_style_text_font(label, LV_PART_MAIN);
    const auto *text = lv_label_get_text(label);
    assert(text[0] != '\0');
    assert(ride_metric_typography::supportsText(font, text));
    assert(lv_text_get_width(text, std::strlen(text), font, 0) <=
           lv_obj_get_width(label) - 4);
    assert(font->line_height <= lv_obj_get_height(label));
    assert(lv_obj_get_style_text_align(label, LV_PART_MAIN) == LV_TEXT_ALIGN_RIGHT);
    const auto rect = ride_telemetry_layout::configurableValueRect(rideLayout, i);
    assert(lv_obj_get_x(label) >= rect.x);
    assert(lv_obj_get_y(label) == rect.y);
    assert(lv_obj_get_x(label) + lv_obj_get_width(label) <= rect.right());
  }
}

static int glyphX(lv_obj_t *label, char character) {
  const auto *text = lv_label_get_text(label);
  const auto *found = std::strchr(text, character);
  assert(found);
  lv_point_t position{};
  lv_label_get_letter_pos(label, static_cast<uint32_t>(found - text), &position);
  return lv_obj_get_x(label) + position.x;
}

static std::vector<uint8_t> pixels(const Rect &rect) {
  auto *image = lv_snapshot_take(ridePage, LV_COLOR_FORMAT_ARGB8888);
  assert(image && image->header.w == 480 && image->header.h == 800);
  std::vector<uint8_t> result;
  for (int y = rect.y; y < rect.bottom(); ++y) {
    const auto *row = image->data + y * image->header.stride + rect.x * 4;
    result.insert(result.end(), row, row + rect.width * 4);
  }
  lv_draw_buf_destroy(image);
  return result;
}

static void transitions() {
  previewLayout.slots = {Widget::Speed, Widget::HeartRate, Widget::Distance,
      Widget::MovingTime, Widget::ElapsedTime, Widget::Power, Widget::Altitude};
  auto model = sampleModel();
  auto *speed = configurableSlots[0].labels.value;
  model.speedTenthsKmh = {true, 99};
  render(model);
  const auto speedCell = cell(speed);
  const auto decimalX = glyphX(speed, '.');
  for (uint32_t value : {100U, 999U, 1000U, UINT32_MAX}) {
    model.speedTenthsKmh = {true, value}; render(model);
    assert(cell(speed) == speedCell && glyphX(speed, '.') == decimalX);
  }
  model.speedTenthsKmh.available = false; render(model);
  assert(cell(speed) == speedCell && std::string(lv_label_get_text(speed)) == "--");

  auto &heart = configurableSlots[1];
  model.currentHeartRateBpm = {true, 99}; render(model);
  const auto heartValue = cell(heart.labels.value), heartIcon = cell(heart.heart);
  for (uint16_t value : {100, 9, 0, 65535}) {
    model.currentHeartRateBpm = {true, value}; render(model);
    assert(cell(heart.labels.value) == heartValue && cell(heart.heart) == heartIcon);
    assert(!lv_obj_has_flag(heart.heart, LV_OBJ_FLAG_HIDDEN));
  }
  model.currentHeartRateBpm.available = false; render(model);
  assert(cell(heart.labels.value) == heartValue && cell(heart.heart) == heartIcon);
  assert(lv_obj_has_flag(heart.heart, LV_OBJ_FLAG_HIDDEN));

  auto &altitude = configurableSlots[6];
  model.altitudeMeters = {true, 9}; render(model);
  const auto altitudeValue = cell(altitude.labels.value), sign = cell(altitude.sign);
  for (int16_t value : {10, 99, 100, -1, -10, -32768, 32767, 0}) {
    model.altitudeMeters = {true, value}; render(model);
    assert(cell(altitude.labels.value) == altitudeValue && cell(altitude.sign) == sign);
    assert(std::string(lv_label_get_text(altitude.sign)) == (value < 0 ? "-" : ""));
  }
  model.altitudeMeters.available = false; render(model);
  assert(cell(altitude.labels.value) == altitudeValue && cell(altitude.sign) == sign);

  previewLayout.slots[5] = Widget::ElapsedTime;
  model.altitudeMeters = {true, 112};
  model.wallElapsedSeconds = {true, 3599}; render(model);
  const auto altitudePixels = pixels(rideLayout.metrics[5]);
  const auto timeCell = cell(configurableSlots[5].labels.value);
  for (uint32_t elapsed : {3600U, 35999U, 36000U, UINT32_MAX}) {
    model.wallElapsedSeconds = {true, elapsed}; render(model);
    assert(cell(configurableSlots[5].labels.value) == timeCell);
    assert(cell(altitude.labels.value) == altitudeValue);
    assert(pixels(rideLayout.metrics[5]) == altitudePixels);
  }

  auto &distance = configurableSlots[2];
  model.distanceMeters = {true, 999}; render(model);
  const auto distanceCell = cell(distance.labels.value);
  const auto distanceDecimal = glyphX(distance.labels.value, '.');
  for (const auto &example : std::array<std::pair<uint32_t, const char *>, 6>{{
      {999,"1.0"}, {1000,"1.0"}, {9949,"9.9"}, {9950,"10.0"},
      {10000,"10.0"}, {UINT32_MAX,"4294967.3"}}}) {
    model.distanceMeters = {true, example.first}; render(model);
    assert(std::string(lv_label_get_text(distance.labels.value)) == example.second);
    assert(cell(distance.labels.value) == distanceCell);
    assert(glyphX(distance.labels.value, '.') == distanceDecimal);
    assert(std::string(lv_label_get_text(distance.labels.title)) == "Distance km");
  }
}

static void allSlotsAndWidgets() {
  previewSensorMask = 3;
  const auto normal = sampleModel();
  auto maximum = normal;
  maximum.speedTenthsKmh.value = maximum.averageSpeedTenthsKmh.value =
      maximum.maximumSpeedTenthsKmh.value = UINT32_MAX;
  maximum.currentHeartRateBpm.value =
      maximum.averageHeartRateBpm.value = maximum.cyclingPowerWatts.value =
      maximum.cyclingCadenceTenthsRpm.value =
      maximum.activeEnergyTenthsKilocalorie.value = UINT16_MAX;
  maximum.distanceMeters.value = maximum.routeRemainingMeters.value =
      maximum.elapsedSeconds.value = maximum.wallElapsedSeconds.value = UINT32_MAX;
  maximum.altitudeMeters.value = INT16_MIN;
  auto missing = ride_telemetry_presenter::ViewModel{};
  missing.usesWorkout = true;
  for (int id = 1; id <= static_cast<int>(Widget::PowerZoneRange); ++id) {
    const auto widget = static_cast<Widget>(id);
    previewLayout.slots.fill(widget);
    render(normal);
    std::array<Cell, 7> original{};
    for (std::size_t i = 0; i < original.size(); ++i)
      original[i] = cell(configurableSlots[i].labels.value);
    for (auto model : {maximum, missing, normal}) {
      render(model);
      for (std::size_t i = 0; i < original.size(); ++i) {
        // Smart fields deliberately change semantics as sensors appear. Zone
        // strips deliberately replace numeric labels when data is available.
        if (widget == Widget::SmartMetric1 || widget == Widget::SmartMetric2 ||
            widget == Widget::HeartRateZone || widget == Widget::PowerZone) continue;
        assert(cell(configurableSlots[i].labels.value) == original[i]);
        const auto expected = epaper_ride_stats::make(widget, model);
        const char *text = expected.value.data();
        if (expected.isAltitude && expected.available && text[0] == '-') ++text;
        assert(std::string(lv_label_get_text(configurableSlots[i].labels.value)) == text);
      }
    }
  }
}

int main(int argc, char **argv) {
  lv_init();
  auto *display = lv_display_create(480, 800);
  assert(display);
  rideLayout = ride_telemetry_layout::makeLayout(480, 800);
  assert(ride_telemetry_layout::isValid(rideLayout));
  assert(rideLayout.metrics[5].bottom() > 600 && rideLayout.metrics[5].bottom() < 700);
  ridePage = lv_obj_create(lv_screen_active());
  lv_obj_remove_style_all(ridePage);
  lv_obj_set_size(ridePage, 480, 800);
  lv_obj_clear_flag(ridePage, LV_OBJ_FLAG_SCROLLABLE);
  for (std::size_t i = 0; i < 7; ++i) createConfigurableSlot(i);
  transitions();
  allSlotsAndWidgets();
  // Optional inspection artifact, using the exact tested production renderer.
  if (argc == 2) {
    previewLayout.slots = {Widget::Speed, Widget::HeartRate, Widget::Distance,
        Widget::MovingTime, Widget::ElapsedTime, Widget::Power, Widget::Altitude};
    render(sampleModel());
    const auto image = pixels({0, 0, 480, 800});
    std::ofstream out(argv[1], std::ios::binary);
    out.write(reinterpret_cast<const char *>(image.data()), image.size());
  }
  lv_obj_delete(ridePage);
  lv_display_delete(display);
  lv_deinit();
  std::cout << "480x800 actual LVGL workout replay: stable anchors, fonts, signs, icons, units; all widgets/slots passed\n";
}
