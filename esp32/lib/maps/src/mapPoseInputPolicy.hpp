#pragma once

#include <cstdint>

namespace map_pose_input_policy {

enum class Action : uint8_t {
  None = 0,
  ObservePhysicalFix,
  UpdateHeadingOnly,
};

/** Classify the latest resolved pose input without conflating route heading
 * changes with physical GPS observations.
 *
 * The position signature includes accepted BLE packet identity. The complete
 * signature additionally includes the resolved display heading. Keeping both
 * histories here makes the production dispatch rule directly host-testable:
 * a fresh packet must re-observe position even when its coordinates repeat,
 * while a route-only heading change must not restart positional prediction.
 */
class Tracker {
public:
  Action classify(uint64_t positionSignature, uint64_t completeSignature,
                  bool presenterHasFix) {
    if (presenterHasFix && hasCompleteSignature_ &&
        completeSignature == lastCompleteSignature_) {
      return Action::None;
    }

    const bool physicalFixChanged =
        !presenterHasFix || !hasPositionSignature_ ||
        positionSignature != lastPositionSignature_;
    lastPositionSignature_ = positionSignature;
    lastCompleteSignature_ = completeSignature;
    hasPositionSignature_ = true;
    hasCompleteSignature_ = true;
    return physicalFixChanged ? Action::ObservePhysicalFix
                              : Action::UpdateHeadingOnly;
  }

  /** Force the current heading through the next classification without
   * treating the unchanged physical fix as newly arrived. */
  void invalidateHeading() { hasCompleteSignature_ = false; }

private:
  bool hasPositionSignature_ = false;
  bool hasCompleteSignature_ = false;
  uint64_t lastPositionSignature_ = 0;
  uint64_t lastCompleteSignature_ = 0;
};

} // namespace map_pose_input_policy
