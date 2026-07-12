#pragma once

#include "map_stream_format.hpp"
#include "map_stream_sha.hpp"
#include "map_stream_trust.hpp"
#include "map_transfer.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace map_transfer {

constexpr size_t MAP_STREAM_MAX_MAP_ID_BYTES = 64;
constexpr size_t MAP_STREAM_MAX_PATH_COMPONENT_BYTES = 64;
constexpr size_t MAP_STREAM_MAX_RELATIVE_PATH_BYTES = 202;

enum class MapStreamParserError {
  None,
  InvalidInput,
  HeaderInvalid,
  ContentLengthMismatch,
  ManifestInvalid,
  FirmwareIncompatible,
  EnvelopeInvalid,
  UnknownSigningKey,
  SignatureInvalid,
  ResourceUnavailable,
  HashUnavailable,
  FileHashMismatch,
  ConsumerRejected,
  Truncated,
  TrailingData,
};

const char *mapStreamParserErrorCode(MapStreamParserError error);

struct MapStreamFileDescriptor {
  uint64_t bytes = 0;
  std::array<uint8_t, 32> sha256 = {};
  uint32_t pathOffset = 0;
  uint16_t pathBytes = 0;
  uint32_t tileOffset = 0;
  uint16_t tileBytes = 0;
  uint32_t filenameOffset = 0;
  uint16_t filenameBytes = 0;
};

// Exact-capacity checked table. Production allocations are forced into PSRAM;
// host allocations use malloc. It never grows implicitly, so allocation
// failure is observable instead of invoking the no-exceptions new handler.
class MapStreamFileTable {
public:
  MapStreamFileTable() = default;
  ~MapStreamFileTable();
  MapStreamFileTable(const MapStreamFileTable &) = delete;
  MapStreamFileTable &operator=(const MapStreamFileTable &) = delete;
  MapStreamFileTable(MapStreamFileTable &&other) noexcept;
  MapStreamFileTable &operator=(MapStreamFileTable &&other) noexcept;

  bool allocate(size_t capacity);
  bool pushBack(const MapStreamFileDescriptor &file);
  void clear();
  size_t size() const;
  size_t capacity() const;
  MapStreamFileDescriptor &operator[](size_t index);
  const MapStreamFileDescriptor &operator[](size_t index) const;

private:
  MapStreamFileDescriptor *data_ = nullptr;
  size_t size_ = 0;
  size_t capacity_ = 0;
};

struct ParsedMapStreamManifest {
  MapManifest metadata;
  MapStreamFileTable files;
  uint64_t payloadBytes = 0;
};

struct VerifiedMapStreamManifest {
  ParsedMapStreamManifest manifest;
  std::string manifestReceipt;
  std::string signedManifestReceipt;
  std::string signatureKeyId;
  uint64_t payloadBytes = 0;
};

struct MapStreamFileView {
  std::string_view path;
  std::string_view tileDirectory;
  std::string_view filename;
  uint64_t bytes = 0;
  const std::array<uint8_t, 32> *sha256 = nullptr;
};

enum class MapStreamFileAction {
  VerifyAndConsume,
  ConsumeCheckpointed,
  Reject,
};

class MapStreamConsumer {
public:
  virtual ~MapStreamConsumer() = default;
  virtual bool onManifest(const VerifiedMapStreamManifest &manifest,
                          std::string_view canonicalManifest) = 0;
  virtual MapStreamFileAction onFileBegin(const MapStreamFileView &file,
                                          size_t index) = 0;
  virtual bool onFileData(const MapStreamFileView &file, const uint8_t *data,
                          size_t size) = 0;
  virtual bool onFileEnd(const MapStreamFileView &file, size_t index) = 0;
  virtual bool onComplete(const VerifiedMapStreamManifest &manifest) = 0;
  virtual void onAbort(MapStreamParserError error) = 0;
};

bool parseMapStreamManifest(std::string_view manifestText,
                            const MapStreamHeader &header,
                            ParsedMapStreamManifest &manifest);
bool mapStreamFileView(const ParsedMapStreamManifest &manifest,
                       std::string_view canonicalManifest, size_t index,
                       MapStreamFileView &file);
bool mapStreamFirmwareCompatible(const std::string &currentVersion,
                                 const std::string &minimumVersion);

struct MapStreamParserOptions {
  uint64_t expectedContentBytes = std::numeric_limits<uint64_t>::max();
  // Required. An empty or malformed version fails closed once the signed
  // manifest has been authenticated.
  std::string currentFirmwareVersion;
  // Deterministic policy ceiling for the retained manifest plus compact file
  // table. Production still requires each checked PSRAM allocation to succeed.
  size_t maximumWorkingBytes = std::numeric_limits<size_t>::max();
};

class MapStreamIncrementalParser {
public:
  MapStreamIncrementalParser(
      const MapStreamTrustStore &trustStore, MapStreamSha256 &fileHasher,
      MapStreamConsumer &consumer,
      MapStreamParserOptions options);
  ~MapStreamIncrementalParser();
  MapStreamIncrementalParser(const MapStreamIncrementalParser &) = delete;
  MapStreamIncrementalParser &
  operator=(const MapStreamIncrementalParser &) = delete;

  bool feed(const uint8_t *data, size_t size);
  bool finish();
  bool complete() const;
  bool failed() const;
  MapStreamParserError error() const;
  const char *errorCode() const;
  uint64_t receivedBytes() const;
  const VerifiedMapStreamManifest *verifiedManifest() const;

private:
  enum class Stage {
    Header,
    Manifest,
    Envelope,
    Payload,
    AwaitingFinish,
    Complete,
    Failed
  };

  const MapStreamTrustStore &trustStore_;
  MapStreamSha256 &fileHasher_;
  MapStreamConsumer &consumer_;
  MapStreamParserOptions options_;
  uint64_t receivedBytes_ = 0;
  Stage stage_ = Stage::Header;
  MapStreamParserError error_ = MapStreamParserError::None;
  std::array<uint8_t, MAP_STREAM_FIXED_HEADER_BYTES> headerBuffer_ = {};
  size_t headerBuffered_ = 0;
  MapStreamHeader header_;
  uint8_t *manifestBuffer_ = nullptr;
  size_t manifestBuffered_ = 0;
  std::array<uint8_t, 4 + MAP_STREAM_MAX_KEY_ID_BYTES +
                          MAP_STREAM_RAW_P256_SIGNATURE_BYTES>
      envelopeBuffer_ = {};
  size_t envelopeBuffered_ = 0;
  MapStreamSignatureEnvelope envelope_;
  VerifiedMapStreamManifest verified_;
  size_t fileIndex_ = 0;
  uint64_t fileBytes_ = 0;
  bool fileStarted_ = false;
  bool verifyCurrentFile_ = true;
  bool verifiedReady_ = false;

  bool fail(MapStreamParserError error);
  bool acceptHeaderByte(const uint8_t *&data, size_t &size);
  bool acceptManifestBytes(const uint8_t *&data, size_t &size);
  bool acceptEnvelopeBytes(const uint8_t *&data, size_t &size);
  bool preparePayload();
  bool acceptPayloadBytes(const uint8_t *&data, size_t &size);
  bool beginCurrentFile();
  bool finishCurrentFile();
  MapStreamFileView currentFileView() const;
};

} // namespace map_transfer
