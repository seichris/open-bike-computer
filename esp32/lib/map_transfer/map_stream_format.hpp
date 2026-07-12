#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace map_transfer {

constexpr size_t MAP_STREAM_FIXED_HEADER_BYTES = 32;
constexpr uint16_t MAP_STREAM_FORMAT_VERSION = 1;
constexpr uint8_t MAP_STREAM_ALGORITHM_P256_SHA256 = 1;
constexpr size_t MAP_STREAM_RAW_P256_SIGNATURE_BYTES = 64;
constexpr uint32_t MAP_STREAM_MAX_MANIFEST_BYTES = 2U * 1024U * 1024U;
constexpr uint8_t MAP_STREAM_MAX_KEY_ID_BYTES = 64;
constexpr uint32_t MAP_STREAM_MAX_FILE_COUNT = 100000;
constexpr uint64_t MAP_STREAM_MAX_PAYLOAD_BYTES = 512ULL * 1024ULL * 1024ULL;
inline constexpr char MAP_STREAM_SIGNATURE_DOMAIN[] =
    "open-bike-computer-map-manifest-v1\0";
constexpr size_t MAP_STREAM_SIGNATURE_DOMAIN_BYTES =
    sizeof(MAP_STREAM_SIGNATURE_DOMAIN) - 1;

enum class MapStreamFormatError {
  Ok,
  Truncated,
  InvalidMagic,
  UnsupportedVersion,
  UnsupportedFlags,
  InvalidReserved,
  InvalidManifestLength,
  InvalidEnvelopeLength,
  InvalidFileCount,
  InvalidPayloadLength,
  InvalidContentLength,
  InvalidAlgorithm,
  InvalidKeyId,
  InvalidSignatureLength,
  NonCanonicalSignature,
};

struct MapStreamLayout {
  uint64_t manifestOffset = 0;
  uint64_t signatureEnvelopeOffset = 0;
  uint64_t payloadOffset = 0;
  uint64_t endOffset = 0;
};

struct MapStreamHeader {
  uint16_t formatVersion = 0;
  uint16_t flags = 0;
  uint32_t manifestBytes = 0;
  uint16_t signatureEnvelopeBytes = 0;
  uint32_t fileCount = 0;
  uint64_t payloadBytes = 0;

  uint64_t totalBytes() const;
};

struct MapStreamSignatureEnvelope {
  uint8_t algorithmId = 0;
  std::string keyId;
  std::array<uint8_t, MAP_STREAM_RAW_P256_SIGNATURE_BYTES> rawSignature = {};
};

MapStreamFormatError parseMapStreamHeader(const uint8_t *data, size_t size,
                                          MapStreamHeader &header);
MapStreamFormatError parseMapStreamSignatureEnvelope(
    const uint8_t *data, size_t size, MapStreamSignatureEnvelope &envelope);
bool isCanonicalMapStreamP256Signature(const uint8_t *signature, size_t size);
MapStreamFormatError mapStreamLayout(const MapStreamHeader &header,
                                     uint64_t contentBytes,
                                     MapStreamLayout &layout);
std::string mapStreamManifestReceipt(const uint8_t *manifest, size_t size);
std::string mapStreamSignedManifestReceipt(const uint8_t *manifest,
                                           size_t manifestSize,
                                           const uint8_t *envelope,
                                           size_t envelopeSize);

} // namespace map_transfer
