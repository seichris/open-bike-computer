#pragma once

#include <cstdint>

namespace map_probe_diagnostics {

enum class Code : uint8_t {
  NotRun = 0,
  Ok,
  WorkerStopFailed,
  RootUnavailable,
  BlockNotFound,
  BlockInvalid,
  FontOpenFailed,
  FontProfileMismatch,
  FontReferencesInvalid,
  RootSwitchFailed,
  WorkerRestartFailed,
};

constexpr const char *name(Code code) {
  switch (code) {
  case Code::NotRun:
    return "not_run";
  case Code::Ok:
    return "ok";
  case Code::WorkerStopFailed:
    return "worker_stop_failed";
  case Code::RootUnavailable:
    return "root_unavailable";
  case Code::BlockNotFound:
    return "block_not_found";
  case Code::BlockInvalid:
    return "block_invalid";
  case Code::FontOpenFailed:
    return "font_open_failed";
  case Code::FontProfileMismatch:
    return "font_profile_mismatch";
  case Code::FontReferencesInvalid:
    return "font_references_invalid";
  case Code::RootSwitchFailed:
    return "root_switch_failed";
  case Code::WorkerRestartFailed:
    return "worker_restart_failed";
  }
  return "unknown";
}

struct Result {
  Code code = Code::NotRun;
  uint32_t elapsedMs = 0;
  uint32_t visitedEntries = 0;
  uint8_t formatVersion = 0;

  constexpr bool loaded() const { return code == Code::Ok; }
};

} // namespace map_probe_diagnostics
