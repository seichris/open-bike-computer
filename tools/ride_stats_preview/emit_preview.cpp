// Compiled with renderer_helpers.inc extracted from the production screen.
// No reimplementation of LVGL text sizing, heart placement, or row pairing.
#include "rideMetricTypography.hpp"
#include "rideTelemetryLayout.hpp"
#include "ride_stats_widget.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

using Widget = screen_configuration_protocol::RideStatsWidget;
using Rect = ride_telemetry_layout::Rect;
ride_telemetry_layout::Layout rideLayout{};
lv_obj_t *ridePage = nullptr;
screen_configuration_protocol::RideStatsLayout previewLayout{};
int previewSensorMask = 0;
const auto &currentRideStatsLayout() { return previewLayout; }
void hideLegacyWorkoutMetrics() {} // Preview owns no legacy page.
#include "renderer_helpers.inc"

static int nominalSize(const lv_font_t *font) {
  for (auto candidate : std::array<std::pair<const lv_font_t *, int>, 9>{{
      {&ride_speed_font_84,84},{&ride_value_font_64,64},{&ride_value_font_56,56},
      {&lv_font_montserrat_48,48},{&lv_font_montserrat_38,38},
      {&lv_font_montserrat_24,24},{&lv_font_montserrat_18,18},
      {&lv_font_montserrat_14,14},{&lv_font_montserrat_12,12}}}) {
    if (font->dsc == candidate.first->dsc) return candidate.second;
  }
  return 10;
}

static ride_telemetry_presenter::ViewModel sampleModel() {
  ride_telemetry_presenter::ViewModel model{};
  model.usesWorkout = true;
  model.sessionState = workout_telemetry_protocol::SessionState::Running;
  model.speedTenthsKmh = {true,264};
  model.averageSpeedTenthsKmh = {true,245};
  model.maximumSpeedTenthsKmh = {true,499};
  model.currentHeartRateBpm = {true,126};
  model.averageHeartRateBpm = {true,142};
  model.currentHeartRateZone = {true,2};
  model.heartRateZoneCount = {true,5};
  model.distanceMeters = {true,46000};
  model.elapsedSeconds = {true,7525};
  model.wallElapsedSeconds = {true,8307};
  model.altitudeMeters = {true,112};
  model.routeRemainingMeters = {true,9800};
  model.activeEnergyTenthsKilocalorie = {true,4120};
  // The default smart fields resolve to elapsed/altitude, as in the report.
  // Optional power/cadence values are enabled for their explicit previews.
  if (previewSensorMask & 1) model.cyclingPowerWatts = {true,245};
  if (previewSensorMask & 2) model.cyclingCadenceTenthsRpm = {true,875};
  return model;
}

static void writeRect(std::ostream &out, const Rect &r) {
  out << "[" << r.x << "," << r.y << "," << r.width << "," << r.height << "]";
}

static void emitSnapshot(std::ostream &out, const std::filesystem::path &dir,
                         const std::string &key, int &imageIndex) {
  const auto model = sampleModel();
  updateConfigurableSlots(model);
  lv_obj_update_layout(ridePage);
  auto *image = lv_snapshot_take(ridePage, LV_COLOR_FORMAT_ARGB8888);
  assert(image && image->header.w == static_cast<uint32_t>(rideLayout.screenWidth));
  assert(image->header.h == static_cast<uint32_t>(rideLayout.screenHeight));
  int left = rideLayout.screenWidth, top = rideLayout.screenHeight;
  int right = -1, bottom = -1;
  for (int y = 0; y < rideLayout.screenHeight; ++y) {
    for (int x = 0; x < rideLayout.screenWidth; ++x) {
      const auto *pixel = image->data + y * image->header.stride + x * 4;
      if (pixel[3] == 0) continue;
      if (ride_telemetry_layout::usesRoundScreenSafeArea(
              rideLayout.screenWidth, rideLayout.screenHeight)) {
        // Verify actual nontransparent pixels, not just a square framebuffer.
        const int dx = x - 233, dy = y - 233;
        assert(dx * dx + dy * dy <= 225 * 225);
      }
      left = std::min(left,x); top = std::min(top,y);
      right = std::max(right,x); bottom = std::max(bottom,y);
    }
  }
  const bool empty = right < left;
  const Rect bounds = empty ? Rect{} : Rect{left,top,right-left+1,bottom-top+1};
  const auto file = std::to_string(imageIndex++) + ".bgra";
  if (!empty) {
    std::ofstream pixels(dir/file,std::ios::binary);
    for (int y = top; y <= bottom; ++y)
      pixels.write(reinterpret_cast<const char *>(image->data +
          y * image->header.stride + left * 4), bounds.width * 4);
  }
  out << '"' << key << "\":{\"file\":\"" << (empty ? "" : file)
      << "\",\"bounds\":";
  writeRect(out,bounds);
  out << ",\"fonts\":[";
  for (std::size_t i=0;i<configurableSlots.size();++i) {
    if(i) out << ',';
    const auto *label = configurableSlots[i].labels.value;
    out << (lv_obj_has_flag(label,LV_OBJ_FLAG_HIDDEN) ? 0 :
        nominalSize(lv_obj_get_style_text_font(label,LV_PART_MAIN)));
  }
  out << "]}";
  lv_draw_buf_destroy(image);
}

static void verifyLivePairing() {
  previewLayout.slots.fill(Widget::Empty);
  for (std::size_t right=2;right<7;right+=2) {
    for (const auto leftWidget : {Widget::ElapsedTime,Widget::MovingTime,Widget::HeartRate}) {
      previewLayout.slots.fill(Widget::Empty);
      previewLayout.slots[right-1]=leftWidget;
      previewLayout.slots[right]=Widget::Altitude;
      const lv_font_t *previous=nullptr;
      for (uint32_t elapsed : {8301U,8302U,8303U,8304U,8305U,8306U,8307U}) {
        auto model=sampleModel();
        model.elapsedSeconds={true,elapsed}; model.wallElapsedSeconds={true,elapsed};
        model.altitudeMeters={true,static_cast<int16_t>(100+elapsed%10)};
        updateConfigurableSlots(model);
        const auto *a=lv_obj_get_style_text_font(configurableSlots[right-1].labels.value,LV_PART_MAIN);
        const auto *b=lv_obj_get_style_text_font(configurableSlots[right].labels.value,LV_PART_MAIN);
        assert(a==b && (!previous || previous==a)); previous=a;
      }
      for (int16_t altitude : {int16_t{-32768}, int16_t{-112}, int16_t{0}, int16_t{112}, int16_t{32767}}) {
        auto model=sampleModel(); model.altitudeMeters={true,altitude};
        updateConfigurableSlots(model);
        const auto *a=lv_obj_get_style_text_font(configurableSlots[right-1].labels.value,LV_PART_MAIN);
        const auto *b=lv_obj_get_style_text_font(configurableSlots[right].labels.value,LV_PART_MAIN);
        assert(a==b);
      }
    }
  }
}

int main(int argc,char **argv) {
  if(argc!=2) return 2;
  const std::filesystem::path output=argv[1];
  std::filesystem::create_directories(output);
  lv_init();
  auto *display=lv_display_create(466,466);
  assert(display);
  std::ofstream out(output/"preview.json");
  out << "{\"schema\":1,\"boards\":{";
  int imageIndex=0;
  for (int scenario=0;scenario<8;++scenario) {
    const int board=scenario/4;
    previewSensorMask=scenario%4;
    if(scenario) out << ',';
    const int width=board ? 410 : 466, height=board ? 502 : 466;
    lv_display_set_resolution(display,width,height);
    rideLayout=ride_telemetry_layout::makeLayout(width,height);
    assert(ride_telemetry_layout::isValid(rideLayout));
    ridePage=lv_obj_create(lv_screen_active());
    lv_obj_remove_style_all(ridePage);
    lv_obj_set_size(ridePage,width,height);
    lv_obj_set_pos(ridePage,0,0);
    lv_obj_clear_flag(ridePage,LV_OBJ_FLAG_SCROLLABLE);
    for(std::size_t i=0;i<7;++i) createConfigurableSlot(i);
    verifyLivePairing();
    out << '"' << (board ? "WAVESHARE_AMOLED_206" : "WAVESHARE_AMOLED_175")
        << ":" << previewSensorMask << "\":{\"width\":" << width << ",\"height\":" << height
        << ",\"round\":" << (board ? "false" : "true") << ",\"normal\":{";
    bool first=true;
    for (int slot=0;slot<7;++slot) {
      for (int widget=0;widget<=16;++widget) {
        if(!first) out << ',';
        first=false;
        previewLayout.slots.fill(Widget::Empty);
        previewLayout.slots[slot]=static_cast<Widget>(widget);
        emitSnapshot(out,output,std::to_string(slot)+":"+std::to_string(widget),imageIndex);
      }
    }
    out << "},\"pairs\":{";first=true;
    // Include every right widget whose *resolved* semantics can be altitude.
    // Rendering the entire row also reproduces font changes to a left heart.
    for (int row=0;row<3;++row) {
      for (int left=0;left<=16;++left) {
        for (int right : {7,16}) {
          if(!first) out << ',';
        first=false;
          previewLayout.slots.fill(Widget::Empty);
          previewLayout.slots[row*2+1]=static_cast<Widget>(left);
          previewLayout.slots[row*2+2]=static_cast<Widget>(right);
          emitSnapshot(out,output,std::to_string(row)+":"+std::to_string(left)+":"+
              std::to_string(right),imageIndex);
        }
      }
    }
    out << "}}";
    lv_obj_delete(ridePage);ridePage=nullptr;
  }
  out << "}}\n";
  lv_display_delete(display);
  lv_deinit();
  std::cerr << "Actual LVGL snapshots and live altitude font pairing passed\n";
}
