#include "../../lib/ride_diagnostics/ride_diagnostics_control.hpp"

#include <cassert>
#include <iostream>

int main() {
  using namespace ride_diagnostics::control;

  CaptureBinding binding;
  assert(parseCaptureBinding(
      "capture|1|standard|123e4567-e89b-12d3-a456-426614174000",
      binding));
  assert(binding.mode == CaptureMode::Standard);
  assert(parseCaptureBinding(
      "capture|1|detailed|123e4567-e89b-12d3-a456-426614174001",
      binding));
  assert(binding.mode == CaptureMode::Detailed);
  assert(!parseCaptureBinding("capture|2|standard|id", binding));
  assert(!parseCaptureBinding("capture|1|unknown|id", binding));

  IssueMarker marker;
  assert(parseIssueMarker("mark|1|7|connection_drop", marker));
  assert(marker.sequence == 7);
  assert(marker.code == "connection_drop");
  assert(!parseIssueMarker("mark|1|0|connection_drop", marker));
  assert(!parseIssueMarker("mark|1|7|connection|drop", marker));
  assert(!parseIssueMarker("mark|2|7|connection_drop", marker));

  std::cout << "ride diagnostics control tests passed\n";
  return 0;
}
