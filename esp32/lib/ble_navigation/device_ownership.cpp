#include "device_ownership.hpp"

#include <Preferences.h>
#include <esp_system.h>
#include <esp_mac.h>
#include <mbedtls/gcm.h>

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
constexpr char REVOCATION_VERSION_KEY[] = "revVersion";
constexpr char REVOKED_OWNER_ID_KEY[] = "revOwner";
constexpr char REVOCATION_NONCE_KEY[] = "revNonce";
constexpr char REVOCATION_PROOF_KEY[] = "revProof";
constexpr uint8_t OWNER_VERSION = 2;
constexpr uint8_t REVOCATION_VERSION = 1;

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

bool proofFor(const OwnerKey &key, const char *prefix,
              const TranscriptHash &transcriptHash,
              std::array<uint8_t, 32> &proof) {
  proof.fill(0);
  std::array<uint8_t, 7 + TRANSCRIPT_HASH_SIZE> message{};
  const size_t prefixLength = strlen(prefix);
  if (prefixLength > 7) {
    return false;
  }
  memcpy(message.data(), prefix, prefixLength);
  memcpy(message.data() + prefixLength, transcriptHash.data(),
         transcriptHash.size());
  return hmacSha256(key.data(), key.size(), message.data(),
                    prefixLength + transcriptHash.size(), proof.data());
}

bool stringProofFor(const OwnerKey &key, const std::string &message,
                    std::array<uint8_t, 32> &proof) {
  proof.fill(0);
  return hmacSha256(key.data(), key.size(),
                    reinterpret_cast<const uint8_t *>(message.data()),
                    message.size(), proof.data());
}

bool ownerMatches(const OwnerId &expected, const std::string &candidateHex) {
  OwnerId candidate{};
  return hexDecode(candidateHex, candidate.data(), candidate.size()) &&
         constantTimeEquals(expected.data(), candidate.data(), expected.size());
}

void makeFrameNonce(AuthenticatedChannel channel, uint32_t sequence,
                    std::array<uint8_t, 12> &nonce) {
  nonce.fill(0);
  nonce[0] = static_cast<uint8_t>(channel);
  nonce[8] = static_cast<uint8_t>(sequence >> 24);
  nonce[9] = static_cast<uint8_t>(sequence >> 16);
  nonce[10] = static_cast<uint8_t>(sequence >> 8);
  nonce[11] = static_cast<uint8_t>(sequence);
}

bool decryptFrame(const OwnerKey &key, AuthenticatedChannel channel,
                  uint32_t sequence, const uint8_t *ciphertext, size_t length,
                  const uint8_t tag[16], const char *aadPrefix,
                  std::string &plaintext) {
  std::array<uint8_t, 12> nonce{};
  makeFrameNonce(channel, sequence, nonce);
  std::vector<uint8_t> aad(aadPrefix, aadPrefix + strlen(aadPrefix));
  aad.push_back(static_cast<uint8_t>(channel));
  aad.push_back(static_cast<uint8_t>(sequence >> 24));
  aad.push_back(static_cast<uint8_t>(sequence >> 16));
  aad.push_back(static_cast<uint8_t>(sequence >> 8));
  aad.push_back(static_cast<uint8_t>(sequence));
  std::vector<uint8_t> output(length);
  uint8_t emptyInput = 0;
  uint8_t emptyOutput = 0;
  const uint8_t *safeCiphertext = length == 0 ? &emptyInput : ciphertext;
  uint8_t *safeOutput = length == 0 ? &emptyOutput : output.data();
  mbedtls_gcm_context context;
  mbedtls_gcm_init(&context);
  const int result =
      mbedtls_gcm_setkey(&context, MBEDTLS_CIPHER_ID_AES, key.data(), 256) == 0
          ? mbedtls_gcm_auth_decrypt(
                &context, length, nonce.data(), nonce.size(), aad.data(),
                aad.size(), tag, 16, safeCiphertext, safeOutput)
                         : -1;
  mbedtls_gcm_free(&context);
  if (result != 0) return false;
  if (output.empty()) {
    plaintext.clear();
  } else {
    plaintext.assign(reinterpret_cast<const char *>(output.data()),
                     output.size());
  }
  return true;
}

bool encryptFrame(const OwnerKey &key, AuthenticatedChannel channel,
                  uint32_t sequence, const std::string &plaintext,
                  const char *aadPrefix, std::string &ciphertext,
                  std::array<uint8_t, 16> &tag) {
  std::array<uint8_t, 12> nonce{};
  makeFrameNonce(channel, sequence, nonce);
  std::vector<uint8_t> aad(aadPrefix, aadPrefix + strlen(aadPrefix));
  aad.push_back(static_cast<uint8_t>(channel));
  aad.push_back(static_cast<uint8_t>(sequence >> 24));
  aad.push_back(static_cast<uint8_t>(sequence >> 16));
  aad.push_back(static_cast<uint8_t>(sequence >> 8));
  aad.push_back(static_cast<uint8_t>(sequence));
  std::vector<uint8_t> output(plaintext.size());
  uint8_t emptyInput = 0;
  uint8_t emptyOutput = 0;
  const uint8_t *safePlaintext =
      plaintext.empty()
          ? &emptyInput
          : reinterpret_cast<const uint8_t *>(plaintext.data());
  uint8_t *safeOutput = plaintext.empty() ? &emptyOutput : output.data();
  mbedtls_gcm_context context;
  mbedtls_gcm_init(&context);
  const int result =
      mbedtls_gcm_setkey(&context, MBEDTLS_CIPHER_ID_AES, key.data(), 256) == 0
          ? mbedtls_gcm_crypt_and_tag(
                &context, MBEDTLS_GCM_ENCRYPT, plaintext.size(), nonce.data(),
                nonce.size(), aad.data(), aad.size(),
                safePlaintext, safeOutput, tag.size(), tag.data())
                         : -1;
  mbedtls_gcm_free(&context);
  if (result != 0) return false;
  if (output.empty()) {
    ciphertext.clear();
  } else {
    ciphertext.assign(reinterpret_cast<const char *>(output.data()),
                      output.size());
  }
  return true;
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
  for (size_t index = 0; index < name.size();) {
    const uint8_t byte = static_cast<uint8_t>(name[index]);
    if (byte == 0 || byte == '|' || byte < 0x20 || byte == 0x7F) {
      return false;
    }
    if (byte <= 0x7F) {
      index++;
      continue;
    }
    size_t continuationCount = 0;
    if (byte >= 0xC2 && byte <= 0xDF) {
      continuationCount = 1;
    } else if (byte >= 0xE0 && byte <= 0xEF) {
      continuationCount = 2;
    } else if (byte >= 0xF0 && byte <= 0xF4) {
      continuationCount = 3;
    } else {
      return false;
    }
    if (index + continuationCount >= name.size()) {
      return false;
    }
    const uint8_t second = static_cast<uint8_t>(name[index + 1]);
    if ((second & 0xC0) != 0x80 ||
        (byte == 0xE0 && second < 0xA0) ||
        (byte == 0xED && second > 0x9F) ||
        (byte == 0xF0 && second < 0x90) ||
        (byte == 0xF4 && second > 0x8F)) {
      return false;
    }
    for (size_t offset = 2; offset <= continuationCount; offset++) {
      if ((static_cast<uint8_t>(name[index + offset]) & 0xC0) != 0x80) {
        return false;
      }
    }
    index += continuationCount + 1;
  }
  return true;
}

bool DeviceOwnership::begin() {
  if (!loadOrCreateDeviceId()) {
    return false;
  }
  if (!loadOwner()) {
    // If ownership storage cannot be read, keep the device locked. Treating an
    // I/O failure as "unclaimed" would silently re-enable the shared v1 key.
    claimed_ = true;
    ownerRecordValid_ = false;
    legacyAuthenticationAllowed_ = false;
  }
  if (!deviceIdIntegrityValid_) {
    // Never bind an otherwise valid owner record to a newly minted identity.
    // Stay recoverably locked until the physical owner-reset action removes
    // the orphaned record.
    claimed_ = true;
    ownerRecordValid_ = false;
    legacyAuthenticationAllowed_ = false;
  }
  if (deviceName_.empty()) {
    deviceName_ = defaultDeviceName();
  }
  return true;
}

void DeviceOwnership::resetConnection() {
  sessionAuthenticated_ = false;
  sessionWriteKey_.fill(0);
  sessionNotifyKey_.fill(0);
  lastInboundSequence_.fill(0);
  nextOutboundSequence_.fill(0);
  pendingAuthNonce_[0] = '\0';
  pendingServerAuthNonce_[0] = '\0';
  clearPairing();
  pairingAttemptedOnConnection_ = false;
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
    if (revocationReceiptValid_ && (!claimed_ || ownerRecordValid_)) {
      // Keep the prior owner's signed receipt visible even after a new owner
      // registers. Omitting the name and already-known owner ID keeps this
      // durable reconciliation record within the supported 182-byte ATT value.
      // A claimed but invalid owner record is a storage failure, not a completed
      // handoff; suppress its receipt so iOS cannot delete the only usable key.
      result.response = "DEVICE|2|" + deviceIdHex() + "|" +
                         (claimed_ ? "1" : "0") + "||" +
                         hexEncode(revocationNonce_.data(),
                                   revocationNonce_.size()) +
                         "|" +
                         hexEncode(revocationProof_.data(),
                                   revocationProof_.size());
    }
    return result;
  }

  if (parts[0] == "PAIR" && parts.size() == 3) {
    result.matched = true;
    if (claimed_) {
      result.response = "OWNED|" + deviceIdHex();
      return result;
    }
    if (pairingAttemptedOnConnection_) {
      result.response = "ERROR|pairing_attempt_already_used";
      return result;
    }

    // Bound unauthenticated P-256 work to one valid request per BLE connection.
    // A new transcript requires a reconnect, and claiming the device still
    // requires an explicit physical confirmation after the comparison code is
    // visible on both sides.
    OwnerId requestedOwner{};
    PublicKey appPublicKey{};
    if (!hexDecode(parts[1], requestedOwner.data(), requestedOwner.size()) ||
        !hexDecode(parts[2], appPublicKey.data(), appPublicKey.size())) {
      result.response = "ERROR|invalid_pairing_request";
      return result;
    }
    pairingAttemptedOnConnection_ = true;
    clearPairing();
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
    pairingGeneration_++;
    if (pairingGeneration_ == 0) {
      pairingGeneration_++;
    }
    armedPairingGeneration_ = 0;
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
    std::array<uint8_t, 32> expectedProof{};
    if (!pairingActive_ ||
        static_cast<uint32_t>(nowMs - pairingStartedMs_) >
            PAIRING_SESSION_TIMEOUT_MS ||
        !proofFor(pendingPairing_.ownerKey, "claim|",
                  pendingPairing_.transcriptHash, expectedProof) ||
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
    if (!persistOwner()) {
      result.response = "ERROR|pairing_persistence_failed";
      // Best-effort rollback. If cleanup cannot be proven, remain locked in
      // memory so a partial record can never downgrade to the legacy key. A
      // durable revocation receipt belongs to the prior owner and must survive
      // every failed new-owner write boundary.
      if (!clearOwnerStorage(false, true)) {
        claimed_ = true;
        ownerRecordValid_ = false;
        legacyAuthenticationAllowed_ = false;
        sessionAuthenticated_ = false;
      }
      clearPairing();
      return result;
    }
    claimed_ = true;
    ownerRecordValid_ = true;
    legacyAuthenticationAllowed_ = false;
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
    pendingAuthNonce_[0] = '\0';
    pendingServerAuthNonce_[0] = '\0';
    if (!claimed_ || !ownerRecordValid_ ||
        !ownerMatches(ownerId_, parts[1]) ||
        !isHexNonce(parts[2])) {
      result.response = "DENIED|" + deviceIdHex();
      return result;
    }
    strncpy(pendingAuthNonce_, parts[2].c_str(),
            sizeof(pendingAuthNonce_) - 1);
    pendingAuthNonce_[sizeof(pendingAuthNonce_) - 1] = '\0';
    std::array<uint8_t, 16> serverNonce{};
    esp_fill_random(serverNonce.data(), serverNonce.size());
    const std::string serverNonceHex =
        hexEncode(serverNonce.data(), serverNonce.size());
    strncpy(pendingServerAuthNonce_, serverNonceHex.c_str(),
            sizeof(pendingServerAuthNonce_) - 1);
    pendingServerAuthNonce_[sizeof(pendingServerAuthNonce_) - 1] = '\0';
    const std::string message = "server2|" + deviceIdHex() + "|" + parts[1] +
                                "|" + parts[2] + "|" + serverNonceHex;
    std::array<uint8_t, 32> proof{};
    if (!stringProofFor(ownerKey_, message, proof)) {
      pendingAuthNonce_[0] = '\0';
      pendingServerAuthNonce_[0] = '\0';
      result.response = "DENIED|" + deviceIdHex();
      return result;
    }
    result.response = "SERVER2|" + deviceIdHex() + "|" + parts[2] + "|" +
                      serverNonceHex + "|" +
                      hexEncode(proof.data(), proof.size());
    return result;
  }

  if (parts[0] == "PROOF" && parts.size() == 5) {
    result.matched = true;
    std::array<uint8_t, 32> suppliedProof{};
    const std::string message = "client2|" + deviceIdHex() + "|" + parts[1] +
                                "|" + parts[2] + "|" + parts[3];
    std::array<uint8_t, 32> expectedProof{};
    if (!claimed_ || !ownerRecordValid_ || parts[2].size() != 32 ||
        parts[3].size() != 32 ||
        !ownerMatches(ownerId_, parts[1]) ||
        !constantTimeEquals(reinterpret_cast<const uint8_t *>(
                                pendingAuthNonce_),
                            reinterpret_cast<const uint8_t *>(
                                parts[2].c_str()),
                            32) ||
        pendingAuthNonce_[32] != '\0' ||
        !constantTimeEquals(reinterpret_cast<const uint8_t *>(
                                pendingServerAuthNonce_),
                            reinterpret_cast<const uint8_t *>(
                                parts[3].c_str()),
                            32) ||
        pendingServerAuthNonce_[32] != '\0' ||
        !stringProofFor(ownerKey_, message, expectedProof) ||
        !hexDecode(parts[4], suppliedProof.data(), suppliedProof.size()) ||
        !constantTimeEquals(expectedProof.data(), suppliedProof.data(),
                            expectedProof.size())) {
      result.response = "DENIED|" + deviceIdHex();
      pendingAuthNonce_[0] = '\0';
      pendingServerAuthNonce_[0] = '\0';
      return result;
    }
    const std::string sessionContext =
        deviceIdHex() + "|" + parts[2] + "|" + parts[3];
    if (!stringProofFor(ownerKey_, "session2-write|" + sessionContext,
                        sessionWriteKey_) ||
        !stringProofFor(ownerKey_, "session2-notify|" + sessionContext,
                        sessionNotifyKey_)) {
      result.response = "DENIED|" + deviceIdHex();
      pendingAuthNonce_[0] = '\0';
      pendingServerAuthNonce_[0] = '\0';
      sessionWriteKey_.fill(0);
      sessionNotifyKey_.fill(0);
      return result;
    }
    pendingAuthNonce_[0] = '\0';
    pendingServerAuthNonce_[0] = '\0';
    lastInboundSequence_.fill(0);
    nextOutboundSequence_.fill(0);
    sessionAuthenticated_ = true;
    result.event = Event::Authenticated;
    result.response = "OK2|" + deviceIdHex() + "|" + parts[2] + "|" +
                      parts[3];
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
    const std::string response = "NAME_OK|" + parts[1];
    if (!protectAuthenticatedPayload(AuthenticatedChannel::Auth, response,
                                     result.response)) {
      result.response = "ERROR|response_authentication_failed";
      result.event = Event::None;
    }
    return result;
  }

  if (parts[0] == "GET_NAME" && parts.size() == 1) {
    result.matched = true;
    if (!sessionAuthenticated_) {
      result.response = "ERROR|name_read_rejected";
      return result;
    }
    const std::string response =
        "NAME_INFO|" +
        hexEncode(reinterpret_cast<const uint8_t *>(deviceName_.data()),
                  deviceName_.size());
    if (!protectAuthenticatedPayload(AuthenticatedChannel::Auth, response,
                                     result.response)) {
      result.response = "ERROR|response_authentication_failed";
    }
    return result;
  }

  if (parts[0] == "UNPAIR" && parts.size() == 1) {
    result.matched = true;
    if (!sessionAuthenticated_) {
      result.response = "ERROR|unpair_rejected";
      return result;
    }
    const std::string id = deviceIdHex();
    const std::string ownerIdHex =
        hexEncode(ownerId_.data(), ownerId_.size());
    std::array<uint8_t, 16> receiptNonce{};
    std::array<uint8_t, 32> receiptProof{};
    esp_fill_random(receiptNonce.data(), receiptNonce.size());
    const std::string receiptNonceHex =
        hexEncode(receiptNonce.data(), receiptNonce.size());
    if (!stringProofFor(ownerKey_,
                        "revoked2|" + id + "|" + ownerIdHex + "|" +
                            receiptNonceHex,
                        receiptProof) ||
        !persistRevocationReceipt(ownerId_, receiptNonce, receiptProof)) {
      result.response = "ERROR|unpair_persistence_failed";
      return result;
    }
    std::string protectedResponse;
    if (!protectAuthenticatedPayload(AuthenticatedChannel::Auth,
                                     "UNPAIRED2|" + id + "|" +
                                         receiptNonceHex + "|" +
                                         hexEncode(receiptProof.data(),
                                                   receiptProof.size()),
                                     protectedResponse) ||
        !clearOwnerStorage(false, true)) {
      result.response = "ERROR|unpair_persistence_failed";
      return result;
    }
    result.event = Event::Unpaired;
    result.response = protectedResponse;
    return result;
  }

  return result;
}

bool DeviceOwnership::armPairingConfirmation(uint32_t pairingGeneration) {
  if (!pairingActive_ || pairingGeneration == 0 ||
      pairingGeneration != pairingGeneration_) {
    return false;
  }
  armedPairingGeneration_ = pairingGeneration;
  return true;
}

bool DeviceOwnership::confirmPairingOnDevice() {
  if (!pairingActive_ || pairingConfirmedOnDevice_ ||
      armedPairingGeneration_ != pairingGeneration_) {
    return false;
  }
  pairingConfirmedOnDevice_ = true;
  return true;
}

bool DeviceOwnership::unwrapAuthenticatedPayload(
    AuthenticatedChannel channel, const std::string &frame,
    std::string &payload) {
  constexpr size_t headerSize = 6;
  constexpr size_t tagSize = 16;
  const size_t channelIndex = static_cast<size_t>(channel);
  payload.clear();
  if (!sessionAuthenticated_ || channelIndex == 0 ||
      channelIndex >= lastInboundSequence_.size() ||
      frame.size() < headerSize + tagSize || frame[0] != 'S' ||
      frame[1] != '2') {
    return false;
  }
  const auto *bytes = reinterpret_cast<const uint8_t *>(frame.data());
  const uint32_t sequence = (static_cast<uint32_t>(bytes[2]) << 24) |
                            (static_cast<uint32_t>(bytes[3]) << 16) |
                            (static_cast<uint32_t>(bytes[4]) << 8) |
                            static_cast<uint32_t>(bytes[5]);
  if (sequence == 0 || sequence <= lastInboundSequence_[channelIndex]) {
    return false;
  }
  const size_t payloadSize = frame.size() - headerSize - tagSize;
  if (!decryptFrame(sessionWriteKey_, channel, sequence, bytes + headerSize,
                    payloadSize, bytes + headerSize + payloadSize, "write2|",
                    payload)) {
    return false;
  }
  lastInboundSequence_[channelIndex] = sequence;
  return true;
}

bool DeviceOwnership::protectAuthenticatedPayload(
    AuthenticatedChannel channel, const std::string &payload,
    std::string &frame) {
  constexpr size_t headerSize = 6;
  constexpr size_t tagSize = 16;
  const size_t channelIndex = static_cast<size_t>(channel);
  frame.clear();
  if (!sessionAuthenticated_ || channelIndex == 0 ||
      channelIndex >= nextOutboundSequence_.size() ||
      nextOutboundSequence_[channelIndex] == UINT32_MAX) {
    return false;
  }
  const uint32_t sequence = ++nextOutboundSequence_[channelIndex];
  const uint8_t sequenceBytes[4] = {
      static_cast<uint8_t>(sequence >> 24),
      static_cast<uint8_t>(sequence >> 16),
      static_cast<uint8_t>(sequence >> 8), static_cast<uint8_t>(sequence)};
  std::array<uint8_t, 16> tag{};
  std::string ciphertext;
  if (!encryptFrame(sessionNotifyKey_, channel, sequence, payload, "notify2|",
                    ciphertext, tag)) {
    return false;
  }
  frame.reserve(headerSize + payload.size() + tagSize);
  frame.append("R2", 2);
  frame.append(reinterpret_cast<const char *>(sequenceBytes),
               sizeof(sequenceBytes));
  frame.append(ciphertext);
  frame.append(reinterpret_cast<const char *>(tag.data()), tagSize);
  return true;
}

bool DeviceOwnership::clearOwner() {
  return clearOwnerStorage(false, false);
}

bool DeviceOwnership::clearOwnerStorage(bool preserveSession,
                                        bool preserveRevocationReceipt) {
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  const auto removeIfPresent = [&preferences](const char *key) {
    return !preferences.isKey(key) || preferences.remove(key);
  };
  // Remove the validity marker last. A power loss during cleanup therefore
  // leaves a locked/corrupt record instead of silently enabling the v1 key.
  const bool ownerIdRemoved = removeIfPresent(OWNER_ID_KEY);
  const bool ownerKeyRemoved = removeIfPresent(OWNER_KEY_KEY);
  const bool nameRemoved = removeIfPresent(DEVICE_NAME_KEY);
  const bool markerRemoved = removeIfPresent(OWNER_VERSION_KEY);
  const bool receiptRemoved =
      preserveRevocationReceipt || clearRevocationReceipt(preferences);
  preferences.end();
  if (!ownerIdRemoved || !ownerKeyRemoved || !nameRemoved || !markerRemoved ||
      !receiptRemoved) {
    claimed_ = true;
    ownerRecordValid_ = false;
    legacyAuthenticationAllowed_ = false;
    sessionAuthenticated_ = false;
    return false;
  }
  ownerId_.fill(0);
  ownerKey_.fill(0);
  if (!preserveSession) {
    sessionWriteKey_.fill(0);
    sessionNotifyKey_.fill(0);
    lastInboundSequence_.fill(0);
    nextOutboundSequence_.fill(0);
    sessionAuthenticated_ = false;
  }
  claimed_ = false;
  ownerRecordValid_ = false;
  legacyAuthenticationAllowed_ = false;
  deviceName_ = defaultDeviceName();
  clearPairing();
  return true;
}

bool DeviceOwnership::persistRevocationReceipt(
    const OwnerId &ownerId, const std::array<uint8_t, 16> &nonce,
    const std::array<uint8_t, 32> &proof) {
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  if (preferences.isKey(REVOCATION_VERSION_KEY) &&
      !preferences.remove(REVOCATION_VERSION_KEY)) {
    preferences.end();
    return false;
  }
  const bool stored =
      preferences.putBytes(REVOKED_OWNER_ID_KEY, ownerId.data(),
                           ownerId.size()) == ownerId.size() &&
      preferences.putBytes(REVOCATION_NONCE_KEY, nonce.data(), nonce.size()) ==
          nonce.size() &&
      preferences.putBytes(REVOCATION_PROOF_KEY, proof.data(), proof.size()) ==
          proof.size() &&
      preferences.putUChar(REVOCATION_VERSION_KEY, REVOCATION_VERSION) ==
          sizeof(uint8_t);
  preferences.end();
  if (stored) {
    revokedOwnerId_ = ownerId;
    revocationNonce_ = nonce;
    revocationProof_ = proof;
    revocationReceiptValid_ = true;
  }
  return stored;
}

bool DeviceOwnership::clearRevocationReceipt(Preferences &preferences) {
  const auto removeIfPresent = [&preferences](const char *key) {
    return !preferences.isKey(key) || preferences.remove(key);
  };
  const bool ownerRemoved = removeIfPresent(REVOKED_OWNER_ID_KEY);
  const bool nonceRemoved = removeIfPresent(REVOCATION_NONCE_KEY);
  const bool proofRemoved = removeIfPresent(REVOCATION_PROOF_KEY);
  const bool markerRemoved = removeIfPresent(REVOCATION_VERSION_KEY);
  if (ownerRemoved && nonceRemoved && proofRemoved && markerRemoved) {
    revokedOwnerId_.fill(0);
    revocationNonce_.fill(0);
    revocationProof_.fill(0);
    revocationReceiptValid_ = false;
    return true;
  }
  return false;
}

std::string DeviceOwnership::deviceIdHex() const {
  return hexEncode(deviceId_.data(), deviceId_.size());
}

std::string DeviceOwnership::advertisedName() const { return deviceName_; }

std::vector<uint8_t> DeviceOwnership::advertisementManufacturerData() const {
  const uint8_t flags = static_cast<uint8_t>(claimed_ ? 0x01 : 0x00);
  return {0xFF, 0xFF, PROTOCOL_VERSION,
          flags, deviceId_[12], deviceId_[13],
          deviceId_[14], deviceId_[15]};
}

bool DeviceOwnership::loadOrCreateDeviceId() {
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  const bool hasOwnerArtifacts = preferences.isKey(OWNER_VERSION_KEY) ||
                                 preferences.isKey(OWNER_ID_KEY) ||
                                 preferences.isKey(OWNER_KEY_KEY) ||
                                 preferences.isKey(DEVICE_NAME_KEY);
  uint8_t hardwareMac[6]{};
  std::array<uint8_t, 32> identityDigest{};
  static constexpr char identityDomain[] = "BikeComputer device ID v2";
  std::array<uint8_t, sizeof(identityDomain) - 1 + sizeof(hardwareMac)>
      identityInput{};
  memcpy(identityInput.data(), identityDomain, sizeof(identityDomain) - 1);
  if (esp_efuse_mac_get_default(hardwareMac) != ESP_OK) {
    preferences.end();
    return false;
  }
  memcpy(identityInput.data() + sizeof(identityDomain) - 1, hardwareMac,
         sizeof(hardwareMac));
  if (!sha256(identityInput.data(), identityInput.size(),
              identityDigest.data())) {
    preferences.end();
    return false;
  }

  std::array<uint8_t, 16> storedDeviceId{};
  const bool hasStoredDeviceId =
      preferences.getBytesLength(DEVICE_ID_KEY) == storedDeviceId.size() &&
      preferences.getBytes(DEVICE_ID_KEY, storedDeviceId.data(),
                           storedDeviceId.size()) == storedDeviceId.size();
  memcpy(deviceId_.data(), identityDigest.data(), deviceId_.size());
  if (hasStoredDeviceId &&
      constantTimeEquals(storedDeviceId.data(), deviceId_.data(),
                         deviceId_.size())) {
    preferences.end();
    return true;
  }

  if (hasOwnerArtifacts) {
    // Device identity is derived from immutable eFuse material. Never bind an
    // existing owner credential to a missing or same-length corrupted cache.
    deviceIdIntegrityValid_ = false;
    preferences.end();
    return true;
  }

  // An unclaimed device can safely repair a missing/corrupt cache from the
  // deterministic hardware identity.
  const bool stored = preferences.putBytes(DEVICE_ID_KEY, deviceId_.data(),
                                           deviceId_.size()) == deviceId_.size();
  preferences.end();
  return stored;
}

bool DeviceOwnership::loadOwner() {
  revokedOwnerId_.fill(0);
  revocationNonce_.fill(0);
  revocationProof_.fill(0);
  revocationReceiptValid_ = false;
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  const bool hasMarker = preferences.isKey(OWNER_VERSION_KEY);
  const bool hasOwnerId = preferences.isKey(OWNER_ID_KEY);
  const bool hasOwnerKey = preferences.isKey(OWNER_KEY_KEY);
  const bool hasName = preferences.isKey(DEVICE_NAME_KEY);
  const bool hasRevocationReceipt =
      preferences.getUChar(REVOCATION_VERSION_KEY, 0) ==
          REVOCATION_VERSION &&
      preferences.getBytesLength(REVOKED_OWNER_ID_KEY) ==
          revokedOwnerId_.size() &&
      preferences.getBytesLength(REVOCATION_NONCE_KEY) ==
          revocationNonce_.size() &&
      preferences.getBytesLength(REVOCATION_PROOF_KEY) ==
          revocationProof_.size();
  if (hasRevocationReceipt) {
    revocationReceiptValid_ =
        preferences.getBytes(REVOKED_OWNER_ID_KEY, revokedOwnerId_.data(),
                             revokedOwnerId_.size()) == revokedOwnerId_.size() &&
        preferences.getBytes(REVOCATION_NONCE_KEY, revocationNonce_.data(),
                             revocationNonce_.size()) == revocationNonce_.size() &&
        preferences.getBytes(REVOCATION_PROOF_KEY, revocationProof_.data(),
                             revocationProof_.size()) == revocationProof_.size();
  }
  if (!hasMarker && !hasOwnerId && !hasOwnerKey && !hasName) {
    preferences.end();
    claimed_ = false;
    ownerRecordValid_ = false;
    // Protocol-v2 firmware never falls back to the app-wide v1 key. iOS may
    // still support genuinely old firmware that does not expose INFO v2.
    legacyAuthenticationAllowed_ = false;
    return true;
  }

  const bool valid = hasMarker && hasOwnerId && hasOwnerKey && hasName &&
                     preferences.getUChar(OWNER_VERSION_KEY, 0) ==
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
      claimed_ = false;
    }
  }
  preferences.end();
  if (!valid || !claimed_) {
    ownerId_.fill(0);
    ownerKey_.fill(0);
    deviceName_ = defaultDeviceName();
    // A historical receipt can belong to a superseded owner and therefore
    // cannot prove that corruption in the current record is an interrupted
    // deregistration. Invalid current-owner storage always fails locked until
    // the explicit eight-second physical recovery action.
    claimed_ = true;
    ownerRecordValid_ = false;
    legacyAuthenticationAllowed_ = false;
    return true;
  }
  if (revocationReceiptValid_ &&
      constantTimeEquals(revokedOwnerId_.data(), ownerId_.data(),
                         ownerId_.size())) {
    std::array<uint8_t, 32> expectedProof{};
    const std::string receiptMessage =
        "revoked2|" + deviceIdHex() + "|" +
        hexEncode(ownerId_.data(), ownerId_.size()) + "|" +
        hexEncode(revocationNonce_.data(), revocationNonce_.size());
    if (stringProofFor(ownerKey_, receiptMessage, expectedProof) &&
        constantTimeEquals(expectedProof.data(), revocationProof_.data(),
                           expectedProof.size())) {
      // The current credential itself signed this tombstone, so power was lost
      // after durable UNPAIR intent but before owner cleanup. Complete that
      // transaction before advertising or answering INFO. A receipt from an
      // older key (even with the same installation OwnerID) remains a handoff
      // receipt and must not erase a newly committed owner.
      if (!clearOwnerStorage(false, true)) {
        // Do not expose a claimed receipt that the current iPhone can verify
        // while its owner record is still present. Taking ownership offline is
        // the only fail-closed state until storage cleanup succeeds.
        return false;
      }
      return true;
    }
  }
  ownerRecordValid_ = true;
  legacyAuthenticationAllowed_ = false;
  return true;
}

bool DeviceOwnership::persistOwner() {
  Preferences preferences;
  if (!preferences.begin(NVS_NAMESPACE, false)) {
    return false;
  }
  // A revocation receipt is the old phone's durable acknowledgement. Retain it
  // before, during, and after a new owner-record commit so the prior iPhone can
  // reconcile a lost handoff. The validity marker keeps partial new-owner
  // writes from becoming authoritative.
  if (preferences.isKey(OWNER_VERSION_KEY) &&
      !preferences.remove(OWNER_VERSION_KEY)) {
    preferences.end();
    return false;
  }
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
  armedPairingGeneration_ = 0;
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
