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
  // boundary and outside firmware maintenance, when the authenticated owner's
  // own link was lost without the firmware asking for the disconnect.
  assert(startsGrace(true, 7, false, false, "diagnostics", true, false));
  assert(startsGrace(true, 7, false, false, "map", true, false));
  assert(!startsGrace(false, 7, false, false, "map", true, false));
  assert(!startsGrace(true, 0, false, false, "map", true, false));
  assert(!startsGrace(true, 7, true, false, "map", true, false));
  assert(!startsGrace(true, 7, false, true, "map", true, false));
  assert(!startsGrace(true, 7, false, false, "firmware", true, false));
  // A stray unauthenticated link, or one the firmware disconnected itself
  // (deadline, ownership revocation), never opens a window.
  assert(!startsGrace(true, 7, false, false, "map", false, false));
  assert(!startsGrace(true, 7, false, false, "map", true, true));

  // An open window is never re-armed by a later disconnect and never torn
  // down by it either: the original deadline decides.
  assert(linkLoss(false, true) == LinkLoss::Started);
  assert(linkLoss(false, false) == LinkLoss::TearDown);
  assert(linkLoss(true, true) == LinkLoss::Continuing);
  assert(linkLoss(true, false) == LinkLoss::Continuing);

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

  // A BLE link appearing while the window is open moves the deadline to a
  // full window from that link, never later than the cap from the loss and
  // never earlier than the deadline already is.
  assert(graceMaxMs == 45000 && graceMaxMs >= 2 * graceMs);
  assert(isAfter(5, 4) && !isAfter(4, 5) && !isAfter(4, 4) &&
         isAfter(1, UINT32_MAX));
  assert(extendedDeadlineMs(11000, 1000, 16000) == 26000);
  assert(extendedDeadlineMs(2000, 1000, 16000) == 17000);
  assert(extendedDeadlineMs(35000, 1000, 45000) == 46000); // capped
  assert(extendedDeadlineMs(46000, 1000, 46000) == 46000); // at the cap
  assert(extendedDeadlineMs(1000, 1000, 40000) == 40000);  // never earlier
  // A link after the deadline (before the loop's expiry check) and one at
  // the deadline do not revive the window, even inside the cap.
  assert(extendedDeadlineMs(17000, 1000, 16000) == 16000);
  assert(extendedDeadlineMs(16000, 1000, 16000) == 16000);
  assert(graceExpired(17000, 16000));
  const uint32_t lossNearWrap = UINT32_MAX - 10000;
  assert(extendedDeadlineMs(lossNearWrap + 5000, lossNearWrap,
                            lossNearWrap + graceMs) ==
         static_cast<uint32_t>(lossNearWrap + 5000 + graceMs));
  assert(extendedDeadlineMs(lossNearWrap + 40000, lossNearWrap,
                            lossNearWrap + 44000) ==
         static_cast<uint32_t>(lossNearWrap + graceMaxMs));
  assert(graceExpired(static_cast<uint32_t>(lossNearWrap + graceMaxMs),
                      static_cast<uint32_t>(lossNearWrap + graceMaxMs)));
  return 0;
}
