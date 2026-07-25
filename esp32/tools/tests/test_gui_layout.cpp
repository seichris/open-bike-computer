#include "../../lib/gui/src/guiLayout.hpp"
#include "../../lib/gui/src/rideTelemetryLayout.hpp"

#include <cassert>

int main() {
#if defined(WAVESHARE_AMOLED_206)
  // 2.06-inch viewport: 502px screen with 72px reserved UI space.
  assert(gui_layout::mapViewportHeight(502) == 430);
  assert(gui_layout::mapScreenAnchorX(410, 410) == 205);
  assert(gui_layout::mapScreenAnchorY(502, 430) == 251);
  assert(gui_layout::mapScreenAnchorY(502, 502) == 251);
  constexpr auto rideLayout = ride_telemetry_layout::makeLayout(410, 502);
#else
  // 1.75-inch viewport: 466px screen with 100px reserved UI space.
  assert(gui_layout::mapViewportHeight(466) == 366);
  assert(gui_layout::mapScreenAnchorX(466, 466) == 233);
  assert(gui_layout::mapScreenAnchorY(466, 366) == 233);
  assert(gui_layout::mapScreenAnchorY(466, 466) == 233);
  constexpr auto rideLayout = ride_telemetry_layout::makeLayout(466, 466);
#endif
  static_assert(ride_telemetry_layout::isValid(rideLayout));
  assert(rideLayout.metrics.size() == 6);
  assert(rideLayout.metrics[0].right() <= rideLayout.metrics[1].x);
  assert(rideLayout.metrics[3].bottom() <= rideLayout.metrics[4].y);
  for (const auto &metric : rideLayout.metrics) {
    assert(ride_telemetry_layout::fits(
        metric, rideLayout.screenWidth, rideLayout.screenHeight));
  }
  return 0;
}
