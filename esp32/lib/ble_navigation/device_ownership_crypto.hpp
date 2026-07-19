#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include <mbedtls/ecp.h>

namespace device_ownership {

constexpr size_t DEVICE_ID_SIZE = 16;
constexpr size_t OWNER_ID_SIZE = 16;
constexpr size_t OWNER_KEY_SIZE = 32;
constexpr size_t PUBLIC_KEY_SIZE = 65;
constexpr size_t TRANSCRIPT_HASH_SIZE = 32;

using DeviceId = std::array<uint8_t, DEVICE_ID_SIZE>;
using OwnerId = std::array<uint8_t, OWNER_ID_SIZE>;
using OwnerKey = std::array<uint8_t, OWNER_KEY_SIZE>;
using PublicKey = std::array<uint8_t, PUBLIC_KEY_SIZE>;
using TranscriptHash = std::array<uint8_t, TRANSCRIPT_HASH_SIZE>;

struct PairingMaterial {
  OwnerKey ownerKey{};
  TranscriptHash transcriptHash{};
  uint32_t comparisonCode = 0;
};

bool constantTimeEquals(const uint8_t *left, const uint8_t *right,
                        size_t length);
bool sha256(const uint8_t *data, size_t length, uint8_t out[32]);
bool hmacSha256(const uint8_t *key, size_t keyLength, const uint8_t *data,
                size_t dataLength, uint8_t out[32]);

class PairingKeyAgreement {
public:
  PairingKeyAgreement();
  ~PairingKeyAgreement();

  PairingKeyAgreement(const PairingKeyAgreement &) = delete;
  PairingKeyAgreement &operator=(const PairingKeyAgreement &) = delete;

  bool generate();
  bool setPrivateKeyForTesting(const uint8_t privateKey[32]);
  bool publicKey(PublicKey &out) const;
  bool derive(const PublicKey &peerPublicKey, const DeviceId &deviceId,
              const OwnerId &ownerId, const PublicKey &appPublicKey,
              const PublicKey &devicePublicKey, PairingMaterial &out);
  void clear();

private:
  mbedtls_ecp_keypair key_;
  bool ready_ = false;
};

} // namespace device_ownership
