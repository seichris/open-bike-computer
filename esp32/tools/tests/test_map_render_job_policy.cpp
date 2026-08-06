#include "../../lib/maps/src/mapRenderJobPolicy.hpp"

#include <cassert>

int main() {
  static_assert(map_render_job_policy::availableMotionPixels() == 80);
  static_assert(map_render_job_policy::kGuidanceMaximumQueuedBuildingRecords >=
                map_render_job_policy::kGuidanceMaximumRenderedBuildingRecords);

  assert(map_render_job_policy::refreshLeadPixels(0.0) == 0);
  assert(map_render_job_policy::refreshLeadPixels(0.1) == 30);
  assert(!map_render_job_policy::shouldRefresh(40.0, 0.0));
  assert(map_render_job_policy::shouldRefresh(50.0, 0.1));
  assert(map_render_job_policy::shouldRefresh(80.0, 0.0));
  return 0;
}
