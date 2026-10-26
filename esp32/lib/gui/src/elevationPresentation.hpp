#pragma once

// Pure layout, chart projection and text for the Elevation screen. The chart
// only projects the phone's display points; values (elevation, grade, ascent)
// are shown exactly as the phone computed them from the canonical profile.

#include "../../route_elevation/route_elevation_protocol.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace elevation_presentation {

namespace rep = route_elevation_protocol;

inline constexpr int32_t MAXIMUM_CHART_WIDTH = 360;
inline constexpr int32_t MINIMUM_VERTICAL_SPAN_M = 40;
inline constexpr int32_t CHART_TOP_PADDING_PX = 8;

struct Rect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;
};

struct Layout {
  Rect primaryLeft;
  Rect primaryRight;
  Rect secondaryLeft;
  Rect secondaryRight;
  Rect chart;
  Rect footer;
  Rect message;
};

// The 466 px round panel needs the chart's corners inside the circle; the
// rectangular 2.06-inch layout is kept compatible but is not the qualified target.
constexpr Layout makeLayout(int32_t width, int32_t height) {
  const bool round = width == 466 && height == 466;
  Layout layout{};
  const int32_t chartWidth = round ? 350 : (width - 40 < MAXIMUM_CHART_WIDTH ? width - 40 : MAXIMUM_CHART_WIDTH);
  const int32_t chartX = (width - chartWidth) / 2;
  const int32_t top = round ? 58 : 40;
  const int32_t columnWidth = round ? 140 : (width - 40) / 2;
  const int32_t columnGap = round ? 8 : 0;
  layout.primaryLeft = {width / 2 - columnGap / 2 - columnWidth, top, columnWidth, 72};
  layout.primaryRight = {width / 2 + columnGap / 2, top, columnWidth, 72};
  layout.secondaryLeft = {width / 2 - columnGap / 2 - columnWidth, top + 82, columnWidth, 58};
  layout.secondaryRight = {width / 2 + columnGap / 2, top + 82, columnWidth, 58};
  layout.chart = {chartX, round ? 212 : top + 160, chartWidth, round ? 152 : height - (top + 160) - 70};
  layout.footer = {width / 2 - 160, layout.chart.y + layout.chart.height + 12, 320, 22};
  layout.message = {chartX, layout.chart.y + layout.chart.height / 2 - 30, chartWidth, 60};
  return layout;
}

constexpr bool insideCircle(int32_t x, int32_t y, int32_t diameter) {
  const int32_t radius = diameter / 2;
  const int32_t dx = x - radius;
  const int32_t dy = y - radius;
  return dx * dx + dy * dy <= radius * radius;
}

constexpr bool rectFitsCircle(const Rect &rect, int32_t diameter, int32_t inset = 8) {
  return insideCircle(rect.x - inset, rect.y - inset, diameter) &&
         insideCircle(rect.x + rect.width + inset, rect.y - inset, diameter) &&
         insideCircle(rect.x - inset, rect.y + rect.height + inset, diameter) &&
         insideCircle(rect.x + rect.width + inset, rect.y + rect.height + inset, diameter);
}

enum class ColumnStyle : uint8_t { Unknown = 0, Measured = 1, Estimated = 2, LowConfidence = 3 };

struct Column {
  int16_t top = 0;
  ColumnStyle style = ColumnStyle::Unknown;
  uint8_t gradeBand = 0;
};

struct Chart {
  int32_t width = 0;
  int32_t height = 0;
  int32_t minimumM = 0;
  int32_t maximumM = 0;
  std::array<Column, MAXIMUM_CHART_WIDTH> columns{};
};

constexpr int32_t projectY(int32_t elevationM, int32_t minimumM, int32_t maximumM, int32_t height) {
  const int32_t usable = height - CHART_TOP_PADDING_PX;
  const int32_t span = maximumM - minimumM;
  if (span <= 0 || usable <= 0) {
    return height - 1;
  }
  const int64_t scaled = static_cast<int64_t>(elevationM - minimumM) * (usable - 1) / span;
  return height - 1 - static_cast<int32_t>(scaled);
}

// Linear interpolation of the display polyline at each pixel column. A column
// is unknown when either neighbouring display point is unknown: gaps are never
// bridged or drawn as zero.
inline void buildChart(const rep::Profile &profile, int32_t width, int32_t height, Chart &chart) {
  chart.width = width > MAXIMUM_CHART_WIDTH ? MAXIMUM_CHART_WIDTH : width;
  chart.height = height;
  int32_t minimum = INT32_MAX;
  int32_t maximum = INT32_MIN;
  for (std::size_t index = 0; index < profile.pointCount; ++index) {
    const int16_t value = profile.points[index].elevationM;
    if (value == rep::UNKNOWN_ELEVATION) continue;
    minimum = value < minimum ? value : minimum;
    maximum = value > maximum ? value : maximum;
  }
  for (Column &column : chart.columns) {
    column = {};
  }
  if (minimum > maximum || profile.totalDistanceM == 0 || chart.width <= 1) {
    chart.minimumM = 0;
    chart.maximumM = 0;
    return;
  }
  if (maximum - minimum < MINIMUM_VERTICAL_SPAN_M) {
    // Do not exaggerate a flat route into hills.
    const int32_t centre = (maximum + minimum) / 2;
    minimum = centre - MINIMUM_VERTICAL_SPAN_M / 2;
    maximum = minimum + MINIMUM_VERTICAL_SPAN_M;
  }
  chart.minimumM = minimum;
  chart.maximumM = maximum;
  std::size_t segment = 0;
  for (int32_t x = 0; x < chart.width; ++x) {
    const uint64_t distance =
        static_cast<uint64_t>(profile.totalDistanceM) * static_cast<uint64_t>(x) / static_cast<uint64_t>(chart.width - 1);
    while (segment + 2 < profile.pointCount && profile.points[segment + 1].distanceM < distance) {
      ++segment;
    }
    const rep::Point &start = profile.points[segment];
    const rep::Point &end = profile.points[segment + 1 < profile.pointCount ? segment + 1 : segment];
    Column &column = chart.columns[static_cast<std::size_t>(x)];
    if (start.elevationM == rep::UNKNOWN_ELEVATION || end.elevationM == rep::UNKNOWN_ELEVATION) {
      continue;
    }
    const uint32_t run = end.distanceM - start.distanceM;
    int32_t elevation = start.elevationM;
    if (run > 0 && distance > start.distanceM) {
      const int64_t numerator = static_cast<int64_t>(end.elevationM - start.elevationM) *
                                static_cast<int64_t>(distance - start.distanceM);
      elevation = start.elevationM + static_cast<int32_t>(numerator / static_cast<int64_t>(run));
    }
    column.top = static_cast<int16_t>(projectY(elevation, minimum, maximum, height));
    const uint8_t flags = end.flags;
    column.gradeBand = flags & rep::POINT_GRADE_BAND_MASK;
    if ((flags & rep::POINT_FLAG_LOW_CONFIDENCE) != 0) {
      column.style = ColumnStyle::LowConfidence;
    } else if ((flags & rep::POINT_FLAG_ESTIMATED) != 0) {
      column.style = ColumnStyle::Estimated;
    } else {
      column.style = ColumnStyle::Measured;
    }
  }
}

// Marker x from the phone's along-route progress; -1 when unknown.
constexpr int32_t markerX(uint32_t progressM, uint32_t totalDistanceM, int32_t width) {
  if (progressM == rep::UNKNOWN_PROGRESS || totalDistanceM == 0 || width <= 1) {
    return -1;
  }
  const uint32_t clamped = progressM > totalDistanceM ? totalDistanceM : progressM;
  return static_cast<int32_t>(static_cast<uint64_t>(clamped) * static_cast<uint64_t>(width - 1) / totalDistanceM);
}

inline uint32_t gradeColor(uint8_t band) {
  switch (band) {
  case 3: return 0x35D46F;
  case 4: return 0xC8D84A;
  case 5: return 0xF6B73C;
  case 6: return 0xFF8A3D;
  case 7: return 0xFF372E;
  default: return 0x2F7FD8;
  }
}

enum class ScreenState : uint8_t { PhoneDisconnected, AppUpdateNeeded, NoRoute, Loading, Unavailable, Ready };

struct Status {
  ScreenState state = ScreenState::PhoneDisconnected;
  const char *headline = "";
  const char *detail = "";
};

inline const char *reasonText(rep::Reason reason) {
  switch (reason) {
  case rep::Reason::Offline: return "Phone is offline";
  case rep::Reason::SourceNotPermitted: return "Not available for this route";
  case rep::Reason::ServiceUnavailable: return "Elevation service unavailable";
  case rep::Reason::QuotaExhausted: return "Daily limit reached";
  case rep::Reason::NoCoverage: return "No elevation data here";
  case rep::Reason::TransferFailed: return "Transfer failed";
  case rep::Reason::RouteTooLong: return "Route too long";
  case rep::Reason::Unspecified: break;
  }
  return "";
}

inline Status status(bool phoneConnected, bool sessionSupportsProfiles, const rep::Session::Binding &binding,
                     bool hasProfile) {
  if (!phoneConnected) {
    return {ScreenState::PhoneDisconnected, "Connect the Bicino app", "Elevation comes from your phone"};
  }
  if (!sessionSupportsProfiles) {
    return {ScreenState::AppUpdateNeeded, "Update the Bicino app", "for route elevation"};
  }
  if (hasProfile && binding.state == rep::ProfileState::Ready) {
    return {ScreenState::Ready, "", ""};
  }
  switch (binding.state) {
  case rep::ProfileState::Loading:
    return {ScreenState::Loading, "Loading elevation...", ""};
  case rep::ProfileState::Unavailable:
  case rep::ProfileState::Failed:
    return {ScreenState::Unavailable, "Elevation unavailable", reasonText(binding.reason)};
  case rep::ProfileState::Cleared:
  case rep::ProfileState::Ready:
    break;
  }
  return {ScreenState::NoRoute, "No route", "Start navigation to see elevation"};
}

// ASCII only: the built-in fonts have no approximately-equal or >= glyphs.
// "~" marks estimated values; "+" marks a total that is only a lower bound.
inline void formatMeters(char *buffer, std::size_t size, int32_t value, bool estimated, bool lowerBound) {
  std::snprintf(buffer, size, "%s%ld%s m", estimated ? "~" : "", static_cast<long>(value), lowerBound ? "+" : "");
}

inline void formatGrade(char *buffer, std::size_t size, int16_t deciPercent, bool estimated) {
  const int32_t magnitude = deciPercent < 0 ? -deciPercent : deciPercent;
  std::snprintf(buffer, size, "%s%s%ld.%ld%%", estimated ? "~" : "", deciPercent < 0 ? "-" : "",
                static_cast<long>(magnitude / 10), static_cast<long>(magnitude % 10));
}

inline void footerText(char *buffer, std::size_t size, const rep::Profile &profile) {
  const char *quality = "";
  if ((profile.flags & rep::BODY_FLAG_AMBIGUOUS_STRUCTURES) != 0) {
    quality = "Uncertain bridges";
  } else if ((profile.flags & rep::BODY_FLAG_PARTIAL) != 0) {
    quality = "Partial elevation";
  } else if ((profile.flags & rep::BODY_FLAG_INCLUDES_ESTIMATED) != 0) {
    quality = "Some estimated";
  }
  std::snprintf(buffer, size, "%s", quality);
}

} // namespace elevation_presentation
