// Durable map contract v1: this firmware must keep reading the frozen
// producer corpus (map-platform/backend/tests/fixtures/map-compatibility-v1).
// Every production stream must install on every profile; development POI
// streams need the POI reader. The reported reader capabilities must match
// what the parser actually admits.
#include "../../lib/map_transfer/map_reader_capabilities.hpp"
#include "../../lib/map_transfer/map_stream_crypto.hpp"
#include "../../lib/map_transfer/map_stream_parser.hpp"
#include "../../lib/map_transfer/map_stream_sha.hpp"
#include "../../lib/map_transfer/map_stream_trust.hpp"
#include "../../lib/maps/src/mapRendererFileValidator.hpp"

#include <cassert>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

using map_transfer::MapStreamConsumer;
using map_transfer::MapStreamFileAction;
using map_transfer::MapStreamFileView;
using map_transfer::MapStreamIncrementalParser;
using map_transfer::MapStreamParserError;
using map_transfer::MapStreamTrustStore;
using map_transfer::MbedTlsMapStreamSha256;
using map_transfer::VerifiedMapStreamManifest;

namespace {

const std::string kCorpus =
    "../map-platform/backend/tests/fixtures/map-compatibility-v1/";
const std::string kCapabilities =
    "../protocol/fixtures/map-reader-capabilities-v1.txt";

struct CorpusStream {
  std::string file;
  std::string profile;
  std::string mapId;
  uint32_t formatVersion = 0;
  std::string channel;
  std::string keyId;
  std::string manifestReceipt;
  std::string signedManifestReceipt;
  size_t fileCount = 0;
  uint64_t payloadBytes = 0;
};

class RendererConsumer final : public MapStreamConsumer {
public:
  bool onManifest(const VerifiedMapStreamManifest &manifest,
                  std::string_view) override {
    mapId = manifest.manifest.metadata.mapId;
    formatVersion = manifest.manifest.metadata.formatVersion;
    manifestReceipt = manifest.manifestReceipt;
    signedManifestReceipt = manifest.signedManifestReceipt;
    signatureKeyId = manifest.signatureKeyId;
    fileCount = manifest.manifest.files.size();
    payloadBytes = manifest.payloadBytes;
    return true;
  }

  MapStreamFileAction onFileBegin(const MapStreamFileView &file,
                                  size_t) override {
    validator = std::make_unique<map_renderer_format::StreamValidator>(
        std::string(file.path));
    return MapStreamFileAction::VerifyAndConsume;
  }

  bool onFileData(const MapStreamFileView &, const uint8_t *data,
                  size_t size) override {
    return validator->feed(data, size);
  }

  bool onFileEnd(const MapStreamFileView &, size_t) override {
    const bool valid = validator->finish() && !validator->failed();
    validator.reset();
    validFiles += valid ? 1 : 0;
    return valid;
  }

  bool onComplete(const VerifiedMapStreamManifest &) override {
    completed = true;
    return true;
  }

  void onAbort(MapStreamParserError) override {}

  std::unique_ptr<map_renderer_format::StreamValidator> validator;
  std::string mapId;
  uint32_t formatVersion = 0;
  std::string manifestReceipt;
  std::string signedManifestReceipt;
  std::string signatureKeyId;
  size_t fileCount = 0;
  size_t validFiles = 0;
  uint64_t payloadBytes = 0;
  bool completed = false;
};

std::vector<uint8_t> readBytes(const std::string &path) {
  std::ifstream input(path, std::ios::binary);
  assert(input.good());
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(input), {});
}

std::vector<uint8_t> decodeHex(const std::string &hex) {
  assert(hex.size() % 2 == 0);
  std::vector<uint8_t> bytes;
  for (size_t index = 0; index < hex.size(); index += 2)
    bytes.push_back(
        static_cast<uint8_t>(std::stoul(hex.substr(index, 2), nullptr, 16)));
  return bytes;
}

struct ParseResult {
  bool complete = false;
  MapStreamParserError error = MapStreamParserError::None;
  RendererConsumer consumer;
};

std::unique_ptr<ParseResult> parse(const std::vector<uint8_t> &stream,
                                   const MapStreamTrustStore &trust,
                                   const std::string &firmwareVersion,
                                   size_t chunkSize) {
  auto result = std::make_unique<ParseResult>();
  MbedTlsMapStreamSha256 hasher;
  MapStreamIncrementalParser parser(trust, hasher, result->consumer,
                                    {stream.size(), firmwareVersion});
  bool fed = true;
  for (size_t offset = 0; fed && offset < stream.size(); offset += chunkSize)
    fed = parser.feed(stream.data() + offset,
                      std::min(chunkSize, stream.size() - offset));
  result->complete = fed && parser.finish() && parser.complete();
  result->error = parser.error();
  return result;
}

} // namespace

int main() {
  std::ifstream index(kCorpus + "corpus.txt");
  assert(index.good());
  MapStreamTrustStore trust;
  std::map<std::string, std::vector<uint8_t>> publicKeys;
  std::vector<CorpusStream> streams;
  std::string line;
  while (std::getline(index, line)) {
    std::istringstream fields(line);
    std::string kind;
    std::getline(fields, kind, '=');
    if (kind == "contract") {
      std::string contract;
      fields >> contract;
      assert(contract == "1");
    } else if (kind == "signer") {
      std::string keyId, publicKey;
      fields >> keyId >> publicKey;
      publicKeys[keyId] = decodeHex(publicKey);
      assert(trust.add(keyId, publicKeys[keyId].data(),
                       publicKeys[keyId].size()));
    } else {
      assert(kind == "stream");
      CorpusStream stream;
      fields >> stream.file >> stream.profile >> stream.mapId >>
          stream.formatVersion >> stream.channel >> stream.keyId >>
          stream.manifestReceipt >> stream.signedManifestReceipt >>
          stream.fileCount >> stream.payloadBytes;
      assert(!fields.fail());
      streams.push_back(stream);
    }
  }
  assert(streams.size() == 15);

  std::ifstream capabilityFixture(kCapabilities);
  assert(capabilityFixture.good());
  std::map<std::string, std::string> capabilities;
  while (std::getline(capabilityFixture, line)) {
    if (line.empty() || line[0] == '#')
      continue;
    const size_t separator = line.find(' ');
    capabilities[line.substr(0, separator)] = line.substr(separator + 1);
  }
  const std::string reported = map_transfer::mapReaderCapabilitiesJson();
  assert(reported ==
         capabilities.at(MAP_POIS_RUNTIME_ENABLED ? "map_pois" : "production"));

  size_t installed = 0;
  for (const CorpusStream &expected : streams) {
    const auto bytes = readBytes(kCorpus + expected.file);
    const bool readable = expected.formatVersion != 5 || MAP_POIS_RUNTIME_ENABLED;
    const std::string format =
        std::to_string(expected.formatVersion);
    // The report advertises a format exactly when the parser admits it.
    assert((reported.find("," + format) != std::string::npos ||
            reported.find("[" + format) != std::string::npos) == readable);
    for (size_t chunk : {size_t(1), size_t(4096), bytes.size()}) {
      // The map's minimum is 0.3.4; later firmware keeps reading it.
      for (const char *firmware : {"0.3.4", "0.3.5", "1.0.0"}) {
        auto result = parse(bytes, trust, firmware, chunk);
        if (!readable) {
          assert(!result->complete);
          assert(result->error == MapStreamParserError::FirmwareIncompatible);
          continue;
        }
        assert(result->complete);
        assert(result->consumer.completed);
        assert(result->consumer.mapId == expected.mapId);
        assert(result->consumer.formatVersion == expected.formatVersion);
        assert(result->consumer.signatureKeyId == expected.keyId);
        assert(result->consumer.manifestReceipt == expected.manifestReceipt);
        assert(result->consumer.signedManifestReceipt ==
               expected.signedManifestReceipt);
        assert(result->consumer.fileCount == expected.fileCount);
        assert(result->consumer.validFiles == expected.fileCount);
        assert(result->consumer.payloadBytes == expected.payloadBytes);
      }
    }
    if (!readable)
      continue;
    installed++;

    // An older firmware than the signed minimum is refused before payload.
    assert(parse(bytes, trust, "0.3.3", bytes.size())->error ==
           MapStreamParserError::FirmwareIncompatible);

    // A device that does not trust the signer refuses the stream.
    MapStreamTrustStore withoutSigner;
    for (const auto &[keyId, publicKey] : publicKeys)
      if (keyId != expected.keyId)
        assert(withoutSigner.add(keyId, publicKey.data(), publicKey.size()));
    assert(parse(bytes, withoutSigner, "0.3.4", bytes.size())->error ==
           MapStreamParserError::UnknownSigningKey);

    // Corrupt, truncated and extended streams never install.
    auto corrupted = bytes;
    corrupted.back() ^= 0x01;
    {
      auto result = parse(corrupted, trust, "0.3.4", corrupted.size());
      assert(!result->complete);
      assert(result->error == MapStreamParserError::FileHashMismatch ||
             result->error == MapStreamParserError::ConsumerRejected);
    }
    auto truncated = bytes;
    truncated.pop_back();
    {
      auto result = parse(truncated, trust, "0.3.4", truncated.size());
      assert(!result->complete);
    }
    auto extended = bytes;
    extended.push_back(0);
    {
      auto result = parse(extended, trust, "0.3.4", extended.size());
      assert(!result->complete);
    }
    auto forged = bytes;
    forged[40] ^= 0x01;
    {
      auto result = parse(forged, trust, "0.3.4", forged.size());
      assert(!result->complete);
      assert(result->error == MapStreamParserError::SignatureInvalid ||
             result->error == MapStreamParserError::ManifestInvalid);
    }
  }
  assert(installed == (MAP_POIS_RUNTIME_ENABLED ? 15u : 12u));
  std::cout << "map compatibility corpus: " << installed
            << " frozen streams installed" << std::endl;
  return 0;
}
