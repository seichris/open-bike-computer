#include "../../lib/maps/src/mapPresentation.hpp"

#include <cassert>
#include <cmath>

int main() {
  using namespace map_presentation;

  assert(normalizeDegrees(-1.0) == 359.0);
  assert(std::fabs(signedHeadingDelta(359.0, 1.0) - 2.0) < 1e-9);
  assert(std::fabs(signedHeadingDelta(1.0, 359.0) + 2.0) < 1e-9);
  assert(std::fabs(markerRotationDegrees(90.0, 0.0) - 90.0) < 1e-9);
  assert(std::fabs(markerRotationDegrees(90.0, -kPi / 2.0)) < 1e-9);


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
  assert(frameCoversViewport(658.0, 658.0, 466.0, 466.0,
                             {329.0, 329.0}, {233.0, 233.0}, 0.0, 16.0));
  assert(frameCoversViewport(658.0, 658.0, 466.0, 466.0,
                             {405.0, 329.0}, {233.0, 233.0}, 0.0, 16.0));
  assert(!frameCoversViewport(658.0, 658.0, 466.0, 466.0,
                              {420.0, 329.0}, {233.0, 233.0}, 0.0, 16.0));
  assert(!frameCoversViewport(658.0, 658.0, 466.0, 466.0,
                              {329.0, 329.0}, {233.0, 233.0}, kPi / 4.0,
                              16.0));

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

  // Version-10 apps encoded a missing course as zero. New firmware detects
  // that legacy negotiation and resolves route-first instead of facing north.
  assert(resolver.resolve(true, 0.0, true, 90.0, heading, true));
  assert(heading == 90.0);
  assert(resolver.source() == HeadingResolver::Source::Route);

  // A mode/session epoch change cannot inherit a stale heading and silently
  // turn an invalid course into north-up.
  resolver.setNavigationSession(true, 8);
  assert(!resolver.resolve(false, -1.0, false, 0.0, heading));
  resolver.setNavigationSession(false, 9);
  assert(!resolver.resolve(true, 0.0, true, 90.0, heading));

  // The default policy keeps the normal 1.5-second full-speed window, then
  // decelerates through a 2.5-second hard horizon. A two-second gap (one
  // missed 1 Hz heartbeat) therefore remains continuous, while longer loss
  // settles at a finite position.
  Presenter::Config graceConfig;
  assert(graceConfig.fullSpeedPredictionMs == 1500);
  assert(graceConfig.maximumPredictionMs == 2500);
  assert(graceConfig.maximumPredictionMeters == 70.0);
  graceConfig.convergenceMs = 0;
  Presenter heartbeatGrace(graceConfig);
  heartbeatGrace.observe(
      {{100.0, 200.0}, 90.0, true, 10.0, 1.0, 1000}, 1000);
  const PresentedPose healthyHeartbeat = heartbeatGrace.present(2000);
  assert(std::fabs(healthyHeartbeat.position.x - 110.0) < 1e-6);
  assert(healthyHeartbeat.observationAgeMs == 1000);
  assert(!healthyHeartbeat.predictionGraceActive);
  assert(!healthyHeartbeat.predictionExhausted);
  const PresentedPose oneMissedHeartbeat = heartbeatGrace.present(3000);
  assert(std::fabs(oneMissedHeartbeat.position.x - 118.75) < 1e-6);
  assert(oneMissedHeartbeat.observationAgeMs == 2000);
  assert(oneMissedHeartbeat.predictionAgeMs == 2000);
  assert(oneMissedHeartbeat.predictionGraceActive);
  assert(!oneMissedHeartbeat.predictionExhausted);
  const PresentedPose graceHorizon = heartbeatGrace.present(3500);
  assert(std::fabs(graceHorizon.position.x - 120.0) < 1e-6);
  assert(graceHorizon.observationAgeMs == 2500);
  assert(graceHorizon.predictionAgeMs == 2500);
  assert(!graceHorizon.predictionGraceActive);
  assert(graceHorizon.predictionExhausted);
  const PresentedPose longTransportLoss = heartbeatGrace.present(9000);
  assert(std::fabs(longTransportLoss.position.x -
                   graceHorizon.position.x) < 1e-6);
  assert(longTransportLoss.observationAgeMs == 8000);
  assert(longTransportLoss.predictionAgeMs == 2500);
  assert(longTransportLoss.predictionExhausted);

  // The default distance guard is derived from the supported 35 m/s speed and
  // integrated horizon. A credible 20 m/s descent therefore stays continuous
  // through one missed heartbeat and stops only at the hard time horizon.
  Presenter highSpeedHeartbeat(graceConfig);
  highSpeedHeartbeat.observe(
      {{0.0, 0.0}, 90.0, true, 20.0, 1.0, 1000}, 1000);
  const PresentedPose highSpeedMiss = highSpeedHeartbeat.present(3000);
  assert(std::fabs(highSpeedMiss.position.x - 37.5) < 1e-6);
  assert(highSpeedMiss.predictionGraceActive);
  assert(!highSpeedMiss.predictionExhausted);
  const PresentedPose highSpeedHorizon = highSpeedHeartbeat.present(3500);
  assert(std::fabs(highSpeedHorizon.position.x - 40.0) < 1e-6);
  assert(highSpeedHorizon.predictionExhausted);

  Presenter maximumSupportedSpeed(graceConfig);
  maximumSupportedSpeed.observe(
      {{0.0, 0.0}, 90.0, true, 35.0, 1.0, 1000}, 1000);
  const PresentedPose maximumSpeedMiss = maximumSupportedSpeed.present(3000);
  assert(std::fabs(maximumSpeedMiss.position.x - 65.625) < 1e-6);
  assert(maximumSpeedMiss.predictionGraceActive);
  assert(!maximumSpeedMiss.predictionExhausted);
  const PresentedPose justBeforeMaximumHorizon =
      maximumSupportedSpeed.present(3499);
  assert(!justBeforeMaximumHorizon.predictionExhausted);
  const PresentedPose maximumSpeedHorizon =
      maximumSupportedSpeed.present(3500);
  assert(std::fabs(maximumSpeedHorizon.position.x - 70.0) < 1e-6);
  assert(maximumSpeedHorizon.predictionExhausted);

  // A route-bearing update can rotate presentation but cannot redefine the
  // positional path owned by the last physical fix. Once stale motion is
  // exhausted it cannot move the shared map/route/marker pose to a new endpoint.
  Presenter::Config headingOnlyConfig;
  Presenter headingOnly(headingOnlyConfig);
  headingOnly.observe(
      {{0.0, 0.0}, 90.0, true, 10.0, 1.0, 1000}, 1000);
  const PresentedPose exhaustedEast = headingOnly.present(3500);
  assert(std::fabs(exhaustedEast.position.x - 20.0) < 1e-6);
  assert(std::fabs(exhaustedEast.position.y) < 1e-6);
  assert(exhaustedEast.predictionExhausted);
  headingOnly.updateHeading(0.0, true, 4000);
  const PresentedPose headingChangedAtStart = headingOnly.present(4000);
  const PresentedPose headingChangedSettled = headingOnly.present(4350);
  for (const PresentedPose &pose :
       {headingChangedAtStart, headingChangedSettled}) {
    assert(std::fabs(pose.position.x - exhaustedEast.position.x) < 1e-6);
    assert(std::fabs(pose.position.y - exhaustedEast.position.y) < 1e-6);
    assert(pose.predictionExhausted);
  }
  assert(std::fabs(headingChangedSettled.headingDegrees) < 1e-6);

  Presenter headingDuringPrediction(headingOnlyConfig);
  headingDuringPrediction.observe(
      {{0.0, 0.0}, 90.0, true, 10.0, 1.0, 1000}, 1000);
  const PresentedPose fiveMetersEast = headingDuringPrediction.present(1500);
  assert(std::fabs(fiveMetersEast.position.x - 5.0) < 1e-6);
  headingDuringPrediction.updateHeading(0.0, true, 1500);
  const PresentedPose halfwayThroughHeading =
      headingDuringPrediction.present(1675);
  assert(std::fabs(halfwayThroughHeading.position.x - 6.75) < 1e-6);
  assert(std::fabs(halfwayThroughHeading.position.y) < 1e-6);
  assert(std::fabs(halfwayThroughHeading.headingDegrees - 45.0) < 1e-6);
  const PresentedPose continuedAlongPhysicalFix =
      headingDuringPrediction.present(1850);
  assert(std::fabs(continuedAlongPhysicalFix.position.x - 8.5) < 1e-6);
  assert(std::fabs(continuedAlongPhysicalFix.position.y) < 1e-6);
  assert(std::fabs(continuedAlongPhysicalFix.headingDegrees) < 1e-6);

  // Receiving route/heading work later must not make an old physical fix
  // fresh. The source timestamp, not the UI observation time, owns the
  // prediction horizon.
  Presenter delayedObservation(graceConfig);
  delayedObservation.observe(
      {{0.0, 0.0}, 90.0, true, 10.0, 1.0, 1000}, 1800);
  const PresentedPose delayedPose = delayedObservation.present(3000);
  assert(delayedPose.observationAgeMs == 2000);
  assert(delayedPose.predictionGraceActive);

  Presenter::Config config;
  config.fullSpeedPredictionMs = 1500;
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
  assert(capped.observationAgeMs == 8000);
  assert(capped.predictionAgeMs == 1500);
  assert(capped.predictionExhausted);

  // The finite prediction limit is expressed in physical metres even though
  // Web Mercator world coordinates stretch by sec(latitude).
  Presenter scaled(config);
  scaled.observe({{100.0, 200.0}, 90.0, true, 20.0, 2.0, 1000}, 1000);
  const PresentedPose scaledCapped = scaled.present(9000);
  // The 20 metre physical cap becomes 40 world units at this local scale.
  assert(std::fabs(scaledCapped.position.x - 140.0) < 1e-6);
  assert(scaledCapped.predictionExhausted);

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
  missingCourse.resetHeading(1500);
  missingCourse.observe({{2.0, 0.0}, 0.0, false, 0.0, 1.0, 1500}, 1500);
  const PresentedPose resetMissingCourse = missingCourse.present(1900);
  assert(!resetMissingCourse.headingValid);
  missingCourse.observe({{3.0, 0.0}, 180.0, true, 0.0, 1.0, 2000}, 2000);
  const PresentedPose newEpochHeading = missingCourse.present(2400);
  assert(newEpochHeading.headingValid);
  assert(std::fabs(newEpochHeading.headingDegrees - 180.0) < 1e-6);

  // Resetting a heading epoch freezes the currently presented prediction. It
  // must not jump back to the raw fix before the replacement heading/fix can
  // converge.
  Presenter headingEpoch(config);
  headingEpoch.observe({{0.0, 0.0}, 90.0, true, 10.0, 1.0, 0}, 0);
  const PresentedPose predictedBeforeReset = headingEpoch.present(500);
  assert(std::fabs(predictedBeforeReset.position.x - 5.0) < 1e-6);
  headingEpoch.resetHeading(500);
  const PresentedPose frozenAfterReset = headingEpoch.present(500);
  assert(!frozenAfterReset.headingValid);
  assert(std::fabs(frozenAfterReset.position.x -
                   predictedBeforeReset.position.x) < 1e-6);
  headingEpoch.observe({{0.0, 0.0}, 180.0, true, 0.0, 1.0, 500}, 500);
  const PresentedPose resetConvergenceStart = headingEpoch.present(500);
  assert(std::fabs(resetConvergenceStart.position.x -
                   predictedBeforeReset.position.x) < 1e-6);

  assert(std::fabs(refreshLeadPixels(10.0, 2.0, 1200, 16.0, 32.0, 96.0) -
                   40.0) < 1e-9);
  assert(refreshLeadPixels(100.0, 10.0, 5000, 16.0, 32.0, 96.0) == 96.0);
  return 0;
}
