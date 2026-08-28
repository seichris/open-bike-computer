#include "../../lib/maps/src/mapProbeDiagnostics.hpp"

#include <cassert>
#include <cstring>

int main() {
  using map_probe_diagnostics::Code;
  using map_probe_diagnostics::Result;
  using map_probe_diagnostics::name;

  constexpr Code codes[] = {
      Code::NotRun,
      Code::Ok,
      Code::WorkerStopFailed,
      Code::RootUnavailable,
      Code::BlockNotFound,
      Code::BlockInvalid,
      Code::FontOpenFailed,
      Code::FontProfileMismatch,
      Code::FontReferencesInvalid,
      Code::RootSwitchFailed,
      Code::WorkerRestartFailed,
  };
  constexpr const char *names[] = {
      "not_run",
      "ok",
      "worker_stop_failed",
      "root_unavailable",
      "block_not_found",
      "block_invalid",
      "font_open_failed",
      "font_profile_mismatch",
      "font_references_invalid",
      "root_switch_failed",
      "worker_restart_failed",
  };
  static_assert(sizeof(codes) / sizeof(codes[0]) ==
                sizeof(names) / sizeof(names[0]));
  for (std::size_t index = 0; index < sizeof(codes) / sizeof(codes[0]); ++index) {
    assert(std::strcmp(name(codes[index]), names[index]) == 0);
    assert(Result{codes[index]}.loaded() == (codes[index] == Code::Ok));
  }

  const Result untouched{};
  assert(!untouched.loaded());
  const Result loaded{Code::Ok, 17, 5, 1};
  assert(loaded.loaded());
  assert(loaded.elapsedMs == 17);
  assert(loaded.visitedEntries == 5);
  assert(loaded.formatVersion == 1);
  assert(std::strcmp(name(static_cast<Code>(255)), "unknown") == 0);
  return 0;
}
