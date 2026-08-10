#include "../../lib/ride_automation/ride_automation_trace.hpp"

#include <cstdio>

int main() {
  using namespace ride_automation;
  TraceRecord record;
  record.timestampMs = 1'000;
  record.observation.wheelSpeedMetersPerSecond =
      TimedMetric{true, 2.0F, 1'000, 0};
  record.evidenceMask = EvidenceWheelMoving;
  char output[2'048];
  if (formatTraceJsonLine(record, output, sizeof(output)) < 0)
    return 1;
  std::puts(output);
  return 0;
}
