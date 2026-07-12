#include "map_stream_format.hpp"

#include "map_transfer.hpp"

#include <algorithm>
#include <cstring>

namespace map_transfer {
namespace {

constexpr uint8_t kMagic[] = {'B', 'I', 'K', 'E', 'M', 'A', 'P', '1'};
constexpr uint8_t kP256Order[] = {
    0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
    0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51};
constexpr uint8_t kP256HalfOrder[] = {
    0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
    0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
    0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8};

bool isZero(const uint8_t *value, size_t size) {
  return std::all_of(value, value + size,
                     [](uint8_t byte) { return byte == 0; });
}

uint16_t readLe16(const uint8_t *data) {
  return static_cast<uint16_t>(data[0]) |
         (static_cast<uint16_t>(data[1]) << 8);
}

uint32_t readLe32(const uint8_t *data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

uint64_t readLe64(const uint8_t *data) {
  return static_cast<uint64_t>(readLe32(data)) |
         (static_cast<uint64_t>(readLe32(data + 4)) << 32);
}

bool safeKeyId(const std::string &value) {
  if (value.empty() || value.size() > MAP_STREAM_MAX_KEY_ID_BYTES)
    return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char character) {
    return (character >= 'a' && character <= 'z') ||
           (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9') || character == '.' ||
           character == '_' || character == '-';
  });
}

} // namespace

bool isCanonicalMapStreamP256Signature(const uint8_t *signature, size_t size) {
  constexpr size_t componentBytes = MAP_STREAM_RAW_P256_SIGNATURE_BYTES / 2;
  if (signature == nullptr || size != MAP_STREAM_RAW_P256_SIGNATURE_BYTES)
    return false;
  const uint8_t *r = signature;
  const uint8_t *s = signature + componentBytes;
  return !isZero(r, componentBytes) &&
         std::memcmp(r, kP256Order, componentBytes) < 0 &&
         !isZero(s, componentBytes) &&
         std::memcmp(s, kP256HalfOrder, componentBytes) <= 0;
}

uint64_t MapStreamHeader::totalBytes() const {
  return MAP_STREAM_FIXED_HEADER_BYTES + static_cast<uint64_t>(manifestBytes) +
         static_cast<uint64_t>(signatureEnvelopeBytes) + payloadBytes;
}

MapStreamFormatError parseMapStreamHeader(const uint8_t *data, size_t size,
                                          MapStreamHeader &header) {
  if (data == nullptr || size != MAP_STREAM_FIXED_HEADER_BYTES)
    return MapStreamFormatError::Truncated;
  if (std::memcmp(data, kMagic, sizeof(kMagic)) != 0)
    return MapStreamFormatError::InvalidMagic;
  header.formatVersion = readLe16(data + 8);
  header.flags = readLe16(data + 10);
  header.manifestBytes = readLe32(data + 12);
  header.signatureEnvelopeBytes = readLe16(data + 16);
  const uint16_t reserved = readLe16(data + 18);
  header.fileCount = readLe32(data + 20);
  header.payloadBytes = readLe64(data + 24);
  if (header.formatVersion != MAP_STREAM_FORMAT_VERSION)
    return MapStreamFormatError::UnsupportedVersion;
  if (header.flags != 0)
    return MapStreamFormatError::UnsupportedFlags;
  if (reserved != 0)
    return MapStreamFormatError::InvalidReserved;
  if (header.manifestBytes == 0 ||
      header.manifestBytes > MAP_STREAM_MAX_MANIFEST_BYTES)
    return MapStreamFormatError::InvalidManifestLength;
  const size_t maximumEnvelope = 4 + MAP_STREAM_MAX_KEY_ID_BYTES +
                                 MAP_STREAM_RAW_P256_SIGNATURE_BYTES;
  if (header.signatureEnvelopeBytes <= 4 ||
      header.signatureEnvelopeBytes > maximumEnvelope)
    return MapStreamFormatError::InvalidEnvelopeLength;
  if (header.fileCount == 0 || header.fileCount > MAP_STREAM_MAX_FILE_COUNT)
    return MapStreamFormatError::InvalidFileCount;
  if (header.payloadBytes == 0 ||
      header.payloadBytes > MAP_STREAM_MAX_PAYLOAD_BYTES)
    return MapStreamFormatError::InvalidPayloadLength;
  return MapStreamFormatError::Ok;
}

MapStreamFormatError parseMapStreamSignatureEnvelope(
    const uint8_t *data, size_t size, MapStreamSignatureEnvelope &envelope) {
  if (data == nullptr || size < 4)
    return MapStreamFormatError::Truncated;
  envelope.algorithmId = data[0];
  const uint8_t keyIdBytes = data[1];
  const uint16_t signatureBytes = readLe16(data + 2);
  if (envelope.algorithmId != MAP_STREAM_ALGORITHM_P256_SHA256)
    return MapStreamFormatError::InvalidAlgorithm;
  if (signatureBytes != MAP_STREAM_RAW_P256_SIGNATURE_BYTES)
    return MapStreamFormatError::InvalidSignatureLength;
  if (size != 4 + static_cast<size_t>(keyIdBytes) + signatureBytes)
    return MapStreamFormatError::InvalidEnvelopeLength;
  const uint8_t *rawSignature = data + 4 + keyIdBytes;
  if (!isCanonicalMapStreamP256Signature(rawSignature, signatureBytes))
    return MapStreamFormatError::NonCanonicalSignature;
  envelope.keyId.assign(reinterpret_cast<const char *>(data + 4), keyIdBytes);
  if (!safeKeyId(envelope.keyId))
    return MapStreamFormatError::InvalidKeyId;
  std::copy(rawSignature, data + size, envelope.rawSignature.begin());
  return MapStreamFormatError::Ok;
}

MapStreamFormatError mapStreamLayout(const MapStreamHeader &header,
                                     uint64_t contentBytes,
                                     MapStreamLayout &layout) {
  if (contentBytes != header.totalBytes())
    return MapStreamFormatError::InvalidContentLength;
  layout.manifestOffset = MAP_STREAM_FIXED_HEADER_BYTES;
  layout.signatureEnvelopeOffset =
      layout.manifestOffset + header.manifestBytes;
  layout.payloadOffset =
      layout.signatureEnvelopeOffset + header.signatureEnvelopeBytes;
  layout.endOffset = header.totalBytes();
  return MapStreamFormatError::Ok;
}

std::string mapStreamManifestReceipt(const uint8_t *manifest, size_t size) {
  return sha256Hex(manifest, size);
}

std::string mapStreamSignedManifestReceipt(const uint8_t *manifest,
                                           size_t manifestSize,
                                           const uint8_t *envelope,
                                           size_t envelopeSize) {
  Sha256Hasher hasher;
  hasher.update(reinterpret_cast<const uint8_t *>(MAP_STREAM_SIGNATURE_DOMAIN),
                MAP_STREAM_SIGNATURE_DOMAIN_BYTES);
  hasher.update(manifest, manifestSize);
  hasher.update(envelope, envelopeSize);
  return hasher.finalHex();
}

} // namespace map_transfer
