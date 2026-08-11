#pragma once

#include "device_ownership_crypto.hpp"
#include "ride_controller_lease.hpp"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

class Preferences;

namespace device_ownership {

constexpr uint8_t PROTOCOL_VERSION = 2;
constexpr size_t MAX_DEVICE_NAME_BYTES = 24;
constexpr uint32_t PAIRING_SESSION_TIMEOUT_MS = 120000;
constexpr size_t AUTHENTICATED_FRAME_OVERHEAD = 22;

enum class AuthenticatedChannel : uint8_t {
  Auth = 1,
  Navigation = 2,
  Route = 3,
  Gps = 4,
  Settings = 5,
  Workout = 6,
  RideAutomation = 7,
};

enum class Event {
  None,
  PairingStarted,
  Paired,
  Authenticated,
  Renamed,
  Unpaired,
  WatchControllerStaged,
  WatchControllerCommitted,
  WatchControllerRevoked,
};

enum class SessionRole : uint8_t {
  None = 0,
  Owner = 1,
  WatchRide = 2,
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
  bool armPairingConfirmation(uint32_t pairingGeneration);
  bool confirmPairingOnDevice();
  bool clearOwner();
  bool unwrapAuthenticatedPayload(AuthenticatedChannel channel,
                                  const std::string &frame,
                                  std::string &payload);
  bool protectAuthenticatedPayload(AuthenticatedChannel channel,
                                   const std::string &payload,
                                   std::string &frame);
  bool authorizeRideWrite(AuthenticatedChannel channel, uint32_t nowMs);
  bool isOwnerSession() const {
    return sessionAuthenticated_ && sessionRole_ == SessionRole::Owner;
  }
  bool isWatchRideSession() const {
    return sessionAuthenticated_ && sessionRole_ == SessionRole::WatchRide;
  }
  SessionRole sessionRole() const { return sessionRole_; }
  bool hasWatchController() const { return watchControllerActive_; }
  bool watchControllerSubsystemReady() const {
    return watchControllerStorageValid_;
  }
#ifdef DEVICE_OWNERSHIP_HOST_TEST
  void setAuthenticatedSessionKeysForTesting(const OwnerKey &writeKey,
                                             const OwnerKey &notifyKey) {
    sessionWriteKey_ = writeKey;
    sessionNotifyKey_ = notifyKey;
    lastInboundSequence_.fill(0);
    nextOutboundSequence_.fill(0);
    sessionAuthenticated_ = true;
    sessionRole_ = SessionRole::Owner;
    sessionControllerId_.fill(0);
    sessionControllerId_[0] = 1;
    sessionId_ = 1;
    rideLease_.claim(currentControllerIdentity(), 0);
  }
#endif

  bool isClaimed() const { return claimed_; }
  bool allowsLegacyAuthentication() const {
    return legacyAuthenticationAllowed_;
  }
  bool isSessionAuthenticated() const { return sessionAuthenticated_; }
  const DeviceId &deviceId() const { return deviceId_; }
  const std::string &deviceName() const { return deviceName_; }
  std::string deviceIdHex() const;
  std::string advertisedName() const;
  std::vector<uint8_t> advertisementManufacturerData() const;

  bool hasPairingCode() const { return pairingActive_; }
  bool isPairingConfirmedOnDevice() const {
    return pairingActive_ && pairingConfirmedOnDevice_;
  }
  uint32_t pairingCode() const { return pendingPairing_.comparisonCode; }
  uint32_t pairingGeneration() const { return pairingGeneration_; }

private:
  bool loadOrCreateDeviceId();
  bool loadOwner();
  bool persistOwner();
  bool loadWatchController();
  bool persistStagedWatchController();
  bool commitStagedWatchController();
  bool revokeWatchController(const std::array<uint8_t, 16> &controllerId);
  bool clearWatchControllerStorage(Preferences &preferences);
  void clearStagedWatchControllerMemory();
  void clearActiveWatchControllerMemory();
  void clearAuthenticatedSession(bool releaseLease);
  ride_controller_lease::ControllerIdentity currentControllerIdentity() const;
  bool beginAuthenticatedSession(SessionRole role,
                                 const std::array<uint8_t, 16> &controllerId,
                                 const OwnerKey &credentialKey,
                                 const char *writeLabel,
                                 const char *notifyLabel,
                                 const std::string &sessionContext,
                                 bool claimOwnerLease,
                                 uint32_t nowMs);
  bool clearOwnerStorage(bool preserveSession, bool preserveRevocationReceipt);
  bool persistRevocationReceipt(const OwnerId &ownerId,
                                const std::array<uint8_t, 16> &nonce,
                                const std::array<uint8_t, 32> &proof);
  bool clearRevocationReceipt(Preferences &preferences);
  void clearPairing();
  std::string defaultDeviceName() const;
  bool setDeviceName(const std::string &name);

  DeviceId deviceId_{};
  OwnerId ownerId_{};
  OwnerKey ownerKey_{};
  OwnerKey sessionWriteKey_{};
  OwnerKey sessionNotifyKey_{};
  std::string deviceName_;
  bool claimed_ = false;
  bool ownerRecordValid_ = false;
  bool legacyAuthenticationAllowed_ = false;
  bool sessionAuthenticated_ = false;
  SessionRole sessionRole_ = SessionRole::None;
  std::array<uint8_t, 16> sessionControllerId_{};
  uint64_t sessionId_ = 0;
  bool deviceIdIntegrityValid_ = true;

  std::array<uint8_t, 16> watchControllerId_{};
  OwnerKey watchControllerKey_{};
  std::array<uint8_t, 16> stagedWatchControllerId_{};
  OwnerKey stagedWatchControllerKey_{};
  std::array<uint8_t, 16> stagedWatchChallenge_{};
  bool watchControllerActive_ = false;
  bool stagedWatchControllerValid_ = false;
  bool watchControllerStorageValid_ = true;
  uint8_t activeWatchControllerSlot_ = 0;
  ride_controller_lease::RideControllerLease rideLease_{};
  SessionRole pendingAuthenticationRole_ = SessionRole::None;
  std::array<uint8_t, 16> pendingAuthenticationControllerId_{};

  PairingKeyAgreement pairingKey_;
  PairingMaterial pendingPairing_{};
  OwnerId pendingOwnerId_{};
  PublicKey pendingAppPublicKey_{};
  PublicKey pendingDevicePublicKey_{};
  std::string pendingDeviceName_;
  uint32_t pairingStartedMs_ = 0;
  uint32_t pairingGeneration_ = 0;
  uint32_t armedPairingGeneration_ = 0;
  bool pairingActive_ = false;
  bool pairingConfirmedOnDevice_ = false;
  bool pairingAttemptedOnConnection_ = false;

  OwnerId revokedOwnerId_{};
  std::array<uint8_t, 16> revocationNonce_{};
  std::array<uint8_t, 32> revocationProof_{};
  bool revocationReceiptValid_ = false;

  char pendingAuthNonce_[33] = "";
  char pendingServerAuthNonce_[33] = "";
  std::array<uint32_t, 8> lastInboundSequence_{};
  std::array<uint32_t, 8> nextOutboundSequence_{};
};

std::string hexEncode(const uint8_t *data, size_t length);
bool hexDecode(const std::string &hex, uint8_t *out, size_t length);
bool isValidDeviceName(const std::string &name);

} // namespace device_ownership
