#pragma once

#include "ride_stats_widget.hpp"

namespace epaper_ride_stats {
using Widget = ride_stats_widget::Widget;
using Model = ride_telemetry_presenter::ViewModel;

inline Widget resolvedWidget(Widget widget, const Model &model) {
  if (widget != Widget::SmartMetric1 && widget != Widget::SmartMetric2)
    return widget;
  const auto pair = ride_telemetry_presenter::selectBottomMetrics(model);
  const auto metric = widget == Widget::SmartMetric1 ? pair.left : pair.right;
  using Bottom = ride_telemetry_presenter::BottomMetric;
  switch (metric) {
  case Bottom::WallElapsed: return Widget::ElapsedTime;
  case Bottom::Altitude: return Widget::Altitude;
  case Bottom::RouteRemaining: return Widget::RouteRemaining;
  case Bottom::Power: return Widget::Power;
  case Bottom::Cadence: return Widget::Cadence;
  case Bottom::MaximumSpeed: return Widget::MaximumSpeed;
  case Bottom::Energy: return Widget::Calories;
  }
  return Widget::Empty;
}

// Font selection depends on the widget's complete supported format, never on
// the current sample, availability, or the neighbour's string. Digits have
// equal advances in rideMetricTypography. Include the sign/decimal/colon
// vocabulary so fonts without those glyphs cannot be selected.
inline const char *maximumFormat(Widget widget, const Model &model) {
  switch (resolvedWidget(widget, model)) {
  case Widget::Speed:
  case Widget::AverageSpeed:
  case Widget::MaximumSpeed: return "429496729.5";
  case Widget::Cadence:
  case Widget::Calories: return "6553.5";
  case Widget::HeartRate:
  case Widget::AverageHeartRate:
  case Widget::Power: return "65535";
  case Widget::Altitude: return "-32768";
  case Widget::Distance:
  case Widget::RouteRemaining: return "4294967.3";
  case Widget::MovingTime:
  case Widget::ElapsedTime:
  case Widget::HeartRateZoneTime:
  case Widget::PowerZoneTime: return "1193046:28:15";
  case Widget::HeartRateZoneRange:
  case Widget::PowerZoneRange: return "-8.8888e+38--8.8888e+38";
  default: return "--";
  }
}

inline bool isZoneRange(Widget widget) {
  return widget == Widget::HeartRateZoneRange || widget == Widget::PowerZoneRange;
}

inline ride_stats_widget::Presentation make(Widget widget, const Model &model) {
  widget = resolvedWidget(widget, model);
  auto result = ride_stats_widget::make(widget, model);
  // Keep distance in one unit and one decimal format through metre/km and
  // 9.95/10 km boundaries. Its unit lives in the fixed caption, not the value.
  if (widget == Widget::Distance || widget == Widget::RouteRemaining) {
    const auto metric = widget == Widget::Distance ? model.distanceMeters
                                                 : model.routeRemainingMeters;
    result.unit = "km";
    if (metric.available) {
      const uint64_t tenths = (uint64_t(metric.value) + 50) / 100;
      std::snprintf(result.value.data(), result.value.size(), "%lu.%lu",
                    static_cast<unsigned long>(tenths / 10),
                    static_cast<unsigned long>(tenths % 10));
    }
  }
  return result;
}
} // namespace epaper_ride_stats
