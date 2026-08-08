#include "../../lib/maps/src/mapTransform.hpp"
#include "../../lib/gui/src/guiLayout.hpp"
#include "../../lib/utils/src/mapPinchZoom.hpp"
#include "../../lib/utils/src/mapTapArbiter.hpp"
#include "../../lib/utils/src/mapDragPreview.hpp"
#include "../../lib/utils/src/mapRasterWindow.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <vector>

using map_pinch_zoom::Action;
using map_pinch_zoom::Controller;
using map_pinch_zoom::Frame;

namespace {

constexpr double kTolerance = 0.0001;

Frame frame(uint32_t sequence, uint8_t count, int16_t firstX = 100,
            int16_t secondX = 200, uint8_t firstId = 1,
            uint8_t secondId = 2) {
  Frame value;
  value.sequence = sequence;
  value.count = count;
  value.contacts[0] = {firstId, firstX, 150};
  value.contacts[1] = {secondId, secondX, 150};
  return value;
}

void assertNear(double actual, double expected) {
  assert(std::fabs(actual - expected) < kTolerance);
}

} // namespace

int main() {
  using namespace map_transform;
  assertNear(worldToScreenScale(1), 1.5);
  assertNear(worldToScreenScale(2), 1.0);
  assertNear(worldToScreenScale(3), 0.5);
  assertNear(worldToScreenScale(4), 1.0 / 3.0);
  assertNear(worldToScreenScale(5), 0.25);
  assert(clampRuntimeZoom(0) == 1);
  assert(clampRuntimeZoom(6) == 5);
  assert(nearestRuntimeZoom(1.49) == 1);
  assert(nearestRuntimeZoom(1.01) == 2);
  assert(nearestRuntimeZoom(0.51) == 3);
  assert(nearestRuntimeZoom(0.34) == 4);
  assert(nearestRuntimeZoom(0.24) == 5);
  assertNear(backdropPresentationRatio(1.0, 1, 5), 6.0);
  assertNear(backdropPresentationRatio(0.5, 2, 5), 2.0);
  assertNear(backdropPresentationRatio(0.25, 2, 5), 1.0);

  const WorldPoint world = {30.0, -40.0};
  for (uint8_t zoom = 1; zoom <= 5; ++zoom) {
    for (double rotation : {0.0, 0.5, -1.2}) {
      const ScreenDelta screen = worldToScreen(world, zoom, rotation);
      const WorldPoint roundTrip = screenToWorld(screen, zoom, rotation);
      assertNear(roundTrip.x, world.x);
      assertNear(roundTrip.y, world.y);
    }
  }

  // Every rolling cell retains one global subpixel phase. A world point must
  // land on the same assembled pixel whether rendered by the center cell or a
  // neighboring cell, including rotated and half-pixel cases.
  const WorldPoint rasterOrigin = {1234.25, -987.5};
  for (uint8_t zoom = 1; zoom <= 5; ++zoom) {
    const int32_t cellExtent = zoom == 5 ? 192 : 128;
    for (double rasterRotation : {0.0, 0.5, -1.2}) {
      for (const PixelOffset cellOffset :
           {PixelOffset{cellExtent, 0}, PixelOffset{-cellExtent, 0},
            PixelOffset{0, cellExtent}, PixelOffset{0, -cellExtent}}) {
        for (const WorldPoint sample :
             {WorldPoint{274.0, -91.5}, WorldPoint{-0.5, 0.5},
              WorldPoint{4096.25, -2048.75}}) {
          const PixelOffset fromOrigin = rasterCellPixel(
              sample, rasterOrigin, {0, 0}, zoom, rasterRotation);
          const PixelOffset fromCell = rasterCellPixel(
              sample, rasterOrigin, cellOffset, zoom, rasterRotation);
          assert(fromOrigin.x == cellOffset.x + fromCell.x);
          assert(fromOrigin.y == cellOffset.y + fromCell.y);
        }
      }
    }
  }

  // Regression: at zoom 1, deriving the left cell's world-space center and
  // projecting it back turns the shared -382.5 tie into
  // -254.50000000000003. Common-origin quantization must still assemble the
  // feature at exactly the center cell's pixel.
  const PixelOffset zoomOneCenter =
      rasterCellPixel({-255.0, 0.0}, {0.0, 0.0}, {0, 0}, 1, 0.0);
  const PixelOffset zoomOneLeft =
      rasterCellPixel({-255.0, 0.0}, {0.0, 0.0}, {-128, 0}, 1, 0.0);
  assert(zoomOneCenter.x == -382);
  assert(-128 + zoomOneLeft.x == zoomOneCenter.x);

  // Regression across a recycle generation: retained pixels are shifted by
  // an exact cell width, while the replacement edge must keep quantizing
  // against the original phase origin. Re-quantizing against the derived
  // logical origin crosses this same half tie.
  const PixelOffset zoomOneAfterLeftRecycle =
      rasterCellPixel({-255.0, 0.0}, {0.0, 0.0}, {-128, 0}, 1, 0.0);
  assert(zoomOneCenter.x + 128 == zoomOneAfterLeftRecycle.x);
  const WorldPoint derivedRecycledOrigin =
      screenToWorld({-128.0, 0.0}, 1, 0.0);
  const ScreenDelta legacyRecycledProjection = worldToScreen(
      {-255.0 - derivedRecycledOrigin.x,
       -derivedRecycledOrigin.y},
      1, 0.0);
  assert(quantizePixel(legacyRecycledProjection.x) == -255);
  assert(quantizePixel(legacyRecycledProjection.x) !=
         zoomOneAfterLeftRecycle.x);

  // Regression: std::round() chooses opposite directions for the +68.5 and
  // -123.5 views of this same zoom-5 point, producing a one-pixel seam.
  assert(quantizePixel(274.0 * 0.25) ==
         192 + quantizePixel((274.0 - 768.0) * 0.25));

  // A completed X recycle is an authoritative checkpoint even if the Y edge
  // is interrupted. Recomputing the canvas offset from the new origin keeps
  // the same logical center-to-screen mapping for the immediate next drag.
  const WorldPoint checkpointCenter = {1800.0, -700.0};
  const WorldPoint checkpointOrigin = {1600.0, -900.0};
  const uint8_t checkpointZoom = 4;
  const double checkpointRotation = 0.5;
  const auto oldPlacement = rasterCenterOffset(
      checkpointCenter, checkpointOrigin, checkpointZoom, checkpointRotation);
  const WorldPoint checkpointShift = screenToWorld(
      {128.0, 0.0}, checkpointZoom, checkpointRotation);
  const WorldPoint shiftedOrigin = {checkpointOrigin.x + checkpointShift.x,
                                    checkpointOrigin.y + checkpointShift.y};
  const auto shiftedPlacement = rasterCenterOffset(
      checkpointCenter, shiftedOrigin, checkpointZoom, checkpointRotation);
  assert(oldPlacement.x - shiftedPlacement.x == 128);
  assert(oldPlacement.y == shiftedPlacement.y);

  const WorldPoint initialCenter = {1000.0, 2000.0};
  const ScreenDelta initialFocal = {50.0, -25.0};
  const ScreenDelta finalFocal = {70.0, 15.0};
  const double rotation = -0.7;
  const WorldPoint adjusted = focalPreservingCenter(
      initialCenter, initialFocal, finalFocal, 3, 2, rotation);
  const WorldPoint focalBeforeOffset =
      screenToWorld(initialFocal, 3, rotation);
  const WorldPoint focalAfterOffset = screenToWorld(finalFocal, 2, rotation);
  assertNear(initialCenter.x + focalBeforeOffset.x,
             adjusted.x + focalAfterOffset.x);
  assertNear(initialCenter.y + focalBeforeOffset.y,
             adjusted.y + focalAfterOffset.y);

  // A course-up heading update during pinch settlement must not change the
  // rotation used by focal anchoring. It is explicitly scheduled afterward.
  const double frozenRotation = -0.4;
  const double newerRotation = -1.1;
  assertNear(renderRotationForSettlement(true, frozenRotation, newerRotation),
             frozenRotation);
  assertNear(renderRotationForSettlement(false, frozenRotation, newerRotation),
             newerRotation);
  assert(rotationNeedsRefresh(frozenRotation, newerRotation));
  assert(!rotationNeedsRefresh(frozenRotation, frozenRotation));

  // Drag presentation updates the authoritative center on every frame. A
  // second session therefore starts from the first session's live endpoint,
  // even if raster settlement has not run between the two sessions.
  const ScreenDelta firstDrag = {63.0, -27.0};
  const ScreenDelta secondDrag = {-14.0, 31.0};
  const WorldPoint firstDragCenter =
      centerAfterScreenDrag(initialCenter, firstDrag, 4, rotation);
  const WorldPoint secondDragCenter =
      centerAfterScreenDrag(firstDragCenter, secondDrag, 4, rotation);
  const WorldPoint combinedDragCenter = centerAfterScreenDrag(
      initialCenter, {firstDrag.x + secondDrag.x,
                      firstDrag.y + secondDrag.y},
      4, rotation);
  assertNear(secondDragCenter.x, combinedDragCenter.x);
  assertNear(secondDragCenter.y, combinedDragCenter.y);

  // Exercise the production rolling-drag rebase used by commit/re-touch.
  // Starting a second session with zero movement must preserve the exact
  // first endpoint and its canvas/raster relationship, even before recycle.
  const WorldPoint dragRasterOrigin = {900.25, 1700.5};
  const auto firstRebase = rollingDragRebase(
      initialCenter, firstDrag, 4, rotation, dragRasterOrigin);
  const auto immediateRestart = rollingDragRebase(
      {static_cast<double>(firstRebase.center.x),
       static_cast<double>(firstRebase.center.y)},
      {0.0, 0.0}, 4, rotation, dragRasterOrigin);
  assert(immediateRestart.center.x == firstRebase.center.x);
  assert(immediateRestart.center.y == firstRebase.center.y);
  assert(immediateRestart.canvasOffset.x == firstRebase.canvasOffset.x);
  assert(immediateRestart.canvasOffset.y == firstRebase.canvasOffset.y);

  const auto immediateSecond = rollingDragRebase(
      {static_cast<double>(firstRebase.center.x),
       static_cast<double>(firstRebase.center.y)},
      secondDrag, 4, rotation, dragRasterOrigin);
  assert(immediateSecond.center.x != firstRebase.center.x ||
         immediateSecond.center.y != firstRebase.center.y);

  // Edge-clamped movement rebases at the visible limit, so reversing on the
  // next session moves immediately instead of paying back hidden overshoot.
  const int32_t clampedOut =
      map_raster_window::clampDragOffset(200, 400, 466, 192, 5);
  const auto clampedFirst = rollingDragRebase(
      initialCenter, {static_cast<double>(clampedOut), 0.0}, 5, 0.0,
      dragRasterOrigin);
  const auto clampedReverse = rollingDragRebase(
      {static_cast<double>(clampedFirst.center.x),
       static_cast<double>(clampedFirst.center.y)},
      {-20.0, 0.0}, 5, 0.0, dragRasterOrigin);
  assert(clampedReverse.center.x != clampedFirst.center.x);

  // A recycle may advance the raster origin between sessions; the endpoint
  // remains authoritative and only its canvas placement changes by one cell.
  const auto afterRecycle = rollingDragRebase(
      {static_cast<double>(clampedFirst.center.x),
       static_cast<double>(clampedFirst.center.y)},
      {0.0, 0.0}, 5, 0.0, dragRasterOrigin, {192, 0});
  assert(afterRecycle.center.x == clampedFirst.center.x);
  assert(afterRecycle.canvasOffset.x - clampedFirst.canvasOffset.x == 192);

  // A zoom change establishes a new scale but still starts at the previous
  // visible endpoint rather than the first gesture's original center.
  const auto afterZoom = rollingDragRebase(
      {static_cast<double>(firstRebase.center.x),
       static_cast<double>(firstRebase.center.y)},
      {0.0, 0.0}, 3, rotation, dragRasterOrigin);
  assert(afterZoom.center.x == firstRebase.center.x);
  assert(afterZoom.center.y == firstRebase.center.y);

  Controller outward;
  assert(outward.update(frame(1, 2), 3).action == Action::Begin);
  auto decision = outward.update(frame(2, 2, 70, 230), 3);
  assert(decision.action == Action::Update);
  assert(decision.previewRatio > 1.0);
  decision = outward.update(frame(3, 0), 3);
  assert(decision.action == Action::Commit);
  assert(decision.targetZoom == 2);
  assert(!outward.ownsInput());
  outward.update(frame(4, 0), 3);
  assert(!outward.ownsInput());

  Controller inward;
  assert(inward.update(frame(10, 2, 50, 250), 2).action == Action::Begin);
  decision = inward.update(frame(11, 2, 100, 200), 2);
  assert(decision.action == Action::Update);
  decision = inward.update(frame(12, 1), 2);
  assert(decision.action == Action::None);
  decision = inward.update(frame(13, 1), 2);
  assert(decision.action == Action::Commit);
  assert(decision.targetZoom == 3);
  assert(inward.ownsInput());
  inward.update(frame(14, 0), 2);
  assert(!inward.ownsInput());

  Controller jitter;
  assert(jitter.update(frame(20, 2), 3).action == Action::Begin);
  assert(jitter.update(frame(21, 2, 96, 204), 3).action == Action::None);
  assert(jitter.update(frame(21, 2, 70, 230), 3).action == Action::None);
  decision = jitter.update(frame(22, 0), 3);
  assert(decision.action == Action::Cancel);

  Controller tooClose;
  assert(tooClose.update(frame(23, 2, 100, 125), 3).action == Action::None);
  assert(!tooClose.ownsInput());

  Controller liftedBeforeActivation;
  liftedBeforeActivation.update(frame(24, 2), 3);
  assert(liftedBeforeActivation.update(frame(25, 1), 3).action ==
         Action::None);
  assert(liftedBeforeActivation.update(frame(26, 1), 3).action ==
         Action::Cancel);
  assert(liftedBeforeActivation.ownsInput());
  liftedBeforeActivation.update(frame(27, 0), 3);
  assert(!liftedBeforeActivation.ownsInput());

  Controller reordered;
  assert(reordered.update(frame(30, 2), 3).action == Action::Begin);
  Frame swapped = frame(31, 2, 220, 80, 2, 1);
  decision = reordered.update(swapped, 3);
  assert(decision.action == Action::Update);
  assert(decision.previewRatio > 1.0);
  Frame jump = frame(32, 2, -250, 450, 1, 2);
  assert(reordered.update(jump, 3).action == Action::None);

  Controller multipleLevels;
  multipleLevels.update(frame(33, 2, 100, 300), 5);
  decision = multipleLevels.update(frame(34, 2, 0, 460), 5);
  assert(decision.action == Action::Update);
  decision = multipleLevels.update(frame(35, 0), 5);
  assert(decision.action == Action::Commit);
  assert(decision.targetZoom == 3);

  Controller boundedIn;
  boundedIn.update(frame(40, 2), 1);
  decision = boundedIn.update(frame(41, 2, 0, 300), 1);
  assert(decision.action == Action::Update);
  assertNear(decision.previewRatio, 1.0);
  decision = boundedIn.update(frame(42, 0), 1);
  assert(decision.action == Action::Cancel);

  Controller boundedOut;
  boundedOut.update(frame(50, 2, 50, 250), 5);
  decision = boundedOut.update(frame(51, 2, 100, 200), 5);
  assert(decision.action == Action::Update);
  assertNear(decision.previewRatio, 1.0);
  decision = boundedOut.update(frame(52, 0), 5);
  assert(decision.action == Action::Cancel);

  Controller context;
  context.update(frame(60, 2), 3);
  assert(context.cancelForContext(2).action == Action::Cancel);
  assert(context.ownsInput());
  context.cancelForContext(0);
  assert(!context.ownsInput());

  map_tap_arbiter::Controller tap;
  tap.arm(1000);
  assert(tap.pending());
  assert(!tap.consumeIfReady(1159, true, 0, false));
  assert(tap.consumeIfReady(1160, true, 0, false));
  assert(!tap.pending());

  tap.arm(2000);
  assert(!tap.consumeIfReady(2010, true, 2, false));
  assert(!tap.pending());

  tap.arm(3000);
  assert(!tap.consumeIfReady(3010, true, 0, true));
  assert(!tap.pending());

  tap.arm(UINT32_MAX - 50);
  assert(tap.consumeIfReady(109, true, 0, false));

  tap.arm(4000);
  assert(!tap.consumeIfReady(4200, false, 0, false));
  assert(!tap.pending());

  map_drag_preview::Controller drag;
  assert(drag.begin());
  auto dragOffset = drag.preview(20, 5);
  assert(dragOffset.x == 20 && dragOffset.y == 5);
  dragOffset = drag.commit(20, 5, 5000);
  assert(dragOffset.x == 20 && dragOffset.y == 5);
  assert(drag.settlementPending());
  assert(drag.blocksRender(5179));
  assert(!drag.blocksRender(5180));
  // Rolling-raster drags replenish on the first post-release update instead
  // of reserving the generic settlement delay for another gesture.
  assert(!drag.blocksRender(5000, 0));

  // A second drag before settlement continues from the first committed visual
  // offset instead of snapping back to the original rendered frame.
  assert(drag.begin());
  dragOffset = drag.preview(7, -3);
  assert(dragOffset.x == 27 && dragOffset.y == 2);
  dragOffset = drag.commit(7, -3, 5100);
  assert(dragOffset.x == 27 && dragOffset.y == 2);
  assert(drag.blocksRender(5279));
  assert(!drag.blocksRender(5280));
  drag.replaceCommittedOffset({12, -8});
  assert(drag.committedOffset().x == 12);
  assert(drag.committedOffset().y == -8);

  // The rolling Map presentation rebases its canvas at every committed world
  // center. Settlement remains pending, but the next gesture is measured from
  // that visible endpoint rather than from the first gesture's canvas origin.
  drag.replaceCommittedOffset({});
  assert(drag.settlementPending());
  assert(drag.begin());
  dragOffset = drag.preview(-9, 6);
  assert(dragOffset.x == -9 && dragOffset.y == 6);
  dragOffset = drag.commit(-9, 6, 5200);
  assert(dragOffset.x == -9 && dragOffset.y == 6);
  drag.reset();
  assert(!drag.active());
  assert(!drag.settlementPending());

  const auto rollingNonFullscreen = map_raster_window::gridExtent();
  assert(rollingNonFullscreen.width == 960);
  assert(rollingNonFullscreen.height == 960);
  const auto rollingFullscreen = map_raster_window::gridExtent();
  assert(rollingFullscreen.width == 960);
  assert(rollingFullscreen.height == 960);
  for (uint8_t zoom = 1; zoom < map_transform::kMaximumRuntimeZoom; ++zoom) {
    const auto compact = map_raster_window::layoutForZoom(
        zoom, map_transform::kMaximumRuntimeZoom);
    assert(compact.radius == 3);
    assert(compact.span == 7);
    assert(compact.cellExtent == 128);
    const auto compactGrid = map_raster_window::gridExtent(compact);
    assert(compactGrid.width == 896);
    assert(compactGrid.height == 896);
  }
  const auto wide = map_raster_window::layoutForZoom(
      map_transform::kMaximumRuntimeZoom,
      map_transform::kMaximumRuntimeZoom);
  assert(wide.radius == 2);
  assert(wide.span == 5);
  assert(wide.cellExtent == 192);
  assert(map_raster_window::centerLimit(466) == 247);
  assert(map_raster_window::centerLimit(366) == 297);
  assert(map_raster_window::centerLimit(410) == 275);
  assert(map_raster_window::centerLimit(502) == 229);
  assert(map_raster_window::clampDragOffset(0, 300, 466) == 247);
  assert(map_raster_window::clampDragOffset(200, 400, 466) == 47);
  assert(map_raster_window::clampDragOffset(-200, -400, 466) == -47);
  assert(map_raster_window::clampDragOffset(200, -400, 466) == -400);
  assert(map_raster_window::recycleDirection(95.9) == 0);
  assert(map_raster_window::recycleDirection(96.1) == 1);
  assert(map_raster_window::recycleDirection(-96.1) == -1);
  assert(map_raster_window::replacementCellOffset(1) == 2);
  assert(map_raster_window::replacementCellOffset(-1) == -2);
  assert(map_raster_window::replacementCellOffset(0) == 0);
  constexpr double pi = 3.14159265358979323846;
  assert(map_raster_window::rotationIsCompatible(0.0, 5.0 * pi / 180.0));
  assert(!map_raster_window::rotationIsCompatible(0.0, 5.1 * pi / 180.0));
  assert(map_raster_window::rotationIsCompatible(359.0 * pi / 180.0,
                                                 1.0 * pi / 180.0));
  // After moving the origin by one cell, a positive replacement sits at +2
  // around the new origin: +3 cells around the old origin. This guards the
  // repeated-edge regression that motivated the rolling raster.
  assert(1 + map_raster_window::replacementCellOffset(1) == 3);
  assert(-1 + map_raster_window::replacementCellOffset(-1) == -3);
  assert(map_raster_window::centerIsCovered(247, -297, 466, 366));
  assert(!map_raster_window::centerIsCovered(248, 0, 466, 366));
  assert(map_raster_window::centerLimit(466, 128, 7) == 215);
  assert(map_raster_window::centerLimit(366, 128, 7) == 265);
  assert(map_raster_window::centerLimit(410, 128, 7) == 243);
  assert(map_raster_window::centerLimit(502, 128, 7) == 197);
  assert(map_raster_window::clampDragOffset(0, 300, 466, 128, 7) ==
         215);
  assert(map_raster_window::clampDragOffset(100, 100, 466, 128, 7) ==
         100);
  assert(map_raster_window::recycleDirection(63.9, 128) == 0);
  assert(map_raster_window::recycleDirection(64.1, 128) == 1);
  assert(map_raster_window::replacementCellOffset(1, 3) == 3);
  assert(map_raster_window::replacementCellOffset(-1, 3) == -3);
  // After the compact origin advances, its replacement is one cell beyond
  // the old 7-cell edge rather than a repeated copy of that edge.
  assert(1 + map_raster_window::replacementCellOffset(1, 3) == 4);
  assert(-1 + map_raster_window::replacementCellOffset(-1, 3) == -4);
  assert(map_raster_window::centerIsCovered(215, -265, 466, 366, 128,
                                            128, 7));
  assert(!map_raster_window::centerIsCovered(216, 0, 466, 366, 128, 128,
                                             7));
  // At the first recycle point, both the old and shifted compact windows
  // still cover the viewport. There are 151 px left before the old hard edge.
  constexpr int32_t compactRecycleOffset = 64;
  constexpr int32_t compactCenterLimit =
      map_raster_window::centerLimit(466, 128, 7);
  assert(compactCenterLimit - compactRecycleOffset == 151);
  assert(map_raster_window::centerIsCovered(compactRecycleOffset, 0, 466,
                                            466, 128, 128, 7));
  assert(map_raster_window::centerIsCovered(compactRecycleOffset - 128, 0,
                                            466, 466, 128, 128, 7));

  // Recycling must move completed cells without repeating the discarded edge.
  constexpr uint16_t testCellExtent = 2;
  constexpr uint16_t testGridExtent =
      testCellExtent * map_raster_window::kGridSpan;
  std::vector<uint16_t> raster(testGridExtent * testGridExtent);
  auto fillCell = [&](uint8_t column, uint8_t row, uint16_t value) {
    for (uint16_t y = 0; y < testCellExtent; ++y) {
      for (uint16_t x = 0; x < testCellExtent; ++x) {
        raster[(row * testCellExtent + y) * testGridExtent +
               (column * testCellExtent + x)] = value;
      }
    }
  };
  auto cellValue = [&](uint8_t column, uint8_t row) {
    return raster[(row * testCellExtent) * testGridExtent +
                  (column * testCellExtent)];
  };
  for (uint8_t row = 0; row < map_raster_window::kGridSpan; ++row) {
    for (uint8_t column = 0; column < map_raster_window::kGridSpan; ++column)
      fillCell(column, row, (row * 10) + column);
  }
  std::vector<uint16_t> scratch(
      map_raster_window::kGridSpan * testCellExtent * testCellExtent);
  for (uint8_t cell = 0; cell < map_raster_window::kGridSpan; ++cell) {
    std::fill(scratch.begin() + (cell * testCellExtent * testCellExtent),
              scratch.begin() + ((cell + 1) * testCellExtent * testCellExtent),
              100 + cell);
  }
  map_raster_window::shiftPixelsHorizontal(
      raster.data(), scratch.data(), testCellExtent, testCellExtent, 1);
  for (uint8_t row = 0; row < map_raster_window::kGridSpan; ++row) {
    assert(cellValue(0, row) == (row * 10) + 1);
    assert(cellValue(3, row) == (row * 10) + 4);
    assert(cellValue(4, row) == 100 + row);
  }

  for (uint8_t cell = 0; cell < map_raster_window::kGridSpan; ++cell) {
    std::fill(scratch.begin() + (cell * testCellExtent * testCellExtent),
              scratch.begin() + ((cell + 1) * testCellExtent * testCellExtent),
              200 + cell);
  }
  map_raster_window::shiftPixelsVertical(
      raster.data(), scratch.data(), testCellExtent, testCellExtent, 1);
  assert(cellValue(0, 0) == 11);
  assert(cellValue(4, 3) == 104);
  for (uint8_t column = 0; column < map_raster_window::kGridSpan; ++column)
    assert(cellValue(column, 4) == 200 + column);

  for (uint8_t cell = 0; cell < map_raster_window::kGridSpan; ++cell) {
    std::fill(scratch.begin() + (cell * testCellExtent * testCellExtent),
              scratch.begin() + ((cell + 1) * testCellExtent * testCellExtent),
              300 + cell);
  }
  map_raster_window::shiftPixelsHorizontal(
      raster.data(), scratch.data(), testCellExtent, testCellExtent, -1);
  assert(cellValue(0, 0) == 300);
  assert(cellValue(1, 0) == 11);
  assert(cellValue(4, 3) == 44);

  for (uint8_t cell = 0; cell < map_raster_window::kGridSpan; ++cell) {
    std::fill(scratch.begin() + (cell * testCellExtent * testCellExtent),
              scratch.begin() + ((cell + 1) * testCellExtent * testCellExtent),
              400 + cell);
  }
  map_raster_window::shiftPixelsVertical(
      raster.data(), scratch.data(), testCellExtent, testCellExtent, -1);
  for (uint8_t column = 0; column < map_raster_window::kGridSpan; ++column)
    assert(cellValue(column, 0) == 400 + column);
  assert(cellValue(0, 1) == 300);
  assert(cellValue(1, 1) == 11);

  // The compact 7x7 layout must also support repeated recycling in the same
  // direction without wrapping the discarded edge back into view.
  constexpr uint8_t compactSpan = map_raster_window::kCompactGridSpan;
  constexpr uint16_t compactTestGridExtent =
      testCellExtent * compactSpan;
  std::vector<uint16_t> compactRaster(compactTestGridExtent *
                                      compactTestGridExtent);
  auto fillCompactCell = [&](uint8_t column, uint8_t row, uint16_t value) {
    for (uint16_t y = 0; y < testCellExtent; ++y) {
      for (uint16_t x = 0; x < testCellExtent; ++x) {
        compactRaster[(row * testCellExtent + y) * compactTestGridExtent +
                      (column * testCellExtent + x)] = value;
      }
    }
  };
  auto compactCellValue = [&](uint8_t column, uint8_t row) {
    return compactRaster[(row * testCellExtent) * compactTestGridExtent +
                         (column * testCellExtent)];
  };
  for (uint8_t row = 0; row < compactSpan; ++row) {
    for (uint8_t column = 0; column < compactSpan; ++column)
      fillCompactCell(column, row, (row * 10) + column);
  }
  std::vector<uint16_t> compactScratch(compactSpan * testCellExtent *
                                       testCellExtent);
  for (uint8_t cell = 0; cell < compactSpan; ++cell) {
    std::fill(compactScratch.begin() +
                  (cell * testCellExtent * testCellExtent),
              compactScratch.begin() +
                  ((cell + 1) * testCellExtent * testCellExtent),
              100 + cell);
  }
  map_raster_window::shiftPixelsHorizontal(
      compactRaster.data(), compactScratch.data(), testCellExtent,
      testCellExtent, 1, compactSpan);
  for (uint8_t row = 0; row < compactSpan; ++row) {
    for (uint8_t column = 0; column < compactSpan - 1; ++column)
      assert(compactCellValue(column, row) == (row * 10) + column + 1);
    assert(compactCellValue(compactSpan - 1, row) == 100 + row);
  }
  for (uint8_t cell = 0; cell < compactSpan; ++cell) {
    std::fill(compactScratch.begin() +
                  (cell * testCellExtent * testCellExtent),
              compactScratch.begin() +
                  ((cell + 1) * testCellExtent * testCellExtent),
              200 + cell);
  }
  map_raster_window::shiftPixelsHorizontal(
      compactRaster.data(), compactScratch.data(), testCellExtent,
      testCellExtent, 1, compactSpan);
  for (uint8_t row = 0; row < compactSpan; ++row) {
    for (uint8_t column = 0; column < compactSpan - 2; ++column)
      assert(compactCellValue(column, row) == (row * 10) + column + 2);
    assert(compactCellValue(compactSpan - 2, row) == 100 + row);
    assert(compactCellValue(compactSpan - 1, row) == 200 + row);
  }
  for (uint8_t cell = 0; cell < compactSpan; ++cell) {
    std::fill(compactScratch.begin() +
                  (cell * testCellExtent * testCellExtent),
              compactScratch.begin() +
                  ((cell + 1) * testCellExtent * testCellExtent),
              300 + cell);
  }
  map_raster_window::shiftPixelsVertical(
      compactRaster.data(), compactScratch.data(), testCellExtent,
      testCellExtent, 1, compactSpan);
  for (uint8_t column = 0; column < compactSpan; ++column)
    assert(compactCellValue(column, compactSpan - 1) == 300 + column);

  // A centered oversized canvas must put the same map center at the same
  // parent coordinate as the normal viewport. Drag presentation therefore
  // moves both from their aligned (0,0) offsets, rather than reusing these
  // resolved negative/top coordinates as new centered offsets.
  assert(gui_layout::centeredViewportOrigin(466, 466) +
             gui_layout::mapAnchorX(466) ==
         gui_layout::centeredViewportOrigin(466, 960) +
             gui_layout::mapAnchorX(960));
  assert(gui_layout::centeredViewportOrigin(466, 366) +
             gui_layout::mapAnchorY(366) ==
         gui_layout::centeredViewportOrigin(466, 960) +
             gui_layout::mapAnchorY(960));
  assert(gui_layout::centeredViewportOrigin(466, 466) +
             gui_layout::mapAnchorX(466) ==
         gui_layout::centeredViewportOrigin(466, 768) +
             gui_layout::mapAnchorX(768));
  assert(gui_layout::centeredViewportOrigin(466, 366) +
             gui_layout::mapAnchorY(366) ==
         gui_layout::centeredViewportOrigin(466, 768) +
             gui_layout::mapAnchorY(768));

  // LVGL preserves CENTER alignment after lv_obj_center(). Position setters
  // therefore take an offset from the centered origin. A fresh overscanned
  // frame whose projected rider is at its render anchor needs offset zero,
  // not the raw -96 px top-left origin that would apply overscan twice.
  assert(gui_layout::centerAlignedOffsetForPoint(466, 658, 329, 233) == 0);
  assert(gui_layout::centerAlignedOffsetForPoint(466, 558, 300, 254) == 0);
  // As the live rider advances within the finished frame, only the projected
  // displacement becomes the aligned offset.
  assert(gui_layout::centerAlignedOffsetForPoint(466, 658, 405, 233) == -76);
  assert(gui_layout::centerAlignedOffsetForPoint(466, 558, 345, 254) == -45);

  const auto northUpCell = map_transform::canvasWorldBounds(
      {1000.0, 2000.0}, 192.0, 192.0, 5, 0.0);
  assertNear(northUpCell.min.x, 616.0);
  assertNear(northUpCell.max.x, 1384.0);
  assertNear(northUpCell.min.y, 1616.0);
  assertNear(northUpCell.max.y, 2384.0);

  // Each independently rendered cell remains narrower than one map block in
  // every orientation. The rolling 5x5 raster therefore retains the existing
  // four-vector-block working-set ceiling even though its prepared pixels span
  // three screens in each direction.
  assert(std::hypot(192.0, 192.0) * screenToWorldScale(5) < 4096.0);
  assert(std::hypot(256.0, 256.0) * screenToWorldScale(4) < 4096.0);

  std::cout << "Map pinch-zoom tests passed\n";
  return 0;
}
