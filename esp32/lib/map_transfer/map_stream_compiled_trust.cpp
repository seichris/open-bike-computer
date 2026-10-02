#include "map_stream_compiled_trust.hpp"

#include <array>
#include <cstdint>
#include <string>

namespace map_transfer {
namespace {

struct CompiledKey {
  const char *keyId;
  const char *publicKeyX963Hex;
  const char *publicKeySha256;
};

#include "map_stream_compiled_keys.generated.inc"
#if defined(MAP_STREAM_DEVELOPMENT_TRUST) && MAP_STREAM_DEVELOPMENT_TRUST
#include "map_stream_development_compiled_key.generated.inc"
#endif

template <typename Callback> bool forEachCompiledKey(Callback callback) {
  for (const CompiledKey &key : kCompiledKeys) {
    if (!callback(key))
      return false;
  }
#if defined(MAP_STREAM_DEVELOPMENT_TRUST) && MAP_STREAM_DEVELOPMENT_TRUST
  if (!callback(kDevelopmentCompiledKey))
    return false;
#endif
  return true;
}

bool decodeHex(const char *hex, std::array<uint8_t, 65> &bytes) {
  if (hex == nullptr || std::char_traits<char>::length(hex) != bytes.size() * 2)
    return false;
  const auto nibble = [](char value) -> int {
    if (value >= '0' && value <= '9')
      return value - '0';
    if (value >= 'a' && value <= 'f')
      return value - 'a' + 10;
    if (value >= 'A' && value <= 'F')
      return value - 'A' + 10;
    return -1;
  };
  for (size_t index = 0; index < bytes.size(); index++) {
    const int high = nibble(hex[index * 2]);
    const int low = nibble(hex[index * 2 + 1]);
    if (high < 0 || low < 0)
      return false;
    bytes[index] = static_cast<uint8_t>((high << 4) | low);
  }
  return true;
}

} // namespace

MapStreamTrustStore compiledMapStreamTrustStore() {
  MapStreamTrustStore trust;
  const bool valid = forEachCompiledKey([&trust](const CompiledKey &key) {
    std::array<uint8_t, 65> publicKey = {};
    if (!decodeHex(key.publicKeyX963Hex, publicKey) ||
        !trust.add(key.keyId, publicKey.data(), publicKey.size())) {
      return false;
    }
    return true;
  });
  if (!valid)
    return MapStreamTrustStore();
  return trust;
}

std::string compiledMapStreamTrustCapabilitiesJson() {
  std::string json = "[";
  bool first = true;
  forEachCompiledKey([&json, &first](const CompiledKey &key) {
    if (!first)
      json += ",";
    first = false;
    json += "\"" + std::string(key.keyId) + "=" + key.publicKeySha256 + "\"";
    return true;
  });
  json += "]";
  return json;
}

} // namespace map_transfer
