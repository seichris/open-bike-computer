/**
 * @file mapRenderJobPolicy.hpp
 * @brief Bounds and admission rules for cooperative guidance renders.
 *
 * These values are deliberately independent of wall-clock discovery.  A
 * render job may be advanced in different sized scheduler slices, but it
 * must discover and admit the same buildings for the same immutable frame
 * request.
 */

#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace map_render_job_policy {

// The UI task gives the job a short cooperative slice.  This is a yield
// boundary, not a completeness deadline: discovery resumes on the next UI
// tick until every candidate has been visited.
constexpr uint32_t kGuidanceSliceBudgetUs = 3500U;
constexpr size_t kGuidanceDiscoveryRecordsPerSlice = 96U;
constexpr size_t kGuidanceBuildingsPerSlice = 8U;

// Keep the nearest useful buildings, then render them far-to-near.  The
// queue/point limits are deterministic geometry quotas, not input-order or
// elapsed-time fallbacks.
constexpr size_t kGuidanceMaximumQueuedBuildingRecords = 512U;
constexpr size_t kGuidanceMaximumRenderedBuildingRecords = 64U;
constexpr size_t kGuidanceMaximumRenderedBuildingPoints = 12288U;
constexpr size_t kGuidanceMaximumRenderedBuildingPointsPerRecord = 512U;
constexpr size_t kGuidanceMaximumExtrudedBuildingRecords = 48U;
constexpr size_t kGuidanceMaximumExtrudedBuildingPoints = 8192U;
constexpr size_t kGuidanceMaximumBuildingPixelsPerRecord = 120000U;

// Motion can consume overscan while a frame is being built.  The refresh
// guard is therefore derived from speed and the worst measured/specified job
// latency instead of a fixed magic margin.
constexpr uint16_t kGuidanceOverscanPixels = 96U;
constexpr uint16_t kGuidanceRefreshSafetyPixels = 16U;
constexpr uint32_t kGuidanceWorstCaseRenderMs = 300U;

constexpr uint16_t availableMotionPixels() {
  return kGuidanceOverscanPixels > kGuidanceRefreshSafetyPixels
             ? static_cast<uint16_t>(kGuidanceOverscanPixels -
                                     kGuidanceRefreshSafetyPixels)
             : 0U;
}

constexpr uint16_t refreshLeadPixels(double pixelsPerMs) {
  if (!(pixelsPerMs > 0.0))
    return 0U;
  const double projected = pixelsPerMs * kGuidanceWorstCaseRenderMs;
  const auto lead = static_cast<uint32_t>(projected + 0.5);
  return static_cast<uint16_t>(std::min<uint32_t>(availableMotionPixels(),
                                                  lead));
}

constexpr bool shouldRefresh(double distanceFromAnchorPixels,
                             double pixelsPerMs) {
  const double lead = refreshLeadPixels(pixelsPerMs);
  return distanceFromAnchorPixels >=
         static_cast<double>(availableMotionPixels()) - lead;
}

} // namespace map_render_job_policy
