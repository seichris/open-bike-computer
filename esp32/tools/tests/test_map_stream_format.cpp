#include "../../lib/map_transfer/map_stream_format.hpp"
#include "../../lib/map_transfer/map_stream_crypto.hpp"
#include "../../lib/map_transfer/map_stream_parser.hpp"
#include "../../lib/map_transfer/map_stream_sha.hpp"
#include "../../lib/map_transfer/map_stream_trust.hpp"
#include "../../lib/maps/src/mapBlockFormat.hpp"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <vector>

using map_transfer::MAP_STREAM_FIXED_HEADER_BYTES;
using map_transfer::MapStreamFormatError;
using map_transfer::MapStreamHeader;
using map_transfer::MapStreamLayout;
using map_transfer::MapStreamSignatureEnvelope;
using map_transfer::MapStreamConsumer;
using map_transfer::MapStreamFileDescriptor;
using map_transfer::MapStreamFileAction;
using map_transfer::MapStreamFileView;
using map_transfer::MapStreamIncrementalParser;
using map_transfer::MapStreamParserError;
using map_transfer::MapStreamTrustStore;
using map_transfer::MbedTlsMapStreamSha256;
using map_transfer::ParsedMapStreamManifest;
using map_transfer::VerifiedMapStreamManifest;
using map_transfer::mapStreamManifestReceipt;
using map_transfer::mapStreamFirmwareCompatible;
using map_transfer::mapStreamSignedManifestReceipt;
using map_transfer::mapStreamLayout;
using map_transfer::parseMapStreamHeader;
using map_transfer::parseMapStreamSignatureEnvelope;
using map_transfer::verifyMapStreamP256Signature;
using map_transfer::parseMapStreamManifest;

class RecordingConsumer final : public MapStreamConsumer {
public:
  bool rejectManifest = false;
  bool rejectData = false;
  bool rejectFileEnd = false;
  bool rejectComplete = false;
  bool consumeCheckpointed = false;
  size_t manifestCalls = 0;
  size_t beginCalls = 0;
  size_t endCalls = 0;
  size_t completeCalls = 0;
  size_t abortCalls = 0;
  std::vector<uint8_t> payload;

  bool onManifest(const VerifiedMapStreamManifest &manifest,
                  std::string_view canonicalManifest) override {
    manifestCalls++;
    mapId = manifest.manifest.metadata.mapId;
    manifestReceipt = manifest.manifestReceipt;
    signedManifestReceipt = manifest.signedManifestReceipt;
    signatureKeyId = manifest.signatureKeyId;
    payloadBytes = manifest.payloadBytes;
    fileCount = manifest.manifest.files.size();
    manifestBytes = canonicalManifest.size();
    return !rejectManifest;
  }

  MapStreamFileAction onFileBegin(const MapStreamFileView &file,
                                  size_t) override {
    beginCalls++;
    lastPath = std::string(file.path);
    lastTileDirectory = std::string(file.tileDirectory);
    lastFilename = std::string(file.filename);
    return consumeCheckpointed ? MapStreamFileAction::ConsumeCheckpointed
                               : MapStreamFileAction::VerifyAndConsume;
  }

  bool onFileData(const MapStreamFileView &, const uint8_t *data,
                  size_t size) override {
    payload.insert(payload.end(), data, data + size);
    return !rejectData;
  }

  bool onFileEnd(const MapStreamFileView &, size_t) override {
    endCalls++;
    return !rejectFileEnd;
  }

  bool onComplete(const VerifiedMapStreamManifest &) override {
    completeCalls++;
    return !rejectComplete;
  }

  void onAbort(MapStreamParserError error) override {
    abortCalls++;
    abortError = error;
  }

  std::string mapId;
  std::string manifestReceipt;
  std::string signedManifestReceipt;
  std::string signatureKeyId;
  std::string lastPath;
  std::string lastTileDirectory;
  std::string lastFilename;
  uint64_t payloadBytes = 0;
  size_t fileCount = 0;
  size_t manifestBytes = 0;
  MapStreamParserError abortError = MapStreamParserError::None;
};

class ResetFailingHasher final : public map_transfer::MapStreamSha256 {
public:
  bool reset() override { return false; }
  bool update(const uint8_t *, size_t) override { return false; }
  bool finish(std::array<uint8_t, 32> &) override { return false; }
};

class UpdateFailingHasher final : public map_transfer::MapStreamSha256 {
public:
  bool reset() override { return true; }
  bool update(const uint8_t *, size_t) override { return false; }
  bool finish(std::array<uint8_t, 32> &) override { return false; }
};

class FinishFailingHasher final : public map_transfer::MapStreamSha256 {
public:
  bool reset() override { return true; }
  bool update(const uint8_t *, size_t) override { return true; }
  bool finish(std::array<uint8_t, 32> &) override { return false; }
};

static MapStreamTrustStore trustStore(const std::vector<uint8_t> &publicKey) {
  MapStreamTrustStore trust;
  assert(trust.add("map-test-2026-01", publicKey.data(), publicKey.size()));
  return trust;
}

static std::vector<uint8_t> decodeHex(const std::string &hex) {
  assert(hex.size() % 2 == 0);
  std::vector<uint8_t> bytes;
  bytes.reserve(hex.size() / 2);
  for (size_t index = 0; index < hex.size(); index += 2) {
    bytes.push_back(static_cast<uint8_t>(
        std::stoul(hex.substr(index, 2), nullptr, 16)));
  }
  return bytes;
}

static void writeLe16(std::vector<uint8_t> &bytes, size_t offset,
                      uint16_t value) {
  bytes[offset] = static_cast<uint8_t>(value);
  bytes[offset + 1] = static_cast<uint8_t>(value >> 8);
}

static void writeLe32(std::vector<uint8_t> &bytes, size_t offset,
                      uint32_t value) {
  for (size_t index = 0; index < 4; index++)
    bytes[offset + index] = static_cast<uint8_t>(value >> (index * 8));
}

static void writeLe64(std::vector<uint8_t> &bytes, size_t offset,
                      uint64_t value) {
  for (size_t index = 0; index < 8; index++)
    bytes[offset + index] = static_cast<uint8_t>(value >> (index * 8));
}

static std::map<std::string, std::string> readFixture() {
  std::ifstream input("../backend/tests/fixtures/map_stream_v1_golden.txt");
  assert(input.good());
  std::map<std::string, std::string> values;
  std::string line;
  while (std::getline(input, line)) {
    const size_t separator = line.find('=');
    assert(separator != std::string::npos);
    values[line.substr(0, separator)] = line.substr(separator + 1);
  }
  return values;
}

int main() {
  const auto fixture = readFixture();
  const auto headerBytes = decodeHex(fixture.at("header_hex"));
  const auto manifest = decodeHex(fixture.at("manifest_hex"));
  const auto envelopeBytes = decodeHex(fixture.at("signature_envelope_hex"));
  const auto stream = decodeHex(fixture.at("stream_hex"));
  const auto expectedPayload = decodeHex(fixture.at("payload_hex"));
  const auto publicKey = decodeHex(fixture.at("public_key_x963_hex"));

  MapStreamHeader header;
  assert(parseMapStreamHeader(headerBytes.data(), headerBytes.size(), header) ==
         MapStreamFormatError::Ok);
  assert(header.formatVersion == 1);
  assert(header.fileCount == 1);
  assert(header.payloadBytes == 8);
  assert(header.totalBytes() == stream.size());
  assert(headerBytes.size() == MAP_STREAM_FIXED_HEADER_BYTES);
  MapStreamLayout layout;
  assert(mapStreamLayout(header, stream.size(), layout) ==
         MapStreamFormatError::Ok);
  assert(std::equal(stream.begin(), stream.begin() + headerBytes.size(),
                    headerBytes.begin()));
  assert(std::equal(stream.begin() + layout.manifestOffset,
                    stream.begin() + layout.signatureEnvelopeOffset,
                    manifest.begin()));
  assert(std::equal(stream.begin() + layout.signatureEnvelopeOffset,
                    stream.begin() + layout.payloadOffset,
                    envelopeBytes.begin()));
  assert(std::equal(stream.begin() + layout.payloadOffset, stream.end(),
                    expectedPayload.begin()));
  assert(std::string(manifest.begin(), manifest.end()).find("\"preview\"") !=
         std::string::npos);
  assert(mapStreamLayout(header, stream.size() - 1, layout) ==
         MapStreamFormatError::InvalidContentLength);
  assert(mapStreamLayout(header, stream.size() + 1, layout) ==
         MapStreamFormatError::InvalidContentLength);

  MapStreamSignatureEnvelope envelope;
  assert(parseMapStreamSignatureEnvelope(envelopeBytes.data(),
                                        envelopeBytes.size(), envelope) ==
         MapStreamFormatError::Ok);
  assert(envelope.keyId == "map-test-2026-01");
  assert(verifyMapStreamP256Signature(manifest.data(), manifest.size(),
                                     envelope, publicKey.data(),
                                     publicKey.size()));
  assert(mapStreamManifestReceipt(manifest.data(), manifest.size()) ==
         fixture.at("manifest_receipt"));
  assert(mapStreamSignedManifestReceipt(
             manifest.data(), manifest.size(), envelopeBytes.data(),
             envelopeBytes.size()) == fixture.at("signed_manifest_receipt"));

  auto tamperedManifest = manifest;
  tamperedManifest.front() ^= 1;
  assert(!verifyMapStreamP256Signature(
      tamperedManifest.data(), tamperedManifest.size(), envelope,
      publicKey.data(), publicKey.size()));
  auto tamperedEnvelope = envelope;
  tamperedEnvelope.rawSignature.back() ^= 1;
  assert(!verifyMapStreamP256Signature(
      manifest.data(), manifest.size(), tamperedEnvelope, publicKey.data(),
      publicKey.size()));

  auto invalidHeader = headerBytes;
  invalidHeader[8] = 2;
  assert(parseMapStreamHeader(invalidHeader.data(), invalidHeader.size(),
                             header) ==
         MapStreamFormatError::UnsupportedVersion);
  assert(parseMapStreamHeader(nullptr, MAP_STREAM_FIXED_HEADER_BYTES, header) ==
         MapStreamFormatError::Truncated);
  assert(parseMapStreamHeader(headerBytes.data(), headerBytes.size() - 1,
                              header) == MapStreamFormatError::Truncated);
  auto badMagic = headerBytes;
  badMagic[0] ^= 1;
  assert(parseMapStreamHeader(badMagic.data(), badMagic.size(), header) ==
         MapStreamFormatError::InvalidMagic);
  auto badFlags = headerBytes;
  writeLe16(badFlags, 10, 1);
  assert(parseMapStreamHeader(badFlags.data(), badFlags.size(), header) ==
         MapStreamFormatError::UnsupportedFlags);
  auto badReserved = headerBytes;
  writeLe16(badReserved, 18, 1);
  assert(parseMapStreamHeader(badReserved.data(), badReserved.size(), header) ==
         MapStreamFormatError::InvalidReserved);
  for (uint32_t manifestLength : {0U, 2U * 1024U * 1024U + 1U}) {
    auto bad = headerBytes;
    writeLe32(bad, 12, manifestLength);
    assert(parseMapStreamHeader(bad.data(), bad.size(), header) ==
           MapStreamFormatError::InvalidManifestLength);
  }
  for (uint16_t envelopeLength : {static_cast<uint16_t>(4),
                                  static_cast<uint16_t>(133)}) {
    auto bad = headerBytes;
    writeLe16(bad, 16, envelopeLength);
    assert(parseMapStreamHeader(bad.data(), bad.size(), header) ==
           MapStreamFormatError::InvalidEnvelopeLength);
  }
  for (uint32_t fileCount : {0U, 100001U}) {
    auto bad = headerBytes;
    writeLe32(bad, 20, fileCount);
    assert(parseMapStreamHeader(bad.data(), bad.size(), header) ==
           MapStreamFormatError::InvalidFileCount);
  }
  for (uint64_t payloadLength : {0ULL, 512ULL * 1024ULL * 1024ULL + 1ULL}) {
    auto bad = headerBytes;
    writeLe64(bad, 24, payloadLength);
    assert(parseMapStreamHeader(bad.data(), bad.size(), header) ==
           MapStreamFormatError::InvalidPayloadLength);
  }
  auto invalidEnvelope = envelopeBytes;
  invalidEnvelope[2] = 63;
  assert(parseMapStreamSignatureEnvelope(
             invalidEnvelope.data(), invalidEnvelope.size(), envelope) ==
         MapStreamFormatError::InvalidSignatureLength);
  assert(parseMapStreamSignatureEnvelope(nullptr, envelopeBytes.size(),
                                         envelope) ==
         MapStreamFormatError::Truncated);
  auto invalidAlgorithm = envelopeBytes;
  invalidAlgorithm[0] = 2;
  assert(parseMapStreamSignatureEnvelope(invalidAlgorithm.data(),
                                         invalidAlgorithm.size(), envelope) ==
         MapStreamFormatError::InvalidAlgorithm);
  auto invalidKeyId = envelopeBytes;
  invalidKeyId[4] = '/';
  assert(parseMapStreamSignatureEnvelope(invalidKeyId.data(),
                                         invalidKeyId.size(), envelope) ==
         MapStreamFormatError::InvalidKeyId);
  auto zeroSignature = envelopeBytes;
  std::fill(zeroSignature.end() - 64, zeroSignature.end(), 0);
  assert(parseMapStreamSignatureEnvelope(zeroSignature.data(),
                                         zeroSignature.size(), envelope) ==
         MapStreamFormatError::NonCanonicalSignature);

  auto highSEnvelope = envelopeBytes;
  const auto highS = decodeHex(
      "84bbcdefdaa6426471c25ac037769c84cebf6fdf76c1ebd87fe26f14e3b42870");
  std::copy(highS.begin(), highS.end(), highSEnvelope.end() - highS.size());
  assert(parseMapStreamSignatureEnvelope(highSEnvelope.data(),
                                        highSEnvelope.size(), envelope) ==
         MapStreamFormatError::NonCanonicalSignature);
  auto manuallyConstructedHighS = envelope;
  std::copy(highS.begin(), highS.end(),
            manuallyConstructedHighS.rawSignature.end() - highS.size());
  assert(!verifyMapStreamP256Signature(
      manifest.data(), manifest.size(), manuallyConstructedHighS,
      publicKey.data(), publicKey.size()));

  {
    auto trust = trustStore(publicKey);
    assert(!trust.add("map-test-2026-01", publicKey.data(), publicKey.size()));
    const auto rotationPublicKey =
        decodeHex(fixture.at("rotation_public_key_x963_hex"));
    const auto rotationSignature =
        decodeHex(fixture.at("rotation_signature_hex"));
    assert(trust.add("map-test-2026-02", rotationPublicKey.data(),
                     rotationPublicKey.size()));
    assert(trust.size() == 2);
    assert(trust.find("map-test-2026-01") != nullptr);
    assert(trust.find("unknown") == nullptr);
    MapStreamSignatureEnvelope rotationEnvelope;
    rotationEnvelope.algorithmId = map_transfer::MAP_STREAM_ALGORITHM_P256_SHA256;
    rotationEnvelope.keyId = "map-test-2026-02";
    std::copy(rotationSignature.begin(), rotationSignature.end(),
              rotationEnvelope.rawSignature.begin());
    assert(trust.verify(manifest.data(), manifest.size(), rotationEnvelope));
    rotationEnvelope.keyId = "map-test-2026-01";
    assert(!trust.verify(manifest.data(), manifest.size(), rotationEnvelope));
    MapStreamTrustStore revokedTrust = trustStore(publicKey);
    rotationEnvelope.keyId = "map-test-2026-02";
    assert(!revokedTrust.verify(manifest.data(), manifest.size(),
                                rotationEnvelope));
    std::vector<uint8_t> invalidPublicKey(65, 0);
    invalidPublicKey[0] = 0x04;
    assert(!trust.add("invalid-point", invalidPublicKey.data(),
                      invalidPublicKey.size()));
  }

  for (size_t chunkSize = 1; chunkSize <= 31; chunkSize++) {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    for (size_t offset = 0; offset < stream.size(); offset += chunkSize) {
      const size_t count = std::min(chunkSize, stream.size() - offset);
      assert(parser.feed(stream.data() + offset, count));
    }
    assert(parser.finish());
    assert(parser.complete());
    assert(parser.receivedBytes() == stream.size());
    assert(consumer.manifestCalls == 1);
    assert(consumer.beginCalls == 1);
    assert(consumer.endCalls == 1);
    assert(consumer.completeCalls == 1);
    assert(consumer.payload == expectedPayload);
    assert(consumer.mapId == "golden-map");
    assert(consumer.manifestReceipt == fixture.at("manifest_receipt"));
    assert(consumer.signedManifestReceipt ==
           fixture.at("signed_manifest_receipt"));
    assert(consumer.signatureKeyId == "map-test-2026-01");
    assert(consumer.payloadBytes == expectedPayload.size());
    assert(consumer.fileCount == 1);
    assert(consumer.lastPath ==
           "VECTMAP/golden-map/+0000+0000/0_0.fmb");
    assert(consumer.lastTileDirectory == "+0000+0000");
    assert(consumer.lastFilename == "0_0.fmb");
    assert(consumer.manifestBytes == manifest.size());
  }

  {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    uint32_t random = 0x5eed1234;
    size_t offset = 0;
    while (offset < stream.size()) {
      random = random * 1664525U + 1013904223U;
      const size_t count =
          std::min<size_t>(1 + (random % 23), stream.size() - offset);
      assert(parser.feed(stream.data() + offset, count));
      offset += count;
    }
    assert(parser.finish());
    assert(consumer.payload == expectedPayload);
  }

  {
    const std::string multiManifest =
        "{\"files\":[{\"bytes\":1,\"path\":\"VECTMAP/multi/+0000+0000/0.fmb\","
        "\"sha256\":\"ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb\"},"
        "{\"bytes\":2,\"path\":\"VECTMAP/multi/+0000+0000/1.fmb\","
        "\"sha256\":\"1e0bbd6c686ba050b8eb03ffeedc64fdc9d80947fce821abbe5d6dc8d252c5ac\"},"
        "{\"bytes\":3,\"path\":\"VECTMAP/multi/+0000+0000/2.fmp\","
        "\"sha256\":\"cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34\"}],"
        "\"mapId\":\"multi\",\"schemaVersion\":1,\"target\":{\"formatVersion\":1,"
        "\"minFirmwareVersion\":\"0.0.0\",\"renderer\":\"esp32-fmb\"}}";
    const std::string keyId = "multi-test";
    const auto multiPublicKey = decodeHex(
        "048e62db2c966358515fbaac0c14e99f9a31101d7d86136d82bc1f89a7c3e9a"
        "3153deed4206e7d552b3a7ef9d27d076b8913229e64da87a22dc026952e5fd56470");
    const auto multiSignature = decodeHex(
        "6c97937f6d621071611b83c8c01846476524f39e55b105cfd0c36e5a65ce2883"
        "23680cda9cf5316339822656908c47688343c676ffcf769202ed7c5fd5f1c535");
    const std::vector<uint8_t> multiPayload = {'a', 'b', 'c', 'd', 'e', 'f'};
    const size_t envelopeSize = 4 + keyId.size() + multiSignature.size();
    std::vector<uint8_t> multiStream(MAP_STREAM_FIXED_HEADER_BYTES, 0);
    std::copy_n(reinterpret_cast<const uint8_t *>("BIKEMAP1"), 8,
                multiStream.begin());
    writeLe16(multiStream, 8, 1);
    writeLe32(multiStream, 12, multiManifest.size());
    writeLe16(multiStream, 16, envelopeSize);
    writeLe32(multiStream, 20, 3);
    writeLe64(multiStream, 24, multiPayload.size());
    multiStream.insert(multiStream.end(), multiManifest.begin(),
                       multiManifest.end());
    multiStream.push_back(1);
    multiStream.push_back(static_cast<uint8_t>(keyId.size()));
    multiStream.push_back(64);
    multiStream.push_back(0);
    multiStream.insert(multiStream.end(), keyId.begin(), keyId.end());
    multiStream.insert(multiStream.end(), multiSignature.begin(),
                       multiSignature.end());
    multiStream.insert(multiStream.end(), multiPayload.begin(),
                       multiPayload.end());
    MapStreamTrustStore trust;
    assert(trust.add(keyId, multiPublicKey.data(), multiPublicKey.size()));
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {multiStream.size(), "0.2.4"});
    const std::array<size_t, 9> chunks = {31, 1, 7, 113, 2, 257, 3, 1, 19};
    size_t offset = 0;
    size_t chunkIndex = 0;
    while (offset < multiStream.size()) {
      const size_t count = std::min(chunks[chunkIndex++ % chunks.size()],
                                    multiStream.size() - offset);
      assert(parser.feed(multiStream.data() + offset, count));
      offset += count;
    }
    assert(parser.finish());
    assert(consumer.beginCalls == 3);
    assert(consumer.endCalls == 3);
    assert(consumer.completeCalls == 1);
    assert(consumer.payload == multiPayload);
    assert(consumer.lastFilename == "2.fmp");

    auto understatedCountStream = multiStream;
    writeLe32(understatedCountStream, 20, 1);
    MbedTlsMapStreamSha256 countHasher;
    RecordingConsumer countConsumer;
    MapStreamIncrementalParser countParser(
        trust, countHasher, countConsumer,
        {understatedCountStream.size(), "0.2.4"});
    assert(!countParser.feed(understatedCountStream.data(),
                             understatedCountStream.size()));
    assert(countParser.error() == MapStreamParserError::ManifestInvalid);
    assert(countParser.verifiedManifest() == nullptr);
    assert(countConsumer.manifestCalls == 0);
  }

  for (size_t truncatedBytes = 0; truncatedBytes < stream.size();
       truncatedBytes++) {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    if (truncatedBytes > 0)
      assert(parser.feed(stream.data(), truncatedBytes));
    assert(!parser.finish());
    assert(parser.error() == MapStreamParserError::Truncated);
  }

  {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size() - 1, "0.2.4"});
    assert(!parser.feed(stream.data(), MAP_STREAM_FIXED_HEADER_BYTES));
    assert(parser.error() == MapStreamParserError::ContentLengthMismatch);
  }

  {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer,
        {stream.size(), "0.2.4", manifest.size() - 1});
    assert(!parser.feed(stream.data(), MAP_STREAM_FIXED_HEADER_BYTES));
    assert(parser.error() == MapStreamParserError::ResourceUnavailable);
    assert(parser.errorCode() ==
           std::string("stream_resource_unavailable"));
    assert(consumer.abortCalls == 1);
  }

  {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer,
        {stream.size(), "0.2.4",
         manifest.size() + sizeof(MapStreamFileDescriptor) - 1});
    assert(!parser.feed(stream.data(), stream.size()));
    assert(parser.error() == MapStreamParserError::ResourceUnavailable);
    assert(parser.verifiedManifest() == nullptr);
    assert(consumer.manifestCalls == 0);
  }

  {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), ""});
    assert(!parser.feed(stream.data(), stream.size()));
    assert(parser.error() == MapStreamParserError::FirmwareIncompatible);
    assert(parser.verifiedManifest() == nullptr);
    assert(consumer.manifestCalls == 0);
    assert(consumer.beginCalls == 0);
  }

  for (int rejection = 0; rejection < 3; rejection++) {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    consumer.rejectData = rejection == 0;
    consumer.rejectFileEnd = rejection == 1;
    consumer.rejectComplete = rejection == 2;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    const bool feedAccepted = parser.feed(stream.data(), stream.size());
    if (rejection < 2) {
      assert(!feedAccepted);
    } else {
      assert(feedAccepted);
      assert(!parser.finish());
    }
    assert(parser.error() == MapStreamParserError::ConsumerRejected);
    assert(consumer.abortCalls == 1);
  }

  {
    MapStreamTrustStore trust;
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    assert(!parser.feed(stream.data(), stream.size()));
    assert(parser.error() == MapStreamParserError::UnknownSigningKey);
    assert(parser.verifiedManifest() == nullptr);
    assert(consumer.beginCalls == 0);
    assert(consumer.abortCalls == 1);
    assert(consumer.abortError == MapStreamParserError::UnknownSigningKey);
  }

  {
    auto corruptPayload = stream;
    corruptPayload.back() ^= 1;
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    assert(!parser.feed(corruptPayload.data(), corruptPayload.size()));
    assert(parser.error() == MapStreamParserError::FileHashMismatch);
    assert(consumer.completeCalls == 0);
  }

  {
    auto unsafeManifestStream = stream;
    const std::string pathNeedle = "VECTMAP/golden-map";
    const auto match = std::search(
        unsafeManifestStream.begin(), unsafeManifestStream.end(),
        pathNeedle.begin(), pathNeedle.end());
    assert(match != unsafeManifestStream.end());
    *match = '/';
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    assert(!parser.feed(unsafeManifestStream.data(), unsafeManifestStream.size()));
    assert(parser.error() == MapStreamParserError::SignatureInvalid);
    assert(parser.verifiedManifest() == nullptr);
    assert(consumer.manifestCalls == 0);
  }

  {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    consumer.rejectManifest = true;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    assert(!parser.feed(stream.data(), stream.size()));
    assert(parser.error() == MapStreamParserError::ConsumerRejected);
    assert(consumer.beginCalls == 0);
  }

  {
    auto trust = trustStore(publicKey);
    ResetFailingHasher hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    assert(!parser.feed(stream.data(), stream.size()));
    assert(parser.error() == MapStreamParserError::HashUnavailable);
    assert(consumer.manifestCalls == 1);
    assert(consumer.beginCalls == 1);
  }

  {
    auto trust = trustStore(publicKey);
    ResetFailingHasher hasher;
    RecordingConsumer consumer;
    consumer.consumeCheckpointed = true;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    assert(parser.feed(stream.data(), stream.size()));
    assert(parser.finish());
    assert(consumer.payload == expectedPayload);
    assert(consumer.endCalls == 1);
    assert(consumer.completeCalls == 1);
  }

  {
    auto trust = trustStore(publicKey);
    UpdateFailingHasher hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    assert(!parser.feed(stream.data(), stream.size()));
    assert(parser.error() == MapStreamParserError::HashUnavailable);
  }

  {
    auto trust = trustStore(publicKey);
    FinishFailingHasher hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    assert(!parser.feed(stream.data(), stream.size()));
    assert(parser.error() == MapStreamParserError::HashUnavailable);
  }

  {
    auto trust = trustStore(publicKey);
    MbedTlsMapStreamSha256 hasher;
    RecordingConsumer consumer;
    MapStreamIncrementalParser parser(
        trust, hasher, consumer, {stream.size(), "0.2.4"});
    assert(parser.feed(stream.data(), stream.size()));
    const uint8_t trailing = 0;
    assert(!parser.feed(&trailing, 1));
    assert(parser.error() == MapStreamParserError::TrailingData);
    assert(consumer.completeCalls == 0);
  }

  {
    const std::string sha(64, '0');
    const std::string first = "VECTMAP/map/+0000+0000/1.fmb";
    const std::string second = "VECTMAP/map/+0000+0000/2.fmp";
    auto manifestText = [&](const std::string &firstPath,
                            const std::string &secondPath) {
      return std::string("{\"files\":[{\"bytes\":1,\"path\":\"") +
             firstPath + "\",\"sha256\":\"" + sha +
             "\"},{\"bytes\":2,\"path\":\"" + secondPath +
             "\",\"sha256\":\"" + sha +
             "\"}],\"mapId\":\"map\",\"schemaVersion\":1,"
             "\"target\":{\"formatVersion\":1,"
             "\"minFirmwareVersion\":\"0.0.0\","
             "\"renderer\":\"esp32-fmb\"}}";
    };
    MapStreamHeader manifestHeader;
    manifestHeader.fileCount = 2;
    manifestHeader.payloadBytes = 3;
    ParsedMapStreamManifest parsed;
    const std::string validManifest = manifestText(first, second);
    assert(parseMapStreamManifest(validManifest, manifestHeader, parsed));
    assert(parsed.files.size() == 2);
    const auto &firstDescriptor = parsed.files[0];
    assert(std::string_view(validManifest)
               .substr(firstDescriptor.pathOffset, firstDescriptor.pathBytes) ==
           first);
    assert(std::string_view(validManifest)
               .substr(firstDescriptor.tileOffset, firstDescriptor.tileBytes) ==
           "+0000+0000");
    assert(!parseMapStreamManifest(manifestText(second, first), manifestHeader,
                                   parsed));
    assert(!parseMapStreamManifest(manifestText(first, first), manifestHeader,
                                   parsed));
    manifestHeader.payloadBytes = 4;
    assert(!parseMapStreamManifest(manifestText(first, second), manifestHeader,
                                   parsed));
    manifestHeader.payloadBytes = 3;
    manifestHeader.fileCount = 1;
    assert(!parseMapStreamManifest(manifestText(first, second), manifestHeader,
                                   parsed));
    manifestHeader.fileCount = 2;
    assert(!parseMapStreamManifest(
        manifestText("VECTMAP/other/+0000+0000/1.fmb", second),
        manifestHeader, parsed));
    assert(!parseMapStreamManifest(
        manifestText("VECTMAP/map/" + std::string(65, 'a') + "/1.fmb",
                     second),
        manifestHeader, parsed));
    auto uppercaseSha = validManifest;
    const size_t shaPosition = uppercaseSha.find(std::string(64, '0'));
    assert(shaPosition != std::string::npos);
    uppercaseSha[shaPosition] = 'A';
    assert(!parseMapStreamManifest(uppercaseSha, manifestHeader, parsed));
    auto zeroBytes = validManifest;
    const size_t bytesPosition = zeroBytes.find("\"bytes\":1");
    assert(bytesPosition != std::string::npos);
    zeroBytes[bytesPosition + 8] = '0';
    assert(!parseMapStreamManifest(zeroBytes, manifestHeader, parsed));
    auto oversizedBlock = validManifest;
    oversizedBlock.replace(bytesPosition + 8, 1,
                            std::to_string(
                                map_block_format::kMaximumBlockBytes + 1));
    manifestHeader.payloadBytes =
        map_block_format::kMaximumBlockBytes + 3;
    assert(!parseMapStreamManifest(oversizedBlock, manifestHeader, parsed));
    manifestHeader.payloadBytes = 3;
    auto wrongRenderer = validManifest;
    const size_t rendererPosition = wrongRenderer.find("esp32-fmb");
    assert(rendererPosition != std::string::npos);
    wrongRenderer[rendererPosition + 8] = 'p';
    assert(!parseMapStreamManifest(wrongRenderer, manifestHeader, parsed));
    auto missingMinimum = validManifest;
    const size_t minimumKeyPosition = missingMinimum.find("minFirmwareVersion");
    assert(minimumKeyPosition != std::string::npos);
    missingMinimum[minimumKeyPosition] = 'x';
    assert(!parseMapStreamManifest(missingMinimum, manifestHeader, parsed));
    auto withWhitespace = validManifest;
    withWhitespace.insert(1, " ");
    assert(!parseMapStreamManifest(withWhitespace, manifestHeader, parsed));
    auto withUnknownValue = [&](const std::string &value) {
      auto candidate = validManifest;
      candidate.insert(candidate.size() - 1, ",\"z\":" + value);
      return candidate;
    };
    assert(!parseMapStreamManifest(withUnknownValue("\"\\/\""),
                                   manifestHeader, parsed));
    assert(!parseMapStreamManifest(withUnknownValue("\"\\u000A\""),
                                   manifestHeader, parsed));
    assert(!parseMapStreamManifest(withUnknownValue("\"\\u000a\""),
                                   manifestHeader, parsed));
    assert(!parseMapStreamManifest(withUnknownValue("1.00"), manifestHeader,
                                   parsed));
    assert(!parseMapStreamManifest(withUnknownValue("1E+16"), manifestHeader,
                                   parsed));
    assert(!parseMapStreamManifest(withUnknownValue("1e+01"), manifestHeader,
                                   parsed));
    assert(!parseMapStreamManifest(withUnknownValue("1.0e+16"),
                                   manifestHeader, parsed));
    assert(!parseMapStreamManifest(
        withUnknownValue("1.234567890123456789"), manifestHeader, parsed));
    assert(!parseMapStreamManifest(withUnknownValue("1e-05"), manifestHeader,
                                   parsed));
    assert(!parseMapStreamManifest(withUnknownValue("-0"), manifestHeader,
                                   parsed));
    assert(parseMapStreamManifest(withUnknownValue("-1"), manifestHeader,
                                  parsed));
    assert(parseMapStreamManifest(withUnknownValue("\"\\u0000\""),
                                  manifestHeader, parsed));
    auto reorderedTopLevel = validManifest;
    const std::string orderedPrefix = "{\"files\":";
    assert(reorderedTopLevel.rfind(orderedPrefix, 0) == 0);
    std::string filesAndRemainder =
        reorderedTopLevel.substr(orderedPrefix.size());
    const std::string mapField = ",\"mapId\":\"map\"";
    const size_t mapFieldPosition = filesAndRemainder.find(mapField);
    assert(mapFieldPosition != std::string::npos);
    filesAndRemainder.erase(mapFieldPosition, mapField.size());
    reorderedTopLevel = "{\"mapId\":\"map\",\"files\":" +
                        filesAndRemainder;
    assert(!parseMapStreamManifest(reorderedTopLevel, manifestHeader, parsed));
    auto invalidUtf8 = validManifest;
    invalidUtf8.insert(invalidUtf8.size() - 1, ",\"z\":\"");
    invalidUtf8.push_back(static_cast<char>(0xc0));
    invalidUtf8 += "\"}";
    assert(!parseMapStreamManifest(invalidUtf8, manifestHeader, parsed));
    const std::string wrappedSizes =
        "{\"files\":[{\"bytes\":18446744073709551610,\"path\":\"" +
        first + "\",\"sha256\":\"" + sha +
        "\"},{\"bytes\":7,\"path\":\"" + second +
        "\",\"sha256\":\"" + sha +
        "\"}],\"mapId\":\"map\",\"schemaVersion\":1,"
        "\"target\":{\"formatVersion\":1,"
        "\"minFirmwareVersion\":\"0.0.0\","
        "\"renderer\":\"esp32-fmb\"}}";
    manifestHeader.payloadBytes = 1;
    assert(!parseMapStreamManifest(wrappedSizes, manifestHeader, parsed));
    assert(mapStreamFirmwareCompatible("0.2.4", "0.2.4"));
    assert(mapStreamFirmwareCompatible("0.3.0", "0.2.4"));
    assert(!mapStreamFirmwareCompatible("0.2.3", "0.2.4"));
    assert(!mapStreamFirmwareCompatible("0.2", "0.2.0"));
    assert(!mapStreamFirmwareCompatible("0.2.0", "01.0.0"));
  }

  {
    constexpr size_t realisticFileCount = 5505;
    const std::string sha(64, '0');
    std::string largeManifest = "{\"files\":[";
    largeManifest.reserve(realisticFileCount * 135);
    for (size_t index = 0; index < realisticFileCount; index++) {
      if (index != 0)
        largeManifest.push_back(',');
      std::string filename = std::to_string(index);
      filename.insert(filename.begin(), 5 - filename.size(), '0');
      largeManifest += "{\"bytes\":1,\"path\":\"VECTMAP/shanghai/";
      largeManifest += "+0000+0000/" + filename +
                       ".fmb\",\"sha256\":\"" + sha + "\"}";
    }
    largeManifest +=
        "],\"mapId\":\"shanghai\",\"schemaVersion\":1,"
        "\"target\":{\"formatVersion\":1,"
        "\"minFirmwareVersion\":\"0.0.0\","
        "\"renderer\":\"esp32-fmb\"}}";
    MapStreamHeader header;
    header.fileCount = realisticFileCount;
    header.payloadBytes = realisticFileCount;
    ParsedMapStreamManifest parsed;
    assert(largeManifest.size() < map_transfer::MAP_STREAM_MAX_MANIFEST_BYTES);
    assert(parseMapStreamManifest(largeManifest, header, parsed));
    assert(parsed.files.size() == realisticFileCount);
    assert(sizeof(MapStreamFileDescriptor) <= 64);
    assert(parsed.files.capacity() * sizeof(MapStreamFileDescriptor) <=
           512 * 1024);

    const std::string mapId(64, 'm');
    const std::string tile(64, 't');
    const std::string filename = std::string(60, 'f') + ".fmb";
    const std::string boundaryPath =
        "VECTMAP/" + mapId + "/" + tile + "/" + filename;
    assert(boundaryPath.size() ==
           map_transfer::MAP_STREAM_MAX_RELATIVE_PATH_BYTES);
    const std::string boundaryManifest =
        "{\"files\":[{\"bytes\":1,\"path\":\"" + boundaryPath +
        "\",\"sha256\":\"" + sha +
        "\"}],\"mapId\":\"" + mapId +
        "\",\"schemaVersion\":1,\"target\":{\"formatVersion\":1,"
        "\"minFirmwareVersion\":\"0.0.0\","
        "\"renderer\":\"esp32-fmb\"}}";
    header.fileCount = 1;
    header.payloadBytes = 1;
    assert(parseMapStreamManifest(boundaryManifest, header, parsed));
  }

  std::cout << "Map stream format tests passed\n";
  return 0;
}
