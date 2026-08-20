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
inline constexpr char kDiagnosticsLanCommandPrefix[] =
    "enter|diagnostics|lan1|";

enum class LanSessionMode : uint8_t { Debug = 0, Diagnostics = 1 };

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

inline const char *lanFallbackReasonForStatus(int stationStatus,
                                              int noSsidStatus,
                                              int connectFailedStatus) {
  if (stationStatus == noSsidStatus)
    return "ssid_unavailable";
  if (stationStatus == connectFailedStatus)
    return "authentication_failed";
  return "association_timeout";
}

inline LanCommandParseResult parseTransferLanCommand(
    const uint8_t *data, size_t length, LanSessionMode &mode,
    LanCredentials &credentials) {
  if (data == nullptr)
    return LanCommandParseResult::NotLanCommand;
  const char *prefix = nullptr;
  size_t prefixLength = 0;
  constexpr size_t debugPrefixLength =
      sizeof(kRemoteDebugLanCommandPrefix) - 1;
  constexpr size_t diagnosticsPrefixLength =
      sizeof(kDiagnosticsLanCommandPrefix) - 1;
  if (length >= debugPrefixLength &&
      std::char_traits<char>::compare(
          reinterpret_cast<const char *>(data),
          kRemoteDebugLanCommandPrefix, debugPrefixLength) == 0) {
    prefix = kRemoteDebugLanCommandPrefix;
    prefixLength = debugPrefixLength;
    mode = LanSessionMode::Debug;
  } else if (length >= diagnosticsPrefixLength &&
             std::char_traits<char>::compare(
                 reinterpret_cast<const char *>(data),
                 kDiagnosticsLanCommandPrefix,
                 diagnosticsPrefixLength) == 0) {
    prefix = kDiagnosticsLanCommandPrefix;
    prefixLength = diagnosticsPrefixLength;
    mode = LanSessionMode::Diagnostics;
  } else {
    return LanCommandParseResult::NotLanCommand;
  }
  (void)prefix;
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

inline LanCommandParseResult parseRemoteDebugLanCommand(
    const uint8_t *data, size_t length, LanCredentials &credentials) {
  LanSessionMode mode = LanSessionMode::Debug;
  const LanCommandParseResult result =
      parseTransferLanCommand(data, length, mode, credentials);
  if (result == LanCommandParseResult::Valid && mode != LanSessionMode::Debug)
    return LanCommandParseResult::NotLanCommand;
  return result;
}

} // namespace device_transfer
