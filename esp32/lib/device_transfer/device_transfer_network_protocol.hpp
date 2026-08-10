#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>

namespace device_transfer {

inline constexpr size_t kMaxLanSsidBytes = 32;
inline constexpr size_t kMinLanPasswordBytes = 8;
inline constexpr size_t kMaxLanPasswordBytes = 63;
inline constexpr char kRemoteDebugLanCommandPrefix[] =
    "enter|debug|lan1|";

struct LanCredentials {
  std::string ssid;
  std::string password;
};

enum class LanCommandParseResult : uint8_t {
  NotLanCommand = 0,
  Valid = 1,
  Invalid = 2,
};

inline bool validLanCredentials(const LanCredentials &credentials) {
  if (credentials.ssid.empty() ||
      credentials.ssid.size() > kMaxLanSsidBytes ||
      credentials.ssid.find('\0') != std::string::npos ||
      credentials.password.size() > kMaxLanPasswordBytes ||
      credentials.password.find('\0') != std::string::npos) {
    return false;
  }
  return credentials.password.empty() ||
         credentials.password.size() >= kMinLanPasswordBytes;
}

inline LanCommandParseResult parseRemoteDebugLanCommand(
    const uint8_t *data, size_t length, LanCredentials &credentials) {
  constexpr size_t prefixLength = sizeof(kRemoteDebugLanCommandPrefix) - 1;
  if (data == nullptr || length < prefixLength ||
      std::char_traits<char>::compare(
          reinterpret_cast<const char *>(data),
          kRemoteDebugLanCommandPrefix, prefixLength) != 0) {
    return LanCommandParseResult::NotLanCommand;
  }
  if (length < prefixLength + 2) {
    return LanCommandParseResult::Invalid;
  }

  const size_t ssidLength = data[prefixLength];
  const size_t passwordLength = data[prefixLength + 1];
  if (length != prefixLength + 2 + ssidLength + passwordLength) {
    return LanCommandParseResult::Invalid;
  }

  LanCredentials parsed;
  parsed.ssid.assign(
      reinterpret_cast<const char *>(data + prefixLength + 2), ssidLength);
  parsed.password.assign(
      reinterpret_cast<const char *>(data + prefixLength + 2 + ssidLength),
      passwordLength);
  if (!validLanCredentials(parsed)) {
    return LanCommandParseResult::Invalid;
  }
  credentials = std::move(parsed);
  return LanCommandParseResult::Valid;
}

} // namespace device_transfer
