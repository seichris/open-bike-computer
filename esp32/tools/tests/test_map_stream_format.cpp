#include "../../lib/map_transfer/map_stream_format.hpp"
#include "../../lib/map_transfer/map_stream_crypto.hpp"

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
using map_transfer::mapStreamManifestReceipt;
using map_transfer::mapStreamSignedManifestReceipt;
using map_transfer::mapStreamLayout;
using map_transfer::parseMapStreamHeader;
using map_transfer::parseMapStreamSignatureEnvelope;
using map_transfer::verifyMapStreamP256Signature;

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
  assert(header.payloadBytes == 9);
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
  auto invalidEnvelope = envelopeBytes;
  invalidEnvelope[2] = 63;
  assert(parseMapStreamSignatureEnvelope(
             invalidEnvelope.data(), invalidEnvelope.size(), envelope) ==
         MapStreamFormatError::InvalidSignatureLength);

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

  std::cout << "Map stream format tests passed\n";
  return 0;
}
