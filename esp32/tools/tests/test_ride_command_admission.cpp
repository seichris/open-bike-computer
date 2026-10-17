#include "../../lib/ble_navigation/ride_command_admission.hpp"
#include <cassert>
#include <initializer_list>
#include <cstdio>

int main() {
  using namespace ride_command_admission;
  // Every feature channel uses the same mandatory boundary. Only the explicitly
  // separate ownership handshake can accept an unauthenticated payload.
  for (bool ready : {false, true}) {
    for (bool transport : {false, true}) {
      for (bool ownership : {false, true}) {
        assert(mayDecode(false, ready, transport, ownership) ==
               (ready && transport && ownership));
        assert(mayDecode(true, ready, transport, ownership));
      }
    }
  }
  assert(mayApply({1, 2}, {1, 2}, true));
  assert(!mayApply({1, 2}, {2, 2}, true)); // reconnect, even same lease
  assert(!mayApply({1, 2}, {1, 3}, true)); // release, transfer, revoke
  assert(!mayApply({1, 2}, {1, 2}, false));
  assert(!mayApply({0, 0}, {0, 0}, true));
  assert(notificationChannel(false, true, 100, 52) == NotificationChannel::Navigation);
  assert(notificationChannel(true, true, 100, 52) == NotificationChannel::Native);
  assert(notificationChannel(false, false, 100, 52) == NotificationChannel::None);
  assert(notificationChannel(true, true, 23, 52) == NotificationChannel::None);
  assert(notificationChannel(false, true, 80, 52) == NotificationChannel::None);
  assert(notificationChannel(true, true, 80, 52) == NotificationChannel::Native);
  puts("Ride command admission and subscribed notification policy passed");
}
