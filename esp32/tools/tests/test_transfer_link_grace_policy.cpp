// Host test for the transfer link-loss grace policy.
//
//   g++ -std=c++17 -Wall -Wextra -Werror tools/tests/test_transfer_link_grace_policy.cpp
#include "../../lib/device_transfer/transfer_link_grace_policy.hpp"

#include <cassert>
#include <climits>

int main() {
  using namespace transfer_link_grace_policy;

  // Only map and diagnostics transfers survive a link loss.
  assert(modeKeepsSessionAcrossLinkLoss("map"));
  assert(modeKeepsSessionAcrossLinkLoss("diagnostics"));
  assert(!modeKeepsSessionAcrossLinkLoss("firmware"));
  assert(!modeKeepsSessionAcrossLinkLoss("debug"));
  assert(!modeKeepsSessionAcrossLinkLoss(""));

  // The window opens only for an enabled, bound session outside a commit
  // boundary and outside firmware maintenance.
  assert(startsGrace(true, 7, false, false, "diagnostics"));
  assert(startsGrace(true, 7, false, false, "map"));
  assert(!startsGrace(false, 7, false, false, "map"));
  assert(!startsGrace(true, 0, false, false, "map"));
  assert(!startsGrace(true, 7, true, false, "map"));
  assert(!startsGrace(true, 7, false, true, "map"));
  assert(!startsGrace(true, 7, false, false, "firmware"));

  // Expiry is wrap-safe.
  assert(!graceExpired(1000, 1000 + graceMs));
  assert(!graceExpired(1000 + graceMs - 1, 1000 + graceMs));
  assert(graceExpired(1000 + graceMs, 1000 + graceMs));
  assert(graceExpired(1000 + graceMs + 1, 1000 + graceMs));
  const uint32_t nearWrap = UINT32_MAX - 2000;
  const uint32_t wrappedDeadline = nearWrap + graceMs; // wraps past zero
  assert(!graceExpired(nearWrap, wrappedDeadline));
  assert(!graceExpired(UINT32_MAX, wrappedDeadline));
  assert(graceExpired(wrappedDeadline, wrappedDeadline));
  assert(graceExpired(wrappedDeadline + 5, wrappedDeadline));

  // Rebind decisions.
  assert(rebind(true, false, 0, 0) == Rebind::Reject);
  assert(rebind(true, true, 5, 0) == Rebind::Reject);
  assert(rebind(true, false, 5, 5) == Rebind::Keep);
  assert(rebind(true, true, 5, 5) == Rebind::Keep);
  assert(rebind(true, true, 5, 9) == Rebind::Adopt);
  assert(rebind(true, false, 5, 9) == Rebind::Reject);
  assert(rebind(false, false, 5, 9) == Rebind::Rotate);
  assert(rebind(true, false, 0, 9) == Rebind::Rotate);
  assert(rebind(false, false, 0, 9) == Rebind::Rotate);
  assert(graceMs == 15000);
  return 0;
}
