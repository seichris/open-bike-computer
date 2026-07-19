#include "../../lib/ble_navigation/device_ownership_crypto.hpp"

#include <algorithm>
#include <cassert>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <sstream>

template <typename Container> std::string hex(const Container &value) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (uint8_t byte : value) {
    stream << std::setw(2) << static_cast<unsigned int>(byte);
  }
  return stream.str();
}

int main() {
  using namespace device_ownership;

  uint8_t appPrivate[32]{};
  uint8_t devicePrivate[32]{};
  appPrivate[31] = 1;
  devicePrivate[31] = 2;

  PairingKeyAgreement app;
  PairingKeyAgreement device;
  assert(app.setPrivateKeyForTesting(appPrivate));
  assert(device.setPrivateKeyForTesting(devicePrivate));

  PublicKey appPublic{};
  PublicKey devicePublic{};
  assert(app.publicKey(appPublic));
  assert(device.publicKey(devicePublic));
  assert(appPublic[0] == 0x04);
  assert(devicePublic[0] == 0x04);

  DeviceId deviceId{};
  OwnerId ownerId{};
  for (size_t index = 0; index < deviceId.size(); index++) {
    deviceId[index] = static_cast<uint8_t>(index);
    ownerId[index] = static_cast<uint8_t>(0xF0 + index);
  }

  PairingMaterial appMaterial{};
  PairingMaterial deviceMaterial{};
  assert(app.derive(devicePublic, deviceId, ownerId, appPublic, devicePublic,
                    appMaterial));
  assert(device.derive(appPublic, deviceId, ownerId, appPublic, devicePublic,
                       deviceMaterial));
  assert(appMaterial.ownerKey == deviceMaterial.ownerKey);
  assert(appMaterial.transcriptHash == deviceMaterial.transcriptHash);
  assert(appMaterial.comparisonCode == deviceMaterial.comparisonCode);
  assert(hex(appMaterial.ownerKey) ==
         "024d0fb0b003b6d22569ef8e5a382eaa9bbd29ebeaee683d93992ae1399900cf");
  assert(hex(appMaterial.transcriptHash) ==
         "9d0aa8a0aa3fb676d1a80412b522ca25047e52a59dde1bedcf18f3dc583b2072");
  assert(appMaterial.comparisonCode == 983668);

  DeviceId differentDeviceId = deviceId;
  differentDeviceId[0] ^= 0xFF;
  PairingMaterial differentMaterial{};
  assert(app.derive(devicePublic, differentDeviceId, ownerId, appPublic,
                    devicePublic, differentMaterial));
  assert(differentMaterial.ownerKey != appMaterial.ownerKey);
  assert(differentMaterial.transcriptHash != appMaterial.transcriptHash);

  uint8_t digest[32]{};
  const uint8_t key[] = {1, 2, 3};
  const uint8_t message[] = {4, 5, 6};
  assert(hmacSha256(key, sizeof(key), message, sizeof(message), digest));
  assert(constantTimeEquals(digest, digest, sizeof(digest)));
  uint8_t changed[32]{};
  std::copy(std::begin(digest), std::end(digest), std::begin(changed));
  changed[31] ^= 1;
  assert(!constantTimeEquals(digest, changed, sizeof(digest)));

  std::cout << "device ownership crypto tests passed\n";
  return 0;
}
