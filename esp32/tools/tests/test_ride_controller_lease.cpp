#include "../../lib/ble_navigation/ride_controller_lease.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

using ride_controller_lease::ClaimResult;
using ride_controller_lease::ControllerId;
using ride_controller_lease::ControllerIdentity;
using ride_controller_lease::ControllerRole;
using ride_controller_lease::RideControllerLease;

int main() {
  const ControllerId iphoneId{0x1111, 0xaaaa};
  const ControllerId watchId{0x2222, 0xbbbb};
  const ControllerIdentity iphone{iphoneId, 0x101, ControllerRole::Owner};
  const ControllerIdentity watch{watchId, 0x202,
                                 ControllerRole::ScopedWatch};
  const ControllerIdentity sameControllerNewSession{
      iphoneId, 0x303, ControllerRole::Owner};
  const ControllerIdentity sameValueWrongRole{
      iphoneId, 0x101, ControllerRole::ScopedWatch};
  const ControllerIdentity invalidRole{
      iphoneId, 0x101, static_cast<ControllerRole>(0xff)};
  const ControllerIdentity invalid{};

  RideControllerLease lease(1000);
  assert(lease.claim(invalid, 10) == ClaimResult::InvalidController);
  assert(lease.claim(invalidRole, 10) == ClaimResult::InvalidController);
  assert(lease.claim(iphone, 10) == ClaimResult::Granted);
  const uint32_t firstGeneration = lease.generation();
  assert(firstGeneration != 0);
  assert(lease.allows(iphone, 10));
  assert(!lease.allows(watch, 10));
  assert(!lease.allows(sameValueWrongRole, 10));
  assert(lease.claim(watch, 11) == ClaimResult::Busy);
  assert(lease.claim(sameControllerNewSession, 11) == ClaimResult::Busy);
  assert(lease.claim(sameValueWrongRole, 11) == ClaimResult::Busy);

  assert(lease.recordActivity(iphone, 900));
  assert(lease.isActive(1899));
  assert(!lease.isActive(1900));
  assert(!lease.allows(iphone, 1900));

  assert(lease.claim(watch, 1901) == ClaimResult::Granted);
  assert(lease.generation() != firstGeneration);
  assert(lease.claim(watch, 1950) == ClaimResult::Renewed);
  assert(lease.release(watch));
  assert(!lease.release(watch));

  assert(lease.claim(iphone, 2000) == ClaimResult::Granted);
  lease.disconnect(watch);
  assert(lease.allows(iphone, 2001));
  lease.disconnect(iphone);
  assert(!lease.isActive(2001));

  assert(lease.claim(watch, 3000) == ClaimResult::Granted);
  lease.revoke(iphoneId);
  assert(lease.allows(watch, 3001));
  lease.revoke(watchId);
  assert(!lease.isActive(3001));

  // Unsigned elapsed-time arithmetic must survive millis() rollover.
  RideControllerLease wrappingLease(32);
  assert(wrappingLease.claim(iphone, UINT32_MAX - 15) ==
         ClaimResult::Granted);
  assert(wrappingLease.isActive(15));
  assert(!wrappingLease.isActive(16));

  // A zero configuration must fail closed to the production default rather
  // than silently creating a non-expiring writer.
  RideControllerLease zeroTimeout(0);
  assert(zeroTimeout.claim(iphone, 1) == ClaimResult::Granted);
  assert(zeroTimeout.isActive(15000));
  assert(!zeroTimeout.isActive(15001));

  std::cout << "ride controller lease tests passed\n";
  return 0;
}
