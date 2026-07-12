#include "map_stream_crypto.hpp"

#include <mbedtls/bignum.h>
#include <mbedtls/ecp.h>
#include <mbedtls/ecdsa.h>
#include <mbedtls/sha256.h>
#include <mbedtls/version.h>

namespace {

int checkedSha256Starts(mbedtls_sha256_context *context) {
#if MBEDTLS_VERSION_NUMBER < 0x03000000
  return mbedtls_sha256_starts_ret(context, 0);
#else
  return mbedtls_sha256_starts(context, 0);
#endif
}

int checkedSha256Update(mbedtls_sha256_context *context, const uint8_t *data,
                        size_t size) {
#if MBEDTLS_VERSION_NUMBER < 0x03000000
  return mbedtls_sha256_update_ret(context, data, size);
#else
  return mbedtls_sha256_update(context, data, size);
#endif
}

int checkedSha256Finish(mbedtls_sha256_context *context, uint8_t digest[32]) {
#if MBEDTLS_VERSION_NUMBER < 0x03000000
  return mbedtls_sha256_finish_ret(context, digest);
#else
  return mbedtls_sha256_finish(context, digest);
#endif
}

} // namespace

namespace map_transfer {

bool verifyMapStreamP256Signature(
    const uint8_t *manifest, size_t manifestSize,
    const MapStreamSignatureEnvelope &envelope, const uint8_t *publicKeyX963,
    size_t publicKeySize) {
  if ((manifest == nullptr && manifestSize != 0) || publicKeyX963 == nullptr ||
      publicKeySize != 65 ||
      envelope.algorithmId != MAP_STREAM_ALGORITHM_P256_SHA256 ||
      !isCanonicalMapStreamP256Signature(envelope.rawSignature.data(),
                                         envelope.rawSignature.size()))
    return false;

  uint8_t digest[32] = {};
  mbedtls_sha256_context sha;
  mbedtls_sha256_init(&sha);
  int result = checkedSha256Starts(&sha);
  if (result == 0) {
    result = checkedSha256Update(
        &sha, reinterpret_cast<const uint8_t *>(MAP_STREAM_SIGNATURE_DOMAIN),
        MAP_STREAM_SIGNATURE_DOMAIN_BYTES);
  }
  if (result == 0)
    result = checkedSha256Update(&sha, manifest, manifestSize);
  if (result == 0)
    result = checkedSha256Finish(&sha, digest);
  mbedtls_sha256_free(&sha);
  if (result != 0)
    return false;

  mbedtls_ecp_group group;
  mbedtls_ecp_point publicKey;
  mbedtls_mpi r;
  mbedtls_mpi s;
  mbedtls_ecp_group_init(&group);
  mbedtls_ecp_point_init(&publicKey);
  mbedtls_mpi_init(&r);
  mbedtls_mpi_init(&s);

  result = mbedtls_ecp_group_load(&group, MBEDTLS_ECP_DP_SECP256R1);
  if (result == 0) {
    result = mbedtls_ecp_point_read_binary(&group, &publicKey, publicKeyX963,
                                           publicKeySize);
  }
  if (result == 0)
    result = mbedtls_ecp_check_pubkey(&group, &publicKey);
  if (result == 0) {
    result = mbedtls_mpi_read_binary(
        &r, envelope.rawSignature.data(),
        MAP_STREAM_RAW_P256_SIGNATURE_BYTES / 2);
  }
  if (result == 0) {
    result = mbedtls_mpi_read_binary(
        &s,
        envelope.rawSignature.data() + MAP_STREAM_RAW_P256_SIGNATURE_BYTES / 2,
        MAP_STREAM_RAW_P256_SIGNATURE_BYTES / 2);
  }
  if (result == 0)
    result = mbedtls_ecdsa_verify(&group, digest, sizeof(digest), &publicKey, &r, &s);

  mbedtls_mpi_free(&s);
  mbedtls_mpi_free(&r);
  mbedtls_ecp_point_free(&publicKey);
  mbedtls_ecp_group_free(&group);
  return result == 0;
}

} // namespace map_transfer
