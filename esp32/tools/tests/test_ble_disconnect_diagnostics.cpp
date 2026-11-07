// Host test for the `ble disconnected` diagnostics payload.
//
//   g++ -std=c++17 -Wall -Wextra -Werror tools/tests/test_ble_disconnect_diagnostics.cpp
#include "../../lib/ble_navigation/ble_disconnect_diagnostics.hpp"

#include <cassert>
#include <climits>
#include <cstring>
#include <string>

int main() {
  using namespace ble_disconnect_diagnostics;
  char out[FIELDS_CAPACITY];

  int written = formatFields(out, sizeof(out), 0x208, 53412, true,
                             LocalCause::None);
  assert(written > 0 && static_cast<size_t>(written) < sizeof(out));
  assert(std::string(out) ==
         "{\"disconnectReason\":520,\"durationMs\":53412,"
         "\"state\":\"authenticated\",\"reason\":\"remote\"}");

  written = formatFields(out, sizeof(out), 0x216, 12001, false,
                         LocalCause::UnauthenticatedDeadline);
  assert(written > 0 && static_cast<size_t>(written) < sizeof(out));
  assert(std::string(out) ==
         "{\"disconnectReason\":534,\"durationMs\":12001,"
         "\"state\":\"unauthenticated\",\"reason\":\"unauthenticated_deadline\"}");

  // No GAP event observed: the reason is 0 and the cause still names the
  // firmware's own decision.
  written = formatFields(out, sizeof(out), 0, 7, false,
                         LocalCause::OwnershipInvalidated);
  assert(std::string(out) ==
         "{\"disconnectReason\":0,\"durationMs\":7,"
         "\"state\":\"unauthenticated\",\"reason\":\"ownership_invalidated\"}");

  // The longest possible payload fits the fixed buffer.
  written = formatFields(out, sizeof(out), INT32_MIN, UINT32_MAX, false,
                         LocalCause::UnauthenticatedDeadline);
  assert(written > 0 && static_cast<size_t>(written) < sizeof(out));
  assert(written == 118);

  assert(localCauseFromValue(0) == LocalCause::None);
  assert(localCauseFromValue(1) == LocalCause::UnauthenticatedDeadline);
  assert(localCauseFromValue(2) == LocalCause::OwnershipLost);
  assert(std::strcmp(localCauseName(localCauseFromValue(3)),
                     "ownership_invalidated") == 0);
  assert(std::strcmp(localCauseName(localCauseFromValue(99)), "remote") == 0);

  // A buffer that is too small reports the needed size and stays terminated.
  char small[8];
  written = formatFields(small, sizeof(small), 1, 2, true, LocalCause::None);
  assert(static_cast<size_t>(written) >= sizeof(small));
  assert(small[sizeof(small) - 1] == '\0');
  return 0;
}
