#include "../../lib/ble_navigation/transfer_control_dispatch.hpp"

#include <cassert>
#include <iostream>

using ble_transfer::Action;
using ble_transfer::NotifyGeneric;
using ble_transfer::NotifyMap;
using ble_transfer::NotifyNone;
using ble_transfer::NotifyRendererDiagnostics;
using ble_transfer::PendingRequest;

int main() {
  PendingRequest pending;
  assert(pending.take().empty());

  pending.merge(Action::EnableMap, NotifyMap);
  pending.merge(Action::None, NotifyGeneric);
  auto request = pending.take();
  assert(request.action == Action::EnableMap);
  assert(request.notifications == (NotifyMap | NotifyGeneric));

  pending.merge(Action::None, NotifyRendererDiagnostics);
  pending.merge(Action::None, NotifyMap);
  request = pending.take();
  assert(request.action == Action::None);
  assert(request.notifications ==
         (NotifyRendererDiagnostics | NotifyMap));

  pending.merge(Action::EnableMap, NotifyMap);
  pending.merge(Action::EnableDebug, NotifyGeneric);
  request = pending.take();
  assert(request.action == Action::EnableDebug);
  assert(request.notifications == (NotifyMap | NotifyGeneric));
  assert(pending.take().empty());

  pending.merge(Action::EnableMap, NotifyMap);
  pending.merge(Action::DisableMap, NotifyNone);
  request = pending.take();
  assert(request.action == Action::DisableMap);
  assert(request.notifications == NotifyMap);

  pending.merge(Action::EnableFirmware, NotifyGeneric);
  pending.merge(Action::DisableAll, NotifyMap);
  request = pending.take();
  assert(request.action == Action::DisableAll);
  assert(request.notifications == (NotifyMap | NotifyGeneric));

  pending.merge(Action::EnableDebug, NotifyGeneric);
  pending.merge(Action::DisableOnBleDisconnect, NotifyNone);
  request = pending.take();
  assert(request.disconnectCleanup);
  assert(request.action == Action::None);
  assert(request.notifications == NotifyNone);
  assert(pending.take().empty());

  pending.merge(Action::DisableOnBleDisconnect, NotifyNone);
  pending.merge(Action::EnableMap, NotifyMap);
  request = pending.take();
  assert(request.disconnectCleanup);
  assert(request.action == Action::EnableMap);
  assert(request.notifications == NotifyMap);

  pending.merge(Action::DisableOnBleDisconnect, NotifyNone);
  pending.merge(Action::EnableDebug, NotifyGeneric);
  request = pending.take();
  assert(request.disconnectCleanup);
  assert(request.action == Action::EnableDebug);
  assert(request.notifications == NotifyGeneric);

  std::cout << "transfer control dispatch tests passed\n";
  return 0;
}
