#include "../../lib/ble_navigation/screen_configuration.hpp"

#include <cassert>

using namespace screen_configuration;
using screen_configuration_protocol::ScreenType;

int main() {
  CommitPersistenceProgress persistence{
      true, true, true, true, true, true, true};
  assert(persistence.complete());
  bool *cutPoints[] = {
      &persistence.inactiveSlotWriteAndReadback,
      &persistence.transactionMarkerWriteAndReadback,
      &persistence.headWriteAndReadback,
      &persistence.legacyMirrorWrite,
      &persistence.legacyMirrorReadback,
      &persistence.mirrorRevisionWriteAndReadback,
      &persistence.transactionClearWriteAndReadback,
  };
  for (bool *cutPoint : cutPoints) {
    *cutPoint = false;
    assert(!persistence.complete());
    *cutPoint = true;
  }

  const SlotCandidate slotA{true, 'A', 4, 0xaaaa};
  const SlotCandidate slotB{true, 'B', 5, 0xbbbb};
  assert(selectActiveSlot(slotA, slotB, true, 'A', 4, 0xaaaa) == 'A');
  assert(selectActiveSlot(slotA, slotB, true, 'A', 4, 0xffff) == 'B');
  assert(selectActiveSlot(slotA, slotB, false, 0, 0, 0) == 'B');
  assert(selectActiveSlot({false, 'A', 0, 0}, slotB, true, 'A', 4,
                          0xaaaa) == 'B');
  assert(selectActiveSlot({false, 'A', 0, 0},
                          {false, 'B', 0, 0}, false, 0, 0, 0) == 0);
  assert(inactiveSlot('A') == 'B');
  assert(inactiveSlot('B') == 'A');
  assert(nextRevision(7) == 8);
  assert(nextRevision(UINT32_MAX) == 1);

  Document document{};
  document.instanceCount = 4;
  document.defaultInstanceID = 10;
  document.instances[0].id = 10;
  document.instances[0].type = ScreenType::Map;
  document.instances[0].enabled = true;
  document.instances[0].mapProfile =
      screen_configuration_protocol::defaultMapProfile(ScreenType::Map);
  document.instances[1] = document.instances[0];
  document.instances[1].id = 11;
  document.instances[1].enabled = false;
  document.instances[2] = document.instances[0];
  document.instances[2].id = 12;
  document.instances[2].type = ScreenType::RideStats;
  document.instances[3] = document.instances[0];
  document.instances[3].id = 13;

  assert(defaultInstanceIndex(document) == 0);
  assert(nextEnabledInstanceIndex(document, 0) == 2);
  assert(nextEnabledInstanceIndex(document, 2) == 3);
  assert(nextEnabledInstanceIndex(document, 3) == 0);
  assert(nextEnabledInstanceOfType(document, 0, ScreenType::Map,
                                   ScreenType::MapNavigation) == 3);

  const uint32_t firstSignature = mapProfileSignature(document.instances[0]);
  document.instances[3].mapProfile.zoomLevel += 1;
  assert(mapProfileSignature(document.instances[3]) != firstSignature);
  document.instances[3].mapProfile = document.instances[0].mapProfile;
  assert(mapProfileSignature(document.instances[3]) == firstSignature);

  const uint32_t mapPayload = screenPayloadSignature(document.instances[0]);
  document.instances[0].mapProfile.zoomLevel += 1;
  assert(screenPayloadSignature(document.instances[0]) != mapPayload);
  document.instances[0].mapProfile.zoomLevel -= 1;
  assert(screenPayloadSignature(document.instances[0]) == mapPayload);
  const uint32_t statsPayload = screenPayloadSignature(document.instances[2]);
  document.instances[2].rideStatsLayout.slots[0] =
      screen_configuration_protocol::RideStatsWidget::Altitude;
  assert(screenPayloadSignature(document.instances[2]) != statsPayload);
  const uint32_t fixedPayload = screenPayloadSignature(document.instances[3]);
  document.instances[3].name[0] = 'X';
  document.instances[3].enabled = false;
  assert(screenPayloadSignature(document.instances[3]) == fixedPayload);
  return 0;
}
