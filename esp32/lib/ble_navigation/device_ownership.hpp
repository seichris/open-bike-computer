#pragma once

#include "device_ownership_crypto.hpp"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace device_ownership {

constexpr uint8_t PROTOCOL_VERSION = 2;
constexpr size_t MAX_DEVICE_NAME_BYTES = 24;
constexpr uint32_t PAIRING_SESSION_TIMEOUT_MS = 120000;

enum class Event {
  None,
  PairingStarted,
  Paired,
  Authenticated,
  Renamed,
  Unpaired,
};

struct CommandResult {
  bool matched = false;
  Event event = Event::None;
  std::string response;
};

class DeviceOwnership {
public:
  bool begin();
  void resetConnection();
  void process(uint32_t nowMs);

  CommandResult handle(const std::string &payload, uint32_t nowMs);
  bool confirmPairingOnDevice();
  bool clearOwner();

  bool isClaimed() const { return claimed_; }
  bool isSessionAuthenticated() const { return sessionAuthenticated_; }
  const DeviceId &deviceId() const { return deviceId_; }
  const std::string &deviceName() const { return deviceName_; }
  std::string deviceIdHex() const;
  std::string advertisedName() const;
  std::vector<uint8_t> advertisementManufacturerData() const;

  bool hasPairingCode() const { return pairingActive_; }
  uint32_t pairingCode() const { return pendingPairing_.comparisonCode; }

private:
  bool loadOrCreateDeviceId();
  bool loadOwner();
  bool persistOwner();
  void clearPairing();
  std::string defaultDeviceName() const;
  bool setDeviceName(const std::string &name);

  DeviceId deviceId_{};
  OwnerId ownerId_{};
  OwnerKey ownerKey_{};
  std::string deviceName_;
  bool claimed_ = false;
  bool sessionAuthenticated_ = false;

  PairingKeyAgreement pairingKey_;
  PairingMaterial pendingPairing_{};
  OwnerId pendingOwnerId_{};
  PublicKey pendingAppPublicKey_{};
  PublicKey pendingDevicePublicKey_{};
  std::string pendingDeviceName_;
  uint32_t pairingStartedMs_ = 0;
  bool pairingActive_ = false;
  bool pairingConfirmedOnDevice_ = false;

  char pendingAuthNonce_[33] = "";
};

std::string hexEncode(const uint8_t *data, size_t length);
bool hexDecode(const std::string &hex, uint8_t *out, size_t length);
bool isValidDeviceName(const std::string &name);

} // namespace device_ownership
