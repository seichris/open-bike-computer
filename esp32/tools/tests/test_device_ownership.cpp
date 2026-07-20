#include "../../lib/ble_navigation/device_ownership.hpp"
#include "../../lib/ble_navigation/ble_connection_policy.hpp"
#include "../../lib/ble_navigation/disconnected_shutdown_policy.hpp"
#include "../../lib/ble_navigation/ownership_button_policy.hpp"
#include "host_stubs/Preferences.h"

#include <array>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <mbedtls/gcm.h>
#include <string>
#include <vector>

using namespace device_ownership;

static std::string sharedFixtureValue(const std::string &key) {
  std::ifstream fixture("../docs/device-ownership-test-vectors.json");
  assert(fixture.good());
  const std::string json((std::istreambuf_iterator<char>(fixture)),
                         std::istreambuf_iterator<char>());
  const std::string prefix = "\"" + key + "\": \"";
  const size_t start = json.find(prefix);
  assert(start != std::string::npos);
  const size_t valueStart = start + prefix.size();
  const size_t end = json.find('"', valueStart);
  assert(end != std::string::npos);
  return json.substr(valueStart, end - valueStart);
}

static std::vector<std::string> split(const std::string &value) {
  std::vector<std::string> parts;
  size_t start = 0;
  while (start <= value.size()) {
    const size_t end = value.find('|', start);
    parts.push_back(value.substr(start, end - start));
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return parts;
}

static std::string proof(const OwnerKey &key, const std::string &message) {
  std::array<uint8_t, 32> digest{};
  assert(hmacSha256(key.data(), key.size(),
                    reinterpret_cast<const uint8_t *>(message.data()),
                    message.size(), digest.data()));
  return hexEncode(digest.data(), digest.size());
}

static std::string binary(const std::string &hex) {
  std::string result(hex.size() / 2, '\0');
  assert(hexDecode(hex, reinterpret_cast<uint8_t *>(result.data()),
                   result.size()));
  return result;
}

static OwnerKey keyFromHex(const std::string &hex) {
  OwnerKey result{};
  assert(hexDecode(hex, result.data(), result.size()));
  return result;
}

static OwnerKey sessionKey(const OwnerKey &ownerKey, const char *label,
                           const std::string &context) {
  OwnerKey result{};
  const std::string message = std::string(label) + "|" + context;
  assert(hmacSha256(ownerKey.data(), ownerKey.size(),
                    reinterpret_cast<const uint8_t *>(message.data()),
                    message.size(), result.data()));
  return result;
}

static std::string writeFrame(const OwnerKey &writeKey,
                              AuthenticatedChannel channel, uint32_t sequence,
                              const std::string &plaintext) {
  const uint8_t channelByte = static_cast<uint8_t>(channel);
  const uint8_t sequenceBytes[4] = {
      static_cast<uint8_t>(sequence >> 24),
      static_cast<uint8_t>(sequence >> 16),
      static_cast<uint8_t>(sequence >> 8), static_cast<uint8_t>(sequence)};
  const std::array<uint8_t, 12> nonce = {
      channelByte, 0, 0, 0, 0, 0, 0, 0, sequenceBytes[0], sequenceBytes[1],
      sequenceBytes[2], sequenceBytes[3]};
  std::string aad = "write2|";
  aad.push_back(static_cast<char>(channelByte));
  aad.append(reinterpret_cast<const char *>(sequenceBytes), 4);
  std::string ciphertext(plaintext.size(), '\0');
  std::array<uint8_t, 16> tag{};
  mbedtls_gcm_context context;
  mbedtls_gcm_init(&context);
  assert(mbedtls_gcm_setkey(&context, MBEDTLS_CIPHER_ID_AES, writeKey.data(),
                            256) == 0);
  assert(mbedtls_gcm_crypt_and_tag(
             &context, MBEDTLS_GCM_ENCRYPT, plaintext.size(), nonce.data(),
             nonce.size(), reinterpret_cast<const uint8_t *>(aad.data()),
             aad.size(), reinterpret_cast<const uint8_t *>(plaintext.data()),
             reinterpret_cast<uint8_t *>(ciphertext.data()), tag.size(),
             tag.data()) == 0);
  mbedtls_gcm_free(&context);
  std::string frame = "S2";
  frame.append(reinterpret_cast<const char *>(sequenceBytes), 4);
  frame.append(ciphertext);
  frame.append(reinterpret_cast<const char *>(tag.data()), tag.size());
  return frame;
}

struct AppPairing {
  PairingKeyAgreement agreement;
  OwnerId ownerId{};
  PublicKey publicKey{};

  explicit AppPairing(uint8_t privateTail) {
    uint8_t privateKey[32]{};
    privateKey[31] = privateTail;
    assert(agreement.setPrivateKeyForTesting(privateKey));
    assert(agreement.publicKey(publicKey));
    for (size_t index = 0; index < ownerId.size(); index++)
      ownerId[index] = static_cast<uint8_t>(0xA0 + index);
  }

  std::string command() const {
    return "PAIR|" + hexEncode(ownerId.data(), ownerId.size()) + "|" +
           hexEncode(publicKey.data(), publicKey.size());
  }

  PairingMaterial material(const CommandResult &response) {
    const auto parts = split(response.response);
    assert(parts.size() == 3 && parts[0] == "PAIRING");
    DeviceId deviceId{};
    PublicKey devicePublic{};
    assert(hexDecode(parts[1], deviceId.data(), deviceId.size()));
    assert(hexDecode(parts[2], devicePublic.data(), devicePublic.size()));
    PairingMaterial result{};
    assert(agreement.derive(devicePublic, deviceId, ownerId, publicKey,
                            devicePublic, result));
    return result;
  }

  std::string confirm(const PairingMaterial &material,
                      const std::string &name) const {
    std::array<uint8_t, 32> digest{};
    std::array<uint8_t, 6 + TRANSCRIPT_HASH_SIZE> message{};
    std::memcpy(message.data(), "claim|", 6);
    std::memcpy(message.data() + 6, material.transcriptHash.data(),
                material.transcriptHash.size());
    assert(hmacSha256(material.ownerKey.data(), material.ownerKey.size(),
                      message.data(), message.size(), digest.data()));
    return "CONFIRM|" + hexEncode(ownerId.data(), ownerId.size()) + "|" +
           hexEncode(digest.data(), digest.size()) + "|" +
           hexEncode(reinterpret_cast<const uint8_t *>(name.data()),
                     name.size());
  }
};

int main() {
  assert(disconnected_shutdown_policy::effectiveTimeoutSeconds(120, true) ==
         120);
  assert(disconnected_shutdown_policy::effectiveTimeoutSeconds(120, false) ==
         600);
  assert(disconnected_shutdown_policy::effectiveTimeoutSeconds(600, false) ==
         600);
  assert(disconnected_shutdown_policy::effectiveTimeoutSeconds(0, false) ==
         0);
  disconnected_shutdown_policy::Tracker shutdownTracker;
  auto shutdownResult = shutdownTracker.update(100, false, 120, false);
  assert(shutdownResult.action ==
         disconnected_shutdown_policy::Action::CountdownStarted);
  assert(shutdownResult.timeoutSeconds == 600);
  assert(shutdownResult.waitingForRegistration);
  shutdownResult = shutdownTracker.update(600099, false, 120, false);
  assert(shutdownResult.action == disconnected_shutdown_policy::Action::None);
  shutdownResult = shutdownTracker.update(600100, false, 120, false);
  assert(shutdownResult.action ==
         disconnected_shutdown_policy::Action::ShutdownDue);
  shutdownResult = shutdownTracker.update(600101, false, 120, false);
  assert(shutdownResult.action ==
         disconnected_shutdown_policy::Action::ShutdownRetry);

  shutdownResult = shutdownTracker.update(700000, true, 120, false);
  assert(shutdownResult.action == disconnected_shutdown_policy::Action::None);
  shutdownResult = shutdownTracker.update(700001, false, 120, true);
  assert(shutdownResult.action ==
         disconnected_shutdown_policy::Action::CountdownStarted);
  assert(shutdownResult.timeoutSeconds == 120);
  assert(!shutdownResult.waitingForRegistration);
  shutdownResult = shutdownTracker.update(800001, false, 0, true);
  assert(shutdownResult.action == disconnected_shutdown_policy::Action::None);
  shutdownResult = shutdownTracker.update(900001, false, 120, true);
  assert(shutdownResult.action ==
         disconnected_shutdown_policy::Action::CountdownStarted);
  shutdownResult = shutdownTracker.update(950001, false, 300, true);
  assert(shutdownResult.action ==
         disconnected_shutdown_policy::Action::CountdownStarted);
  shutdownResult = shutdownTracker.update(1250001, false, 300, true);
  assert(shutdownResult.action ==
         disconnected_shutdown_policy::Action::ShutdownDue);
  shutdownResult = shutdownTracker.update(1300000, false, 600, false);
  assert(shutdownResult.action ==
         disconnected_shutdown_policy::Action::CountdownStarted);
  shutdownResult = shutdownTracker.update(1400000, false, 600, true);
  assert(shutdownResult.action ==
         disconnected_shutdown_policy::Action::CountdownStarted);
  assert(ble_connection_policy::accepts(
      ble_connection_policy::noConnection, 7));
  assert(ble_connection_policy::accepts(7, 7));
  assert(!ble_connection_policy::accepts(7, 8));
  assert(ble_connection_policy::tearsDownSession(7, 7));
  assert(!ble_connection_policy::tearsDownSession(7, 8));
  uint16_t activeHandle = ble_connection_policy::noConnection;
  int sessionResets = 0;
  assert(ble_connection_policy::beginSession(
      activeHandle, 7, [&] {
        sessionResets++;
        return true;
      }));
  assert(activeHandle == 7 && sessionResets == 1);
  assert(!ble_connection_policy::beginSession(
      activeHandle, 8, [&] {
        sessionResets++;
        return true;
      }));
  assert(activeHandle == 7 && sessionResets == 1);
  assert(!ble_connection_policy::endSession(
      activeHandle, 8, [&] {
        sessionResets++;
        return true;
      }));
  assert(activeHandle == 7 && sessionResets == 1);
  assert(ble_connection_policy::endSession(
      activeHandle, 7, [&] {
        sessionResets++;
        return true;
      }));
  assert(activeHandle == ble_connection_policy::noConnection &&
         sessionResets == 2);
  int bootConfirmations = 0;
  int bootFallbacks = 0;
  assert(ownership_button_policy::handleShortPress(
      [&] {
        bootConfirmations++;
        return true;
      },
      [&] { bootFallbacks++; }));
  assert(bootConfirmations == 1 && bootFallbacks == 0);
  int powerConfirmations = 0;
  int powerFallbacks = 0;
  assert(ownership_button_policy::handleShortPress(
      [&] {
        powerConfirmations++;
        return true;
      },
      [&] { powerFallbacks++; }));
  assert(powerConfirmations == 1 && powerFallbacks == 0);
  assert(!ownership_button_policy::handleShortPress(
      [] { return false; }, [&] { powerFallbacks++; }));
  assert(powerFallbacks == 1);
  assert(!ownership_button_policy::shouldRecoverOwner(7999, false));
  assert(ownership_button_policy::shouldRecoverOwner(8000, false));
  assert(!ownership_button_policy::shouldRecoverOwner(9000, true));

  ownership_button_policy::ComparisonRenderGate renderGate;
  renderGate.request(7);
  assert(renderGate.renderedGeneration() == 0);
  assert(!renderGate.consumeRendered(7));
  renderGate.displayFlushed();
  assert(renderGate.renderedGeneration() == 7);
  assert(!renderGate.consumeRendered(8));
  assert(renderGate.consumeRendered(7));
  assert(renderGate.renderedGeneration() == 0);

  ownership_button_policy::FreshBootButtonGate bootGate;
  bootGate.arm();
  assert(bootGate.blocksInput(true, 100, 50));
  assert(bootGate.blocksInput(false, 110, 50));
  assert(bootGate.blocksInput(false, 159, 50));
  assert(bootGate.blocksInput(false, 160, 50));
  // After the stale press is released and debounced, the very next fresh
  // press passes the gate and can confirm pairing.
  assert(!bootGate.blocksInput(true, 200, 50));

  ownership_button_policy::FreshPowerButtonGate powerGate;
  powerGate.arm(7);
  // Releasing a button held before arming must not confirm pairing.
  assert(!powerGate.acceptEvents(7, false, true, true));
  assert(!powerGate.acceptEvents(8, true, true, true));
  assert(!powerGate.acceptEvents(7, true, false, false));
  assert(powerGate.acceptEvents(7, false, true, true));
  assert(!powerGate.acceptEvents(7, false, true, true));
  assert(powerGate.acceptEvents(7, true, true, true));
  powerGate.arm(8);
  // A complete fresh tap can be reported in one PMU status read.
  assert(powerGate.acceptEvents(8, true, true, true));

  assert(isValidDeviceName("Chris' bike"));
  assert(isValidDeviceName("Chris' \xF0\x9F\x9A\xB2"));
  assert(!isValidDeviceName(std::string("\xC0\xAF", 2)));
  assert(!isValidDeviceName(std::string("\xED\xA0\x80", 3)));
  preferences_test::reset();
  DeviceOwnership device;
  assert(device.begin());
  assert(!device.isClaimed());
  assert(!device.allowsLegacyAuthentication());
  assert(!device.confirmPairingOnDevice());
  const auto unclaimedAdvertisement = device.advertisementManufacturerData();
  assert(unclaimedAdvertisement.size() == 8);
  assert(hexEncode(unclaimedAdvertisement.data(),
                   unclaimedAdvertisement.size()) ==
         sharedFixtureValue("advertisementUnclaimed"));
  const std::string stableId = device.deviceIdHex();
  assert(stableId == sharedFixtureValue("deviceID"));

  AppPairing firstApp(1);
  assert(device.handle("PAIR|bad|bad", 9).response ==
         "ERROR|invalid_pairing_request");
  const auto firstPair = device.handle(firstApp.command(), 10);
  assert(firstPair.event == Event::PairingStarted);
  const uint32_t firstPairingGeneration = device.pairingGeneration();
  assert(firstPairingGeneration != 0);

  // A BOOT/PWR event latched before the comparison is rendered cannot confirm
  // the new pairing generation. Only a fresh post-render press can do so.
  assert(!device.confirmPairingOnDevice());
  assert(!device.armPairingConfirmation(firstPairingGeneration + 1));
  assert(!device.confirmPairingOnDevice());

  AppPairing replacement(2);
  const auto replacementPair = device.handle(replacement.command(), 20);
  assert(replacementPair.response == "ERROR|pairing_attempt_already_used");
  const auto firstMaterial = firstApp.material(firstPair);
  const auto premature =
      device.handle(firstApp.confirm(firstMaterial, "Cargo bike"), 21);
  assert(premature.response == "ERROR|physical_confirmation_required");

  assert(device.armPairingConfirmation(firstPairingGeneration));
  assert(device.confirmPairingOnDevice());
  assert(!device.confirmPairingOnDevice());
  const auto paired =
      device.handle(firstApp.confirm(firstMaterial, "Cargo bike"), 22);
  assert(paired.event == Event::Paired);
  assert(device.isClaimed());
  assert(!device.allowsLegacyAuthentication());
  const auto claimedAdvertisement = device.advertisementManufacturerData();
  assert(hexEncode(claimedAdvertisement.data(),
                   claimedAdvertisement.size()) ==
         sharedFixtureValue("advertisementClaimed"));

  const std::string ownerHex =
      hexEncode(firstApp.ownerId.data(), firstApp.ownerId.size());
  const std::string clientNonce = "00112233445566778899aabbccddeeff";
  const auto server =
      device.handle("OWNER|" + ownerHex + "|" + clientNonce, 30);
  const auto serverParts = split(server.response);
  assert(serverParts.size() == 5 && serverParts[0] == "SERVER2");
  const std::string serverMessage = "server2|" + stableId + "|" + ownerHex +
                                    "|" + clientNonce + "|" + serverParts[3];
  assert(serverParts[4] == proof(firstMaterial.ownerKey, serverMessage));
  const std::string clientMessage = "client2|" + stableId + "|" + ownerHex +
                                    "|" + clientNonce + "|" + serverParts[3];
  const std::string oldProof = "PROOF|" + ownerHex + "|" + clientNonce + "|" +
                               serverParts[3] + "|" +
                               proof(firstMaterial.ownerKey, clientMessage);
  assert(device.handle(oldProof, 31).event == Event::Authenticated);

  device.resetConnection();
  const auto freshServer =
      device.handle("OWNER|" + ownerHex + "|" + clientNonce, 40);
  assert(split(freshServer.response)[3] != serverParts[3]);
  assert(device.handle(oldProof, 41).response == "DENIED|" + stableId);

  DeviceOwnership rebooted;
  assert(rebooted.begin());
  assert(rebooted.deviceIdHex() == stableId);
  assert(rebooted.isClaimed());
  assert(!rebooted.allowsLegacyAuthentication());

  const auto rebootServer =
      rebooted.handle("OWNER|" + ownerHex + "|" + clientNonce, 50);
  const auto rebootServerParts = split(rebootServer.response);
  assert(rebootServerParts.size() == 5);
  const std::string rebootContext =
      stableId + "|" + clientNonce + "|" + rebootServerParts[3];
  const std::string rebootClientMessage =
      "client2|" + stableId + "|" + ownerHex + "|" + clientNonce + "|" +
      rebootServerParts[3];
  assert(rebooted
             .handle("PROOF|" + ownerHex + "|" + clientNonce + "|" +
                         rebootServerParts[3] + "|" +
                         proof(firstMaterial.ownerKey, rebootClientMessage),
                     51)
             .event == Event::Authenticated);
  const OwnerKey rebootWriteKey =
      sessionKey(firstMaterial.ownerKey, "session2-write", rebootContext);
  std::string command;
  assert(rebooted.unwrapAuthenticatedPayload(
      AuthenticatedChannel::Auth,
      writeFrame(rebootWriteKey, AuthenticatedChannel::Auth, 1,
                 "NAME|526f61642062696b65"),
      command));
  const auto renamed = rebooted.handle(command, 52);
  assert(renamed.event == Event::Renamed);
  assert(renamed.response.size() <= 182);

  assert(rebooted.unwrapAuthenticatedPayload(
      AuthenticatedChannel::Auth,
      writeFrame(rebootWriteKey, AuthenticatedChannel::Auth, 2, "GET_NAME"),
      command));
  const auto currentName = rebooted.handle(command, 53);
  assert(currentName.matched && currentName.event == Event::None &&
         currentName.response.size() >= AUTHENTICATED_FRAME_OVERHEAD &&
         currentName.response[0] == 'R' && currentName.response[1] == '2');
  assert(rebooted.deviceName() == "Road bike");

  assert(rebooted.unwrapAuthenticatedPayload(
      AuthenticatedChannel::Auth,
      writeFrame(rebootWriteKey, AuthenticatedChannel::Auth, 3, "UNPAIR"),
      command));
  const auto unpaired = rebooted.handle(command, 54);
  assert(unpaired.event == Event::Unpaired);
  assert(unpaired.response.size() <= 182);
  assert(!rebooted.isClaimed());
  assert(!rebooted.allowsLegacyAuthentication());

  DeviceOwnership afterUnpair;
  assert(afterUnpair.begin());
  const auto receiptInfo = split(afterUnpair.handle("INFO", 55).response);
  assert(receiptInfo.size() == 7 && receiptInfo[3] == "0" &&
         receiptInfo[4].empty());
  assert(receiptInfo[5].size() == 32 && receiptInfo[6].size() == 64);
  const std::string receiptMessage =
      "revoked2|" + stableId + "|" + ownerHex + "|" + receiptInfo[5];
  assert(receiptInfo[6] == proof(firstMaterial.ownerKey, receiptMessage));

  const auto receiptStore = preferences_test::stores;
  const auto assertReceiptSurvives = [&](uint32_t nowMs) {
    DeviceOwnership recovered;
    assert(recovered.begin());
    assert(!recovered.isClaimed());
    const auto recoveredInfo = split(recovered.handle("INFO", nowMs).response);
    assert(recoveredInfo.size() == 7 && recoveredInfo[3] == "0");
    assert(recoveredInfo[5].size() == 32 &&
           recoveredInfo[6] ==
               proof(firstMaterial.ownerKey,
                     "revoked2|" + stableId + "|" + ownerHex + "|" +
                         recoveredInfo[5]));
  };

  // Model reset after the UNPAIR tombstone commits but before owner cleanup.
  // Because the current key signed this receipt, boot must finish revocation
  // before exposing any claimed state to the iPhone.
  preferences_test::stores = receiptStore;
  preferences_test::put("bleOwner", "version", {2});
  preferences_test::put(
      "bleOwner", "ownerId",
      preferences_test::Bytes(firstApp.ownerId.begin(), firstApp.ownerId.end()));
  preferences_test::put(
      "bleOwner", "ownerKey",
      preferences_test::Bytes(firstMaterial.ownerKey.begin(),
                              firstMaterial.ownerKey.end()));
  preferences_test::put("bleOwner", "name", {'C', 'a', 'r', 'g', 'o'});
  const auto interruptedUnpairStore = preferences_test::stores;
  preferences_test::failRemoveKey = "ownerKey";
  DeviceOwnership blockedInterruptedUnpair;
  assert(blockedInterruptedUnpair.begin());
  assert(blockedInterruptedUnpair.isClaimed());
  assert(split(blockedInterruptedUnpair.handle("INFO", 899).response).size() ==
         5);
  assert(!blockedInterruptedUnpair.allowsLegacyAuthentication());
  preferences_test::failRemoveKey.clear();
  preferences_test::stores = interruptedUnpairStore;
  assertReceiptSurvives(900);

  // Every failed owner-record write must roll back without deleting the prior
  // owner's durable deregistration acknowledgement.
  const std::array<const char *, 4> ownerWriteKeys = {
      "ownerId", "ownerKey", "name", "version"};
  for (size_t index = 0; index < ownerWriteKeys.size(); index++) {
    preferences_test::stores = receiptStore;
    preferences_test::failPutKey.clear();
    preferences_test::failRemoveKey.clear();
    DeviceOwnership retry;
    assert(retry.begin());
    AppPairing retryApp(static_cast<uint8_t>(10 + index));
    const auto retryPair = retry.handle(
        retryApp.command(), 1001 + static_cast<uint32_t>(index * 10));
    const auto retryMaterial = retryApp.material(retryPair);
    assert(retry.armPairingConfirmation(retry.pairingGeneration()));
    assert(retry.confirmPairingOnDevice());
    preferences_test::failPutKey = ownerWriteKeys[index];
    assert(retry
               .handle(retryApp.confirm(retryMaterial, "Retry bike"),
                       1002 + static_cast<uint32_t>(index * 10))
               .response == "ERROR|pairing_persistence_failed");
    preferences_test::failPutKey.clear();
    assertReceiptSurvives(1003 + static_cast<uint32_t>(index * 10));
  }

  // Without a transaction marker bound to the replacement credential, a
  // historical receipt cannot distinguish these partial writes from arbitrary
  // corruption of a later owner. Every partial owner record must fail locked.
  for (size_t completedWrites = 1; completedWrites <= 3; completedWrites++) {
    preferences_test::stores = receiptStore;
    preferences_test::put(
        "bleOwner", "ownerId",
        preferences_test::Bytes(firstApp.ownerId.begin(),
                                firstApp.ownerId.end()));
    if (completedWrites >= 2) {
      preferences_test::put(
          "bleOwner", "ownerKey",
          preferences_test::Bytes(firstMaterial.ownerKey.begin(),
                                  firstMaterial.ownerKey.end()));
    }
    if (completedWrites >= 3) {
      preferences_test::put("bleOwner", "name",
                            {'R', 'e', 't', 'r', 'y', ' ', 'b', 'i', 'k', 'e'});
    }
    DeviceOwnership interruptedReplacement;
    assert(interruptedReplacement.begin());
    assert(interruptedReplacement.isClaimed());
    assert(interruptedReplacement
               .handle(firstApp.command(),
                       1100 + static_cast<uint32_t>(completedWrites))
               .response == "OWNED|" + interruptedReplacement.deviceIdHex());
  }

  // A committed replacement owner keeps exposing the prior signed receipt so
  // the old iPhone can converge even when its direct UNPAIRED2 was lost.
  preferences_test::stores = receiptStore;
  preferences_test::failPutKey.clear();
  preferences_test::failRemoveKey.clear();
  DeviceOwnership committedRetry;
  assert(committedRetry.begin());
  AppPairing committedApp(20);
  const auto committedPair = committedRetry.handle(committedApp.command(), 1201);
  const auto committedMaterial = committedApp.material(committedPair);
  assert(committedRetry.armPairingConfirmation(
      committedRetry.pairingGeneration()));
  assert(committedRetry.confirmPairingOnDevice());
  const auto committed = committedRetry.handle(
      committedApp.confirm(committedMaterial, "Committed bike"), 1202);
  assert(committed.event == Event::Paired);
  DeviceOwnership committedReboot;
  assert(committedReboot.begin());
  assert(committedReboot.isClaimed());
  const auto claimedReceipt =
      split(committedReboot.handle("INFO", 1203).response);
  assert(claimedReceipt.size() == 7 && claimedReceipt[3] == "1" &&
         claimedReceipt[4].empty());
  assert(claimedReceipt[6] ==
         proof(firstMaterial.ownerKey,
               "revoked2|" + stableId + "|" + ownerHex + "|" +
                   claimedReceipt[5]));
  const auto committedOwnerStore = preferences_test::stores;
  preferences_test::put("bleOwner", "name", {0xFF});
  DeviceOwnership corruptedReplacement;
  assert(corruptedReplacement.begin());
  assert(corruptedReplacement.isClaimed());
  assert(corruptedReplacement
             .handle(committedApp.command(), 1203)
             .response == "OWNED|" + corruptedReplacement.deviceIdHex());
  preferences_test::stores = committedOwnerStore;
  const auto committedServer = committedReboot.handle(
      "OWNER|" + ownerHex + "|00112233445566778899aabbccddeeff",
      1204);
  const auto committedServerParts = split(committedServer.response);
  assert(committedServerParts.size() == 5 &&
         committedServerParts[0] == "SERVER2");
  const std::string committedClientMessage =
      "client2|" + stableId + "|" + ownerHex +
      "|00112233445566778899aabbccddeeff|" + committedServerParts[3];
  assert(committedReboot
             .handle("PROOF|" + ownerHex +
                         "|00112233445566778899aabbccddeeff|" +
                         committedServerParts[3] + "|" +
                         proof(committedMaterial.ownerKey,
                               committedClientMessage),
                     1205)
             .event == Event::Authenticated);
  const OwnerKey committedWriteKey = sessionKey(
      committedMaterial.ownerKey, "session2-write",
      stableId + "|00112233445566778899aabbccddeeff|" +
          committedServerParts[3]);
  assert(committedReboot.unwrapAuthenticatedPayload(
      AuthenticatedChannel::Auth,
      writeFrame(committedWriteKey, AuthenticatedChannel::Auth, 1, "UNPAIR"),
      command));
  preferences_test::failRemoveKey = "revVersion";
  assert(committedReboot.handle(command, 1206).response ==
         "ERROR|unpair_persistence_failed");
  assert(committedReboot.isClaimed() &&
         committedReboot.isSessionAuthenticated());
  preferences_test::failRemoveKey.clear();

  preferences_test::reset();
  preferences_test::put("bleOwner", "version", {2});
  DeviceOwnership corrupt;
  assert(corrupt.begin());
  assert(corrupt.isClaimed());
  assert(!corrupt.allowsLegacyAuthentication());

  preferences_test::reset();
  preferences_test::failBegin = true;
  DeviceOwnership unavailable;
  assert(!unavailable.begin());
  assert(!unavailable.allowsLegacyAuthentication());

  preferences_test::reset();
  DeviceOwnership expiring;
  assert(expiring.begin());
  const auto expiringPair = expiring.handle(firstApp.command(), 100);
  const auto expiringMaterial = firstApp.material(expiringPair);
  assert(expiring.armPairingConfirmation(expiring.pairingGeneration()));
  assert(expiring.confirmPairingOnDevice());
  expiring.process(100 + PAIRING_SESSION_TIMEOUT_MS + 1);
  assert(expiring.handle(firstApp.confirm(expiringMaterial, "Bike"),
                         100 + PAIRING_SESSION_TIMEOUT_MS + 2)
             .response == "ERROR|pairing_confirmation_failed");
  assert(expiring
             .handle(firstApp.command(),
                     100 + PAIRING_SESSION_TIMEOUT_MS + 3)
             .response == "ERROR|pairing_attempt_already_used");
  expiring.resetConnection();
  assert(expiring
             .handle(firstApp.command(),
                     100 + PAIRING_SESSION_TIMEOUT_MS + 4)
             .event == Event::PairingStarted);

  preferences_test::reset();
  DeviceOwnership persistFailure;
  assert(persistFailure.begin());
  AppPairing failingApp(3);
  const auto failingPair = persistFailure.handle(failingApp.command(), 201);
  const auto failingMaterial = failingApp.material(failingPair);
  assert(persistFailure.armPairingConfirmation(
      persistFailure.pairingGeneration()));
  assert(persistFailure.confirmPairingOnDevice());
  preferences_test::failPutKey = "ownerKey";
  assert(persistFailure
             .handle(failingApp.confirm(failingMaterial, "Bike"), 202)
             .response == "ERROR|pairing_persistence_failed");
  assert(!persistFailure.isClaimed());
  assert(!persistFailure.allowsLegacyAuthentication());

  preferences_test::reset();
  preferences_test::put("bleOwner", "version", {2});
  preferences_test::put(
      "bleOwner", "ownerId",
      preferences_test::Bytes(firstApp.ownerId.begin(), firstApp.ownerId.end()));
  preferences_test::put(
      "bleOwner", "ownerKey",
      preferences_test::Bytes(firstMaterial.ownerKey.begin(),
                              firstMaterial.ownerKey.end()));
  preferences_test::put("bleOwner", "name", {'B', 'i', 'k', 'e'});
  DeviceOwnership missingIdentity;
  assert(missingIdentity.begin());
  assert(missingIdentity.isClaimed());
  assert(!missingIdentity.allowsLegacyAuthentication());
  assert(missingIdentity.handle(
             "OWNER|" + ownerHex + "|" + clientNonce, 205).response ==
         "DENIED|" + missingIdentity.deviceIdHex());
  assert(missingIdentity.clearOwner());
  DeviceOwnership recoveredIdentity;
  assert(recoveredIdentity.begin());
  assert(!recoveredIdentity.isClaimed());
  assert(recoveredIdentity.deviceIdHex() == missingIdentity.deviceIdHex());

  preferences_test::reset();
  DeviceOwnership identitySeed;
  assert(identitySeed.begin());
  preferences_test::put("bleOwner", "version", {2});
  preferences_test::put(
      "bleOwner", "ownerId",
      preferences_test::Bytes(firstApp.ownerId.begin(), firstApp.ownerId.end()));
  preferences_test::put(
      "bleOwner", "ownerKey",
      preferences_test::Bytes(firstMaterial.ownerKey.begin(),
                              firstMaterial.ownerKey.end()));
  preferences_test::put("bleOwner", "name", {'B', 'i', 'k', 'e'});
  const auto deterministicOwnerStore = preferences_test::stores;
  const std::string deterministicIdentity = identitySeed.deviceIdHex();
  preferences_test::put("bleOwner", "deviceId",
                        preferences_test::Bytes(16, 0xA5));
  DeviceOwnership sameLengthCorruptIdentity;
  assert(sameLengthCorruptIdentity.begin());
  assert(sameLengthCorruptIdentity.isClaimed());
  assert(sameLengthCorruptIdentity.deviceIdHex() == deterministicIdentity);
  assert(sameLengthCorruptIdentity
             .handle("OWNER|" + ownerHex + "|" + clientNonce, 209)
             .response == "DENIED|" + deterministicIdentity);
  preferences_test::stores = deterministicOwnerStore;
  DeviceOwnership storageFailure;
  assert(storageFailure.begin() && storageFailure.isClaimed());
  const std::string storageId = storageFailure.deviceIdHex();
  const auto storageServer =
      storageFailure.handle("OWNER|" + ownerHex + "|" + clientNonce, 210);
  const auto storageServerParts = split(storageServer.response);
  const std::string storageClientMessage =
      "client2|" + storageId + "|" + ownerHex + "|" + clientNonce + "|" +
      storageServerParts[3];
  assert(storageFailure
             .handle("PROOF|" + ownerHex + "|" + clientNonce + "|" +
                         storageServerParts[3] + "|" +
                         proof(firstMaterial.ownerKey, storageClientMessage),
                     211)
             .event == Event::Authenticated);
  const OwnerKey storageWriteKey = sessionKey(
      firstMaterial.ownerKey, "session2-write",
      storageId + "|" + clientNonce + "|" + storageServerParts[3]);
  preferences_test::failPutKey = "name";
  assert(storageFailure.unwrapAuthenticatedPayload(
      AuthenticatedChannel::Auth,
      writeFrame(storageWriteKey, AuthenticatedChannel::Auth, 1,
                 "NAME|4e6577206e616d65"),
      command));
  assert(storageFailure.handle(command, 212).response ==
         "ERROR|rename_rejected");
  assert(storageFailure.isSessionAuthenticated());
  preferences_test::failPutKey = "revProof";
  assert(storageFailure.unwrapAuthenticatedPayload(
      AuthenticatedChannel::Auth,
      writeFrame(storageWriteKey, AuthenticatedChannel::Auth, 2, "UNPAIR"),
      command));
  assert(storageFailure.handle(command, 213).response ==
         "ERROR|unpair_persistence_failed");
  assert(storageFailure.isClaimed() &&
         storageFailure.isSessionAuthenticated());
  preferences_test::failPutKey.clear();
  preferences_test::failRemoveKey = "ownerKey";
  assert(storageFailure.unwrapAuthenticatedPayload(
      AuthenticatedChannel::Auth,
      writeFrame(storageWriteKey, AuthenticatedChannel::Auth, 3, "UNPAIR"),
      command));
  assert(storageFailure.handle(command, 214).response ==
         "ERROR|unpair_persistence_failed");
  assert(storageFailure.isClaimed());
  assert(!storageFailure.isSessionAuthenticated());
  assert(!storageFailure.allowsLegacyAuthentication());

  const OwnerKey goldenWriteKey = keyFromHex(
      "fc52403d7ec42e7b3b7ecf64e6e496655930b1d175249e3447c670f59147304d");
  const OwnerKey goldenNotifyKey = keyFromHex(
      "54a70b224da51f29d318ddaa4e9d3cddb5b5fde0ee1a9da5361debc26f7bdc06");
  const std::string goldenWriteFrame = binary(
      "533200000001c486d6a2464da1600aab2af46a3ae0e00442af910dcdc23c8164d0336842cfaa426b31");
  const std::string goldenNotifyFrame = binary(
      "523200000001f19f6c8cd9263269e34a54aa910f37738270d42cb7d8632c8f0e20bfa6a4588d369304ab9662");

  DeviceOwnership wire;
  wire.setAuthenticatedSessionKeysForTesting(goldenWriteKey, goldenNotifyKey);
  std::string plaintext;
  assert(wire.unwrapAuthenticatedPayload(AuthenticatedChannel::Auth,
                                         goldenWriteFrame, plaintext));
  assert(plaintext == "NAME|4d792062696b65");
  assert(!wire.unwrapAuthenticatedPayload(AuthenticatedChannel::Auth,
                                          goldenWriteFrame, plaintext));

  DeviceOwnership tamperedWire;
  tamperedWire.setAuthenticatedSessionKeysForTesting(goldenWriteKey,
                                                      goldenNotifyKey);
  std::string tampered = goldenWriteFrame;
  tampered.back() ^= 0x01;
  assert(!tamperedWire.unwrapAuthenticatedPayload(AuthenticatedChannel::Auth,
                                                  tampered, plaintext));
  assert(tamperedWire.unwrapAuthenticatedPayload(AuthenticatedChannel::Auth,
                                                  goldenWriteFrame,
                                                  plaintext));

  DeviceOwnership wrongChannel;
  wrongChannel.setAuthenticatedSessionKeysForTesting(goldenWriteKey,
                                                      goldenNotifyKey);
  assert(!wrongChannel.unwrapAuthenticatedPayload(AuthenticatedChannel::Route,
                                                   goldenWriteFrame,
                                                   plaintext));

  DeviceOwnership emptyRoute;
  emptyRoute.setAuthenticatedSessionKeysForTesting(goldenWriteKey,
                                                   goldenNotifyKey);
  assert(emptyRoute.unwrapAuthenticatedPayload(
      AuthenticatedChannel::Route,
      binary("533200000001c981669fdeb1b029019459478ef19ff6"),
      plaintext));
  assert(plaintext.empty());

  DeviceOwnership notifier;
  notifier.setAuthenticatedSessionKeysForTesting(goldenWriteKey,
                                                  goldenNotifyKey);
  std::string notification;
  assert(notifier.protectAuthenticatedPayload(
      AuthenticatedChannel::Auth, "NAME_OK|4d792062696b65", notification));
  assert(notification == goldenNotifyFrame);

  DeviceOwnership navigationNotifier;
  navigationNotifier.setAuthenticatedSessionKeysForTesting(goldenWriteKey,
                                                            goldenNotifyKey);
  const std::string destinationRequest("DREQ\x01\x00\x00\x00\x02\x00", 10);
  assert(navigationNotifier.protectAuthenticatedPayload(
      AuthenticatedChannel::Navigation, destinationRequest, notification));
  assert(notification == binary(
      "523200000001a0d24a5355c7de1683c4a586dd2fb19a8c19b6a6c0afe3b4f62e"));

  std::cout << "device ownership state tests passed\n";
  return 0;
}
