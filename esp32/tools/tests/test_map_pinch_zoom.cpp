#include "../../lib/maps/src/mapTransform.hpp"
#include "../../lib/gui/src/guiLayout.hpp"
#include "../../lib/utils/src/mapPinchZoom.hpp"
#include "../../lib/utils/src/mapTapArbiter.hpp"
#include "../../lib/utils/src/mapDragPreview.hpp"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>

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

  // A second drag before settlement continues from the first committed visual
  // offset instead of snapping back to the original rendered frame.
  assert(drag.begin());
  dragOffset = drag.preview(7, -3);
  assert(dragOffset.x == 27 && dragOffset.y == 2);
  dragOffset = drag.commit(7, -3, 5100);
  assert(dragOffset.x == 27 && dragOffset.y == 2);
  assert(drag.blocksRender(5279));
  assert(!drag.blocksRender(5280));
  drag.reset();
  assert(!drag.active());
  assert(!drag.settlementPending());

  assert(map_drag_preview::kOverscanMarginPx == 96);
  assert(map_drag_preview::overscanExtent(466) == 658);
  assert(map_drag_preview::overscanExtent(366) == 558);

  // A centered oversized canvas must put the same map center at the same
  // parent coordinate as the normal viewport. Drag presentation therefore
  // moves both from their aligned (0,0) offsets, rather than reusing these
  // resolved negative/top coordinates as new centered offsets.
  assert(gui_layout::centeredViewportOrigin(466, 466) +
             gui_layout::mapAnchorX(466) ==
         gui_layout::centeredViewportOrigin(466, 658) +
             gui_layout::mapAnchorX(658));
  assert(gui_layout::centeredViewportOrigin(466, 366) +
             gui_layout::mapAnchorY(366) ==
         gui_layout::centeredViewportOrigin(466, 558) +
             gui_layout::mapAnchorY(558));

  const auto northUpOverscan = map_transform::canvasWorldBounds(
      {1000.0, 2000.0}, 658.0, 558.0, 5, 0.0);
  assertNear(northUpOverscan.min.x, -316.0);
  assertNear(northUpOverscan.max.x, 2316.0);
  assertNear(northUpOverscan.min.y, 884.0);
  assertNear(northUpOverscan.max.y, 3116.0);

  const auto quarterTurnOverscan = map_transform::canvasWorldBounds(
      {1000.0, 2000.0}, 658.0, 558.0, 5, std::acos(-1.0) / 2.0);
  assertNear(quarterTurnOverscan.min.x, -116.0);
  assertNear(quarterTurnOverscan.max.x, 2116.0);
  assertNear(quarterTurnOverscan.min.y, 684.0);
  assertNear(quarterTurnOverscan.max.y, 3316.0);

  std::cout << "Map pinch-zoom tests passed\n";
  return 0;
}
