#include "../../lib/ride_diagnostics/ride_diagnostics_http_policy.hpp"
#include "../../lib/ride_diagnostics/ride_diagnostics_index_policy.hpp"

#include <cassert>
#include <cstdint>
#include <string>

using ride_diagnostics::http_policy::RouteKind;
using ride_diagnostics::http_policy::StorageCallPlacement;
using ride_diagnostics::http_policy::runStorageCall;
using ride_diagnostics::http_policy::storageCallPlacement;
using ride_diagnostics::index_policy::CandidateDisposition;
using ride_diagnostics::index_policy::classifyCandidate;

// Only an FFat read from a PSRAM stack must move. Removable SD stays direct.
static_assert(storageCallPlacement(true, false) ==
              StorageCallPlacement::InternalStack);
static_assert(storageCallPlacement(true, true) == StorageCallPlacement::Direct);
static_assert(storageCallPlacement(false, false) ==
              StorageCallPlacement::Direct);
static_assert(storageCallPlacement(false, true) == StorageCallPlacement::Direct);

template <typename Step> void runStep(void *context) {
  (*static_cast<Step *>(context))();
}

void checkStorageCallPlacement() {
  bool stackInternal = false;
  unsigned dispatches = 0;
  unsigned steps = 0;
  bool ffat = false;
  auto owner = [&](void (*call)(void *), void *context) {
    ++dispatches;
    const bool caller = stackInternal;
    stackInternal = true;
    call(context);
    stackInternal = caller;
    return true;
  };
  auto refusingOwner = [&](void (*)(void *), void *) {
    ++dispatches;
    return false;
  };
  auto step = [&] {
    // Stand-in for a flash read: never on a PSRAM stack while FFat is mounted.
    assert(!ffat || stackInternal);
    ++steps;
  };
  void (*call)(void *) = runStep<decltype(step)>;

  assert(runStorageCall(ffat, stackInternal, owner, call, &step));
  assert(steps == 1 && dispatches == 0);

  ffat = true;
  assert(runStorageCall(ffat, stackInternal, owner, call, &step));
  assert(steps == 2 && dispatches == 1 && !stackInternal);

  assert(!runStorageCall(ffat, stackInternal, refusingOwner, call, &step));
  assert(steps == 2 && dispatches == 2);

  stackInternal = true;
  assert(runStorageCall(ffat, stackInternal, refusingOwner, call, &step));
  assert(steps == 3 && dispatches == 2);
}

int main() {
  checkStorageCallPlacement();
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
