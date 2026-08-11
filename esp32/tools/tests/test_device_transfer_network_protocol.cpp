#include "../../lib/device_transfer/device_transfer_network_protocol.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

using device_transfer::LanCommandParseResult;
using device_transfer::LanCredentials;

static std::vector<uint8_t> command(const std::string &ssid,
                                    const std::string &password) {
  const std::string prefix = device_transfer::kRemoteDebugLanCommandPrefix;
  std::vector<uint8_t> payload(prefix.begin(), prefix.end());
  payload.push_back(static_cast<uint8_t>(ssid.size()));
  payload.push_back(static_cast<uint8_t>(password.size()));
  payload.insert(payload.end(), ssid.begin(), ssid.end());
  payload.insert(payload.end(), password.begin(), password.end());
  return payload;
}

int main() {
  LanCredentials credentials;
  const auto valid = command("Home Wi-Fi", "correct horse battery staple");
  assert(device_transfer::parseRemoteDebugLanCommand(
             valid.data(), valid.size(), credentials) ==
         LanCommandParseResult::Valid);
  assert(credentials.ssid == "Home Wi-Fi");
  assert(credentials.password == "correct horse battery staple");

  const auto open = command("Developer Lab", "");
  assert(device_transfer::parseRemoteDebugLanCommand(
             open.data(), open.size(), credentials) ==
         LanCommandParseResult::Valid);
  assert(credentials.password.empty());

  const std::string ordinary = "enter|debug";
  assert(device_transfer::parseRemoteDebugLanCommand(
             reinterpret_cast<const uint8_t *>(ordinary.data()),
             ordinary.size(), credentials) ==
         LanCommandParseResult::NotLanCommand);

  assert(std::string(device_transfer::lanFallbackReasonForStatus(1, 1, 2)) ==
         "ssid_unavailable");
  assert(std::string(device_transfer::lanFallbackReasonForStatus(2, 1, 2)) ==
         "authentication_failed");
  assert(std::string(device_transfer::lanFallbackReasonForStatus(3, 1, 2)) ==
         "association_timeout");

  auto truncated = valid;
  truncated.pop_back();
  assert(device_transfer::parseRemoteDebugLanCommand(
             truncated.data(), truncated.size(), credentials) ==
         LanCommandParseResult::Invalid);

  const auto shortPassword = command("Home Wi-Fi", "short");
  assert(device_transfer::parseRemoteDebugLanCommand(
             shortPassword.data(), shortPassword.size(), credentials) ==
         LanCommandParseResult::Invalid);

  const auto longSsid = command(std::string(33, 's'), "password");
  assert(device_transfer::parseRemoteDebugLanCommand(
             longSsid.data(), longSsid.size(), credentials) ==
         LanCommandParseResult::Invalid);

  std::cout << "device transfer network protocol tests passed\n";
  return 0;
}
