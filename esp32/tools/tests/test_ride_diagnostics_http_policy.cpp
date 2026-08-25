#include "../../lib/ride_diagnostics/ride_diagnostics_http_policy.hpp"
#include "../../lib/ride_diagnostics/ride_diagnostics_index_policy.hpp"

#include <cassert>
#include <cstdint>
#include <string>

using ride_diagnostics::http_policy::RouteKind;
using ride_diagnostics::index_policy::CandidateDisposition;
using ride_diagnostics::index_policy::classifyCandidate;

int main() {
  constexpr char prefix[] = "/device-diagnostics/v1/";
  const auto status = ride_diagnostics::http_policy::parseRoute(
      "GET", std::string(prefix) + "status", prefix);
  assert(status.kind == RouteKind::Status);
  assert(ride_diagnostics::http_policy::parseRoute(
             "POST", std::string(prefix) + "status", prefix)
             .kind == RouteKind::Unknown);

  assert(ride_diagnostics::http_policy::parseRoute(
             "GET", std::string(prefix) + "index", prefix)
             .kind == RouteKind::Index);
  assert(ride_diagnostics::http_policy::parseRoute(
             "GET", std::string(prefix) + "active-tail", prefix)
             .kind == RouteKind::ActiveTail);
  assert(ride_diagnostics::http_policy::parseRoute(
             "POST", std::string(prefix) + "session/exit", prefix)
             .kind == RouteKind::Exit);
  assert(ride_diagnostics::http_policy::parseRoute(
             "GET", std::string(prefix) + "session/exit", prefix)
             .kind == RouteKind::Unknown);

  assert(classifyCandidate(0, 256 * 1024) ==
         CandidateDisposition::IgnoreEmpty);
  // The firmware indexes readable crash-tail bytes as-is. iOS verifies the
  // checksum and ignores only the incomplete final JSON record.
  assert(classifyCandidate(66560, 256 * 1024) ==
         CandidateDisposition::Include);
  assert(classifyCandidate(256 * 1024 + 1, 256 * 1024) ==
         CandidateDisposition::Reject);

  const auto chunk = ride_diagnostics::http_policy::parseRoute(
      "GET", std::string(prefix) + "chunks/12/34", prefix);
  assert(chunk.kind == RouteKind::Chunk);
  assert(chunk.boot == 12);
  assert(chunk.chunk == 34);

  for (const char *path : {
           "/device-diagnostics/v1/chunks/0/1",
           "/device-diagnostics/v1/chunks/1/0",
           "/device-diagnostics/v1/chunks/1",
           "/device-diagnostics/v1/chunks/1/2/3",
           "/device-diagnostics/v1/chunks/-1/2",
           "/device-diagnostics/v1/chunks/4294967296/1",
           "/device-diagnostics/v1/../status",
           "/other/status",
       }) {
    assert(ride_diagnostics::http_policy::parseRoute("GET", path, prefix)
               .kind == RouteKind::Unknown);
  }
  return 0;
}
