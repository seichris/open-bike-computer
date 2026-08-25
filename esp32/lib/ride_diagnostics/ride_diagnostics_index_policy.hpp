#pragma once

#include <cstdint>

namespace ride_diagnostics::index_policy {

enum class CandidateDisposition : uint8_t {
  IgnoreEmpty = 0,
  Include,
  Reject,
};

constexpr CandidateDisposition classifyCandidate(int64_t bytes,
                                                  uint64_t maximumBytes) {
  if (bytes == 0)
    return CandidateDisposition::IgnoreEmpty;
  if (bytes < 0 || static_cast<uint64_t>(bytes) > maximumBytes)
    return CandidateDisposition::Reject;
  return CandidateDisposition::Include;
}

} // namespace ride_diagnostics::index_policy
