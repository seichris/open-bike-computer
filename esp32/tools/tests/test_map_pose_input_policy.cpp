#include "../../lib/maps/src/mapPoseInputPolicy.hpp"

#include <cassert>
#include <cstdint>

int main() {
  using map_pose_input_policy::Action;
  using map_pose_input_policy::Tracker;

  Tracker tracker;

  // The first input always establishes a physical presentation anchor.
  assert(tracker.classify(100U, 1000U, false) ==
         Action::ObservePhysicalFix);
  assert(tracker.classify(100U, 1000U, true) == Action::None);

  // A route-only heading refinement changes the complete signature but not
  // accepted GPS packet identity, so it can rotate presentation only.
  assert(tracker.classify(100U, 1001U, true) == Action::UpdateHeadingOnly);
  assert(tracker.classify(100U, 1001U, true) == Action::None);

  // An identical coordinate carried by a newly accepted GPS packet changes
  // the position signature and must refresh transport age/convergence.
  assert(tracker.classify(101U, 1002U, true) ==
         Action::ObservePhysicalFix);

  // A heading epoch reset re-resolves display direction but cannot manufacture
  // a physical observation from the retained fix.
  tracker.invalidateHeading();
  assert(tracker.classify(101U, 1002U, true) == Action::UpdateHeadingOnly);

  // If the presenter was independently reset, the retained signature history
  // cannot suppress rebuilding its physical anchor.
  assert(tracker.classify(101U, 1002U, false) ==
         Action::ObservePhysicalFix);

  // Zero is a valid hash value; explicit state, not a sentinel, owns history.
  Tracker zeroTracker;
  assert(zeroTracker.classify(0U, 0U, false) ==
         Action::ObservePhysicalFix);
  assert(zeroTracker.classify(0U, 0U, true) == Action::None);

  return 0;
}
