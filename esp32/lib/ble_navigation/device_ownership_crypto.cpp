#include "device_ownership_crypto.hpp"

#include <algorithm>
#include <array>
#include <cstring>

#include <mbedtls/hkdf.h>
#include <mbedtls/ecdh.h>
#include <mbedtls/md.h>
#include <mbedtls/version.h>
#ifdef DEVICE_OWNERSHIP_HOST_TEST
#include <random>
#else
#include <esp_random.h>
#endif

namespace device_ownership {
namespace {

#if MBEDTLS_VERSION_MAJOR >= 3
#define OWNERSHIP_KEY_FIELD(key, member) ((key).MBEDTLS_PRIVATE(member))
#else
#define OWNERSHIP_KEY_FIELD(key, member) ((key).member)
#endif

constexpr char TRANSCRIPT_PREFIX[] = "BikeComputer ownership v2";
constexpr char OWNER_KEY_INFO[] = "BikeComputer owner key v2";
constexpr char COMPARISON_PREFIX[] = "compare|";

int fillRandom(void *, unsigned char *output, size_t length) {
#ifdef DEVICE_OWNERSHIP_HOST_TEST
  static std::random_device random;
  for (size_t index = 0; index < length; index++) {
    output[index] = static_cast<unsigned char>(random());
  }
#else
  esp_fill_random(output, length);
#endif
  return 0;
}

template <size_t Size>
void append(std::array<uint8_t, Size> &buffer, size_t &offset,
            const uint8_t *value, size_t length) {
  if (value == nullptr || offset + length > buffer.size()) {
    return;
  }
  memcpy(buffer.data() + offset, value, length);
  offset += length;
}

bool makeTranscriptHash(const DeviceId &deviceId, const OwnerId &ownerId,
                        const PublicKey &appPublicKey,
                        const PublicKey &devicePublicKey,
                        TranscriptHash &out) {
  constexpr size_t transcriptSize = sizeof(TRANSCRIPT_PREFIX) - 1 +
                                    DEVICE_ID_SIZE + OWNER_ID_SIZE +
                                    (PUBLIC_KEY_SIZE * 2);
  std::array<uint8_t, transcriptSize> transcript{};
  size_t offset = 0;
  append(transcript, offset,
         reinterpret_cast<const uint8_t *>(TRANSCRIPT_PREFIX),
         sizeof(TRANSCRIPT_PREFIX) - 1);
  append(transcript, offset, deviceId.data(), deviceId.size());
  append(transcript, offset, ownerId.data(), ownerId.size());
  append(transcript, offset, appPublicKey.data(), appPublicKey.size());
  append(transcript, offset, devicePublicKey.data(), devicePublicKey.size());
  return offset == transcript.size() &&
         sha256(transcript.data(), transcript.size(), out.data());
}

} // namespace

bool constantTimeEquals(const uint8_t *left, const uint8_t *right,
                        size_t length) {
  if (left == nullptr || right == nullptr) {
    return false;
  }
  uint8_t difference = 0;
  for (size_t index = 0; index < length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool sha256(const uint8_t *data, size_t length, uint8_t out[32]) {
  if (data == nullptr || out == nullptr) {
    return false;
  }
  const mbedtls_md_info_t *info =
      mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  return info != nullptr && mbedtls_md(info, data, length, out) == 0;
}

bool hmacSha256(const uint8_t *key, size_t keyLength, const uint8_t *data,
                size_t dataLength, uint8_t out[32]) {
  if (key == nullptr || data == nullptr || out == nullptr) {
    return false;
  }
  const mbedtls_md_info_t *info =
      mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  return info != nullptr &&
         mbedtls_md_hmac(info, key, keyLength, data, dataLength, out) == 0;
}

PairingKeyAgreement::PairingKeyAgreement() { mbedtls_ecp_keypair_init(&key_); }

PairingKeyAgreement::~PairingKeyAgreement() { clear(); }

bool PairingKeyAgreement::generate() {
  clear();
  mbedtls_ecp_keypair_init(&key_);
  ready_ = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, &key_, fillRandom,
                               nullptr) == 0;
  return ready_;
}

bool PairingKeyAgreement::setPrivateKeyForTesting(
    const uint8_t privateKey[32]) {
  if (privateKey == nullptr) {
    return false;
  }
  clear();
  mbedtls_ecp_keypair_init(&key_);
  if (mbedtls_ecp_group_load(&OWNERSHIP_KEY_FIELD(key_, grp),
                             MBEDTLS_ECP_DP_SECP256R1) != 0 ||
      mbedtls_mpi_read_binary(&OWNERSHIP_KEY_FIELD(key_, d), privateKey, 32) !=
          0 ||
      mbedtls_ecp_check_privkey(&OWNERSHIP_KEY_FIELD(key_, grp),
                                &OWNERSHIP_KEY_FIELD(key_, d)) != 0 ||
      mbedtls_ecp_mul(&OWNERSHIP_KEY_FIELD(key_, grp),
                      &OWNERSHIP_KEY_FIELD(key_, Q),
                      &OWNERSHIP_KEY_FIELD(key_, d),
                      &OWNERSHIP_KEY_FIELD(key_, grp).G, fillRandom,
                      nullptr) != 0) {
    clear();
    return false;
  }
  ready_ = true;
  return true;
}

bool PairingKeyAgreement::publicKey(PublicKey &out) const {
  if (!ready_) {
    return false;
  }
  size_t written = 0;
  return mbedtls_ecp_point_write_binary(
             &OWNERSHIP_KEY_FIELD(key_, grp),
             &OWNERSHIP_KEY_FIELD(key_, Q),
             MBEDTLS_ECP_PF_UNCOMPRESSED, &written, out.data(), out.size()) ==
             0 &&
         written == out.size();
}

bool PairingKeyAgreement::derive(const PublicKey &peerPublicKey,
                                 const DeviceId &deviceId,
                                 const OwnerId &ownerId,
                                 const PublicKey &appPublicKey,
                                 const PublicKey &devicePublicKey,
                                 PairingMaterial &out) {
  if (!ready_) {
    return false;
  }

  mbedtls_ecp_point peer;
  mbedtls_mpi shared;
  mbedtls_ecp_point_init(&peer);
  mbedtls_mpi_init(&shared);
  bool ok = false;

  do {
    if (mbedtls_ecp_point_read_binary(&OWNERSHIP_KEY_FIELD(key_, grp), &peer,
                                      peerPublicKey.data(),
                                      peerPublicKey.size()) != 0 ||
        mbedtls_ecp_check_pubkey(&OWNERSHIP_KEY_FIELD(key_, grp), &peer) != 0 ||
        mbedtls_ecdh_compute_shared(&OWNERSHIP_KEY_FIELD(key_, grp), &shared,
                                    &peer, &OWNERSHIP_KEY_FIELD(key_, d),
                                    fillRandom,
                                    nullptr) != 0) {
      break;
    }

    std::array<uint8_t, 32> sharedBytes{};
    if (mbedtls_mpi_write_binary(&shared, sharedBytes.data(),
                                 sharedBytes.size()) != 0 ||
        !makeTranscriptHash(deviceId, ownerId, appPublicKey, devicePublicKey,
                            out.transcriptHash)) {
      break;
    }

    const mbedtls_md_info_t *info =
        mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (info == nullptr ||
        mbedtls_hkdf(
            info, out.transcriptHash.data(), out.transcriptHash.size(),
            sharedBytes.data(), sharedBytes.size(),
            reinterpret_cast<const uint8_t *>(OWNER_KEY_INFO),
            sizeof(OWNER_KEY_INFO) - 1, out.ownerKey.data(),
            out.ownerKey.size()) != 0) {
      break;
    }

    std::array<uint8_t,
               sizeof(COMPARISON_PREFIX) - 1 + TRANSCRIPT_HASH_SIZE>
        comparisonMessage{};
    memcpy(comparisonMessage.data(), COMPARISON_PREFIX,
           sizeof(COMPARISON_PREFIX) - 1);
    memcpy(comparisonMessage.data() + sizeof(COMPARISON_PREFIX) - 1,
           out.transcriptHash.data(), out.transcriptHash.size());
    uint8_t digest[32]{};
    if (!hmacSha256(out.ownerKey.data(), out.ownerKey.size(),
                    comparisonMessage.data(), comparisonMessage.size(),
                    digest)) {
      break;
    }
    const uint32_t value = (static_cast<uint32_t>(digest[0]) << 24) |
                           (static_cast<uint32_t>(digest[1]) << 16) |
                           (static_cast<uint32_t>(digest[2]) << 8) |
                           static_cast<uint32_t>(digest[3]);
    out.comparisonCode = value % 1000000U;
    ok = true;
  } while (false);

  mbedtls_mpi_free(&shared);
  mbedtls_ecp_point_free(&peer);
  return ok;
}

void PairingKeyAgreement::clear() {
  mbedtls_ecp_keypair_free(&key_);
  memset(&key_, 0, sizeof(key_));
  ready_ = false;
}

} // namespace device_ownership

#undef OWNERSHIP_KEY_FIELD
