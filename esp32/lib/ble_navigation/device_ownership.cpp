#include "device_ownership.hpp"

#include <Preferences.h>
#include <esp_system.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdio>
#include <cstring>

namespace device_ownership {
namespace {

constexpr char NVS_NAMESPACE[] = "bleOwner";
constexpr char DEVICE_ID_KEY[] = "deviceId";
constexpr char OWNER_VERSION_KEY[] = "version";
constexpr char OWNER_ID_KEY[] = "ownerId";
constexpr char OWNER_KEY_KEY[] = "ownerKey";
constexpr char DEVICE_NAME_KEY[] = "name";
constexpr uint8_t OWNER_VERSION = 2;

std::vector<std::string> split(const std::string &value) {
  std::vector<std::string> parts;
  size_t start = 0;
  while (start <= value.size()) {
    const size_t separator = value.find('|', start);
    if (separator == std::string::npos) {
      parts.push_back(value.substr(start));
      break;
    }
    parts.push_back(value.substr(start, separator - start));
    start = separator + 1;
  }
  return parts;
}

bool isHexNonce(const std::string &nonce) {
  return nonce.size() == 32 &&
         std::all_of(nonce.begin(), nonce.end(), [](unsigned char character) {
           return std::isxdigit(character) != 0;
         });
}

std::array<uint8_t, 32>
proofFor(const OwnerKey &key, const char *prefix,
         const TranscriptHash &transcriptHash) {
  std::array<uint8_t, 32> proof{};
  std::array<uint8_t, 7 + TRANSCRIPT_HASH_SIZE> message{};
  const size_t prefixLength = strlen(prefix);
  if (prefixLength > 7) {
    return proof;
  }
  memcpy(message.data(), prefix, prefixLength);
  memcpy(message.data() + prefixLength, transcriptHash.data(),
         transcriptHash.size());
  hmacSha256(key.data(), key.size(), message.data(),
             prefixLength + transcriptHash.size(), proof.data());
  return proof;
}

std::array<uint8_t, 32> stringProofFor(const OwnerKey &key,
                                       const std::string &message) {
  std::array<uint8_t, 32> proof{};
  hmacSha256(key.data(), key.size(),
             reinterpret_cast<const uint8_t *>(message.data()), message.size(),
             proof.data());
  return proof;
}

bool ownerMatches(const OwnerId &expected, const std::string &candidateHex) {
  OwnerId candidate{};
  return hexDecode(candidateHex, candidate.data(), candidate.size()) &&
         constantTimeEquals(expected.data(), candidate.data(), expected.size());
}

} // namespace

std::string hexEncode(const uint8_t *data, size_t length) {
  static const char digits[] = "0123456789abcdef";
  if (data == nullptr) {
    return "";
  }
  std::string result(length * 2, '0');
  for (size_t index = 0; index < length; index++) {
    result[index * 2] = digits[(data[index] >> 4) & 0x0F];
    result[index * 2 + 1] = digits[data[index] & 0x0F];
  }
  return result;
}

bool hexDecode(const std::string &hex, uint8_t *out, size_t length) {
  if (out == nullptr || hex.size() != length * 2) {
    return false;
  }
  auto nibble = [](char value) -> int {
    if (value >= '0' && value <= '9')
      return value - '0';
    if (value >= 'a' && value <= 'f')
      return value - 'a' + 10;
    if (value >= 'A' && value <= 'F')
      return value - 'A' + 10;
    return -1;
  };
  for (size_t index = 0; index < length; index++) {
    const int high = nibble(hex[index * 2]);
    const int low = nibble(hex[index * 2 + 1]);
    if (high < 0 || low < 0) {
      return false;
    }
    out[index] = static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

bool isValidDeviceName(const std::string &name) {
  if (name.empty() || name.size() > MAX_DEVICE_NAME_BYTES) {
    return false;
  }
  for (const unsigned char byte : name) {
    if (byte == 0 || byte == '|' || byte < 0x20 || byte == 0x7F) {
      return false;
    }
  }
  return true;
}

bool DeviceOwnership::begin() {
  if (!loadOrCreateDeviceId()) {
    return false;
  }
  loadOwner();
  if (deviceName_.empty()) {
    deviceName_ = defaultDeviceName();
  }
  return true;
}

void DeviceOwnership::resetConnection() {
  sessionAuthenticated_ = false;
  pendingAuthNonce_[0] = '\0';
  clearPairing();
}

void DeviceOwnership::process(uint32_t nowMs) {
  if (pairingActive_ &&
      static_cast<uint32_t>(nowMs - pairingStartedMs_) >
          PAIRING_SESSION_TIMEOUT_MS) {
    clearPairing();
  }
}

CommandResult DeviceOwnership::handle(const std::string &payload,
                                      uint32_t nowMs) {
  const std::vector<std::string> parts = split(payload);
  CommandResult result;
  if (parts.empty()) {
    return result;
  }

  if (parts[0] == "INFO" && parts.size() == 1) {
    result.matched = true;
    result.response = "DEVICE|2|" + deviceIdHex() + "|" +
                      (claimed_ ? "1" : "0") + "|" +
                      hexEncode(reinterpret_cast<const uint8_t *>(
                                    deviceName_.data()),
                                deviceName_.size());
    return result;
  }

  if (parts[0] == "PAIR" && parts.size() == 3) {
    result.matched = true;
    if (claimed_) {
      result.response = "OWNED|" + deviceIdHex();
      return result;
    }

    OwnerId requestedOwner{};
    PublicKey appPublicKey{};
    if (!hexDecode(parts[1], requestedOwner.data(), requestedOwner.size()) ||
        !hexDecode(parts[2], appPublicKey.data(), appPublicKey.size())) {
      result.response = "ERROR|invalid_pairing_request";
      return result;
    }
    if (!pairingKey_.generate() ||
        !pairingKey_.publicKey(pendingDevicePublicKey_) ||
        !pairingKey_.derive(appPublicKey, deviceId_, requestedOwner,
                            appPublicKey, pendingDevicePublicKey_,
                            pendingPairing_)) {
      clearPairing();
      result.response = "ERROR|pairing_setup_failed";
      return result;
    }

    pendingOwnerId_ = requestedOwner;
    pendingAppPublicKey_ = appPublicKey;
    pendingDeviceName_.clear();
    pairingStartedMs_ = nowMs;
    pairingActive_ = true;
    result.event = Event::PairingStarted;
    result.response = "PAIRING|" + deviceIdHex() + "|" +
                      hexEncode(pendingDevicePublicKey_.data(),
                                pendingDevicePublicKey_.size());
    return result;
  }

  if (parts[0] == "CONFIRM" && parts.size() == 4) {
    result.matched = true;
    if (pairingActive_ && !pairingConfirmedOnDevice_) {
      result.response = "ERROR|physical_confirmation_required";
      return result;
    }
    std::array<uint8_t, 32> suppliedProof{};
    std::array<uint8_t, MAX_DEVICE_NAME_BYTES> nameBytes{};
    const std::array<uint8_t, 32> expectedProof =
        proofFor(pendingPairing_.ownerKey, "claim|",
                 pendingPairing_.transcriptHash);
    if (!pairingActive_ ||
        static_cast<uint32_t>(nowMs - pairingStartedMs_) >
            PAIRING_SESSION_TIMEOUT_MS ||
        !ownerMatches(pendingOwnerId_, parts[1]) ||
        !hexDecode(parts[2], suppliedProof.data(), suppliedProof.size()) ||
        !constantTimeEquals(expectedProof.data(), suppliedProof.data(),
                            expectedProof.size()) ||
        parts[3].empty() || parts[3].size() > MAX_DEVICE_NAME_BYTES * 2 ||
        parts[3].size() % 2 != 0 ||
        !hexDecode(parts[3], nameBytes.data(), parts[3].size() / 2)) {
      result.response = "ERROR|pairing_confirmation_failed";
      clearPairing();
      return result;
    }

    pendingDeviceName_ = std::string(
        reinterpret_cast<const char *>(nameBytes.data()), parts[3].size() / 2);
    if (!isValidDeviceName(pendingDeviceName_)) {
      result.response = "ERROR|pairing_confirmation_failed";
      clearPairing();
      return result;
    }

    ownerId_ = pendingOwnerId_;
    ownerKey_ = pendingPairing_.ownerKey;
    deviceName_ = pendingDeviceName_;
    claimed_ = persistOwner();
    if (!claimed_) {
      result.response = "ERROR|pairing_persistence_failed";
      ownerId_.fill(0);
      ownerKey_.fill(0);
      deviceName_ = defaultDeviceName();
      clearPairing();
      return result;
    }
    result.event = Event::Paired;
    result.response = "PAIRED|" + deviceIdHex() + "|" +
                      hexEncode(reinterpret_cast<const uint8_t *>(
                                    deviceName_.data()),
                                deviceName_.size());
    clearPairing();
    return result;
  }

  if (parts[0] == "OWNER" && parts.size() == 3) {
    result.matched = true;
    sessionAuthenticated_ = false;
    if (!claimed_ || !ownerMatches(ownerId_, parts[1]) ||
        !isHexNonce(parts[2])) {
      result.response = "DENIED|" + deviceIdHex();
      return result;
    }
    strncpy(pendingAuthNonce_, parts[2].c_str(),
            sizeof(pendingAuthNonce_) - 1);
    pendingAuthNonce_[sizeof(pendingAuthNonce_) - 1] = '\0';
    const std::string message = "server2|" + deviceIdHex() + "|" + parts[1] +
                                "|" + parts[2];
    const auto proof = stringProofFor(ownerKey_, message);
    result.response = "SERVER2|" + deviceIdHex() + "|" + parts[2] + "|" +
                      hexEncode(proof.data(), proof.size());
    return result;
  }

  if (parts[0] == "PROOF" && parts.size() == 4) {
    result.matched = true;
    std::array<uint8_t, 32> suppliedProof{};
    const std::string message = "client2|" + deviceIdHex() + "|" + parts[1] +
                                "|" + parts[2];
    const auto expectedProof = stringProofFor(ownerKey_, message);
    if (!claimed_ || parts[2].size() != 32 ||
        !ownerMatches(ownerId_, parts[1]) ||
        !constantTimeEquals(reinterpret_cast<const uint8_t *>(
                                pendingAuthNonce_),
                            reinterpret_cast<const uint8_t *>(
                                parts[2].c_str()),
                            32) ||
        pendingAuthNonce_[32] != '\0' ||
        !hexDecode(parts[3], suppliedProof.data(), suppliedProof.size()) ||
        !constantTimeEquals(expectedProof.data(), suppliedProof.data(),
                            expectedProof.size())) {
      result.response = "DENIED|" + deviceIdHex();
      pendingAuthNonce_[0] = '\0';
      return result;
    }
    pendingAuthNonce_[0] = '\0';
    sessionAuthenticated_ = true;
    result.event = Event::Authenticated;
    result.response = "OK2|" + deviceIdHex() + "|" + parts[2];
    return result;
  }

  if (parts[0] == "NAME" && parts.size() == 2) {
    result.matched = true;
    std::array<uint8_t, MAX_DEVICE_NAME_BYTES> nameBytes{};
    if (!sessionAuthenticated_ || parts[1].empty() ||
        parts[1].size() > MAX_DEVICE_NAME_BYTES * 2 ||
        parts[1].size() % 2 != 0 ||
        !hexDecode(parts[1], nameBytes.data(), parts[1].size() / 2)) {
      result.response = "ERROR|rename_rejected";
      return result;
    }
    const std::string name(reinterpret_cast<const char *>(nameBytes.data()),
                           parts[1].size() / 2);
    if (!setDeviceName(name)) {
      result.response = "ERROR|rename_rejected";
      return result;
    }
    result.event = Event::Renamed;
    result.response = "NAME_OK|" + parts[1];
    return result;
  }

  if (parts[0] == "UNPAIR" && parts.size() == 1) {
    result.matched = true;
    if (!sessionAuthenticated_) {
      result.response = "ERROR|unpair_rejected";
      return result;
    }
    const std::string id = deviceIdHex();
    if (!clearOwner()) {
      result.response = "ERROR|unpair_persistence_failed";
      return result;
    }
    result.event = Event::Unpaired;
    result.response = "UNPAIRED|" + id;
    return result;
  }

  return result;
}

bool DeviceOwnership::confirmPairingOnDevice() {
  if (!pairingActive_) {
    return false;
  }
  pairingConfirmedOnDevice_ = true;
  return true;
}

bool DeviceOwnership::clearOwner() {
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  const bool markerRemoved = !preferences.isKey(OWNER_VERSION_KEY) ||
                             preferences.remove(OWNER_VERSION_KEY);
  preferences.remove(OWNER_ID_KEY);
  preferences.remove(OWNER_KEY_KEY);
  preferences.remove(DEVICE_NAME_KEY);
  preferences.end();
  if (!markerRemoved) {
    return false;
  }
  ownerId_.fill(0);
  ownerKey_.fill(0);
  claimed_ = false;
  sessionAuthenticated_ = false;
  deviceName_ = defaultDeviceName();
  clearPairing();
  return true;
}

std::string DeviceOwnership::deviceIdHex() const {
  return hexEncode(deviceId_.data(), deviceId_.size());
}

std::string DeviceOwnership::advertisedName() const { return deviceName_; }

std::vector<uint8_t> DeviceOwnership::advertisementManufacturerData() const {
  return {0xFF, 0xFF, PROTOCOL_VERSION,
          static_cast<uint8_t>(claimed_ ? 1 : 0), deviceId_[12], deviceId_[13],
          deviceId_[14], deviceId_[15]};
}

bool DeviceOwnership::loadOrCreateDeviceId() {
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  if (preferences.getBytesLength(DEVICE_ID_KEY) == deviceId_.size() &&
      preferences.getBytes(DEVICE_ID_KEY, deviceId_.data(), deviceId_.size()) ==
          deviceId_.size()) {
    preferences.end();
    return true;
  }
  esp_fill_random(deviceId_.data(), deviceId_.size());
  const bool stored = preferences.putBytes(DEVICE_ID_KEY, deviceId_.data(),
                                           deviceId_.size()) == deviceId_.size();
  preferences.end();
  return stored;
}

bool DeviceOwnership::loadOwner() {
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  const bool valid = preferences.getUChar(OWNER_VERSION_KEY, 0) ==
                         OWNER_VERSION &&
                     preferences.getBytesLength(OWNER_ID_KEY) ==
                         ownerId_.size() &&
                     preferences.getBytesLength(OWNER_KEY_KEY) ==
                         ownerKey_.size();
  if (valid) {
    claimed_ = preferences.getBytes(OWNER_ID_KEY, ownerId_.data(),
                                    ownerId_.size()) == ownerId_.size() &&
               preferences.getBytes(OWNER_KEY_KEY, ownerKey_.data(),
                                    ownerKey_.size()) == ownerKey_.size();
    deviceName_ = preferences.getString(DEVICE_NAME_KEY, "").c_str();
    if (!isValidDeviceName(deviceName_)) {
      deviceName_ = defaultDeviceName();
    }
  }
  preferences.end();
  return claimed_;
}

bool DeviceOwnership::persistOwner() {
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  preferences.remove(OWNER_VERSION_KEY);
  const bool stored =
      preferences.putBytes(OWNER_ID_KEY, ownerId_.data(), ownerId_.size()) ==
          ownerId_.size() &&
      preferences.putBytes(OWNER_KEY_KEY, ownerKey_.data(), ownerKey_.size()) ==
          ownerKey_.size() &&
      preferences.putString(DEVICE_NAME_KEY, deviceName_.c_str()) ==
          deviceName_.size() &&
      preferences.putUChar(OWNER_VERSION_KEY, OWNER_VERSION) == sizeof(uint8_t);
  preferences.end();
  return stored;
}

void DeviceOwnership::clearPairing() {
  pairingKey_.clear();
  pendingPairing_ = {};
  pendingOwnerId_.fill(0);
  pendingAppPublicKey_.fill(0);
  pendingDevicePublicKey_.fill(0);
  pendingDeviceName_.clear();
  pairingStartedMs_ = 0;
  pairingActive_ = false;
  pairingConfirmedOnDevice_ = false;
}

std::string DeviceOwnership::defaultDeviceName() const {
  char name[24];
  snprintf(name, sizeof(name), "BikeComputer %02X%02X", deviceId_[14],
           deviceId_[15]);
  return name;
}

bool DeviceOwnership::setDeviceName(const std::string &name) {
  if (!isValidDeviceName(name)) {
    return false;
  }
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  const bool stored = preferences.putString(DEVICE_NAME_KEY, name.c_str()) ==
                      name.size();
  preferences.end();
  if (!stored) {
    return false;
  }
  deviceName_ = name;
  return true;
}

} // namespace device_ownership
