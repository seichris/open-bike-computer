#include "../../lib/maps/src/mapPresentation.hpp"

#include <cassert>
#include <cmath>

int main() {
  using namespace map_presentation;

  assert(normalizeDegrees(-1.0) == 359.0);
  assert(std::fabs(signedHeadingDelta(359.0, 1.0) - 2.0) < 1e-9);
  assert(std::fabs(signedHeadingDelta(1.0, 359.0) + 2.0) < 1e-9);


  // Base pixels, route geometry, and current-position markers share one affine
  // transform: rotate around the old projected rider, then translate that
  // pivot to the live viewport anchor (which has overscan removed).
  const ScreenPoint pivot{196.0, 256.0};
  const ScreenPoint anchor{100.0, 140.0};
  const ScreenPoint pivotPresented =
      presentFramePoint(pivot, pivot, anchor, kPi / 2.0);
  assert(std::fabs(pivotPresented.x - anchor.x) < 1e-9);
  assert(std::fabs(pivotPresented.y - anchor.y) < 1e-9);
  const ScreenPoint eastOfPivot =
      presentFramePoint({206.0, 256.0}, pivot, anchor, kPi / 2.0);
  assert(std::fabs(eastOfPivot.x - 100.0) < 1e-9);
  assert(std::fabs(eastOfPivot.y - 150.0) < 1e-9);
  const ScreenPoint translatedOnly =
      presentFramePoint({210.0, 260.0}, pivot, anchor, 0.0);
  assert(std::fabs(translatedOnly.x - 114.0) < 1e-9);
  assert(std::fabs(translatedOnly.y - 144.0) < 1e-9);

  HeadingResolver resolver;
  double heading = -1.0;
  resolver.setNavigationSession(true, 7);
  assert(resolver.resolve(true, 358.0, true, 90.0, heading));
  assert(heading == 358.0);
  assert(resolver.source() == HeadingResolver::Source::Measured);
  assert(resolver.resolve(false, -1.0, true, 2.0, heading));
  assert(heading == 2.0);
  assert(resolver.source() == HeadingResolver::Source::Route);
  assert(resolver.resolve(false, -1.0, false, 0.0, heading));
  assert(heading == 2.0);
  assert(resolver.source() == HeadingResolver::Source::Remembered);

  // A mode/session epoch change cannot inherit a stale heading and silently
  // turn an invalid course into north-up.
  resolver.setNavigationSession(true, 8);
  assert(!resolver.resolve(false, -1.0, false, 0.0, heading));
  resolver.setNavigationSession(false, 9);
  assert(!resolver.resolve(true, 0.0, true, 90.0, heading));

  Presenter::Config config;
  config.maximumPredictionMs = 1500;
  config.convergenceMs = 0;
  config.maximumPredictionMeters = 20;
  Presenter presenter(config);
  presenter.observe({{100.0, 200.0}, 90.0, true, 10.0, 1.0, 1000},
                    1000);
  PresentedPose afterHalfSecond = presenter.present(1500);
  assert(std::fabs(afterHalfSecond.position.x - 105.0) < 1e-6);
  assert(std::fabs(afterHalfSecond.position.y - 200.0) < 1e-6);
  PresentedPose capped = presenter.present(9000);
  assert(std::fabs(capped.position.x - 115.0) < 1e-6);
  assert(capped.predictionAgeMs == 1500);

  // The finite prediction limit is expressed in physical metres even though
  // Web Mercator world coordinates stretch by sec(latitude).
  Presenter scaled(config);
  scaled.observe({{100.0, 200.0}, 90.0, true, 20.0, 2.0, 1000}, 1000);
  const PresentedPose scaledCapped = scaled.present(9000);
  // The 20 metre physical cap becomes 40 world units at this local scale.
  assert(std::fabs(scaledCapped.position.x - 140.0) < 1e-6);

  // A correction converges instead of leaving disconnected dead reckoning.
  config.convergenceMs = 400;
  Presenter converging(config);
  converging.observe({{0.0, 0.0}, 359.0, true, 0.0, 1.0, 0}, 0);
  converging.observe({{10.0, 0.0}, 1.0, true, 0.0, 1.0, 1000},
                     1000);
  const PresentedPose halfway = converging.present(1200);
  assert(halfway.position.x > 0.0 && halfway.position.x < 10.0);
  assert(halfway.headingDegrees < 2.0 || halfway.headingDegrees > 358.0);
  const PresentedPose settled = converging.present(1400);
  assert(std::fabs(settled.position.x - 10.0) < 1e-6);
  assert(std::fabs(settled.headingDegrees - 1.0) < 1e-6);

  // A fix without a course must preserve the last valid direction rather
  // than treating its zero-initialized heading as north-up.
  Presenter missingCourse(config);
  missingCourse.observe({{0.0, 0.0}, 90.0, true, 0.0, 1.0, 0}, 0);
  missingCourse.observe({{1.0, 0.0}, 0.0, false, 0.0, 1.0, 1000}, 1000);
  const PresentedPose missingCoursePose = missingCourse.present(1400);
  assert(missingCoursePose.headingValid);
  assert(std::fabs(missingCoursePose.headingDegrees - 90.0) < 1e-6);

  assert(std::fabs(refreshLeadPixels(10.0, 2.0, 1200, 16.0, 32.0, 96.0) -
                   40.0) < 1e-9);
  assert(refreshLeadPixels(100.0, 10.0, 5000, 16.0, 32.0, 96.0) == 96.0);
  return 0;
}
