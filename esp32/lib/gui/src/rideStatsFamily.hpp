/**
 * @file rideStatsFamily.hpp
 * @brief The Ride Stats screen's configurable-slot presentation, implemented
 *        per display family (docs/plans/board-support-architecture-plan.md,
 *        layer 3).
 *
 * rideTelemetryScr.cpp owns the screen, its layout and the zone strips; the
 * family composes the slot widgets and presents each value cell.
 * rideStatsAmoled.cpp keeps the AMOLED widget set with fonts paired across
 * metric columns; rideStatsEpaper.cpp keeps the e-paper set (zone ranges, a
 * fixed sign column and one font box per cell, so no glyph moves between
 * waveforms).
 */

#pragma once

#include "rideTelemetryLayout.hpp"
#include "ride_stats_widget.hpp"

#include <lvgl.h>

#include <array>
#include <cstddef>

namespace ride_stats_family {

using Widget = ride_stats_widget::Widget;
using Model = ride_telemetry_presenter::ViewModel;
using Presentation = ride_stats_widget::Presentation;
constexpr std::size_t kSlotCount = ride_telemetry_layout::kConfigurableSlotCount;
using Presentations = std::array<Presentation, kSlotCount>;
using ValueFonts = std::array<const lv_font_t *, kSlotCount>;

struct SlotObjects {
  lv_obj_t *value;
  lv_obj_t *heart;
  lv_obj_t *sign;  // nullptr where the family has no sign column
};

// Composes the widget of one configured slot.
Presentation make(Widget widget, const Model &model);
// Whether the title of slot `index` carries the widget's unit.
bool unitInTitle(std::size_t index);
// The family's sign label for a slot, or nullptr.
lv_obj_t *createSign(lv_obj_t *page);
// Fonts shared across slots for this update, or nullptr per slot.
ValueFonts valueFonts(const Presentations &widgets,
                      const ride_telemetry_layout::Layout &rideLayout);
// Presents one slot's value cell (title and zone strips are the screen's).
void presentValue(const SlotObjects &slot, std::size_t index,
                  const Presentation &widget, Widget layoutSlot,
                  const Model &model,
                  const ride_telemetry_layout::Layout &rideLayout,
                  const ride_telemetry_layout::Rect &rect,
                  const lv_font_t *sharedFont);

}  // namespace ride_stats_family
