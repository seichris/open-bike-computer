#include "usb_recovery_status.hpp"

#if USB_RECOVERY_STATUS
#if FIRMWARE_DIAGNOSTICS || ARDUINO_USB_CDC_ON_BOOT
#error "USB recovery status requires quiet production-style serial configuration"
#endif

#include "request.hpp"
#include "../boot_diagnostics/boot_diagnostics.hpp"
#include "../firmware_metadata/firmware_metadata.hpp"
#include <Arduino.h>
#include <HWCDC.h>
#include <esp_flash.h>
#include <esp_mac.h>
#include <esp_ota_ops.h>
#include <mbedtls/sha256.h>
#include <cstdio>

namespace usb_recovery_status {
namespace {
// A dedicated HWCDC instance keeps Serial/UART logging separate. Do not set
// ARDUINO_USB_CDC_ON_BOOT=1 or enable stdout forwarding in this profile.
HWCDC statusPort;
Request request;
uint32_t lastReply = 0;
bool replied = false;
}

void begin() {
  statusPort.setRxBufferSize(128);
  statusPort.setTxBufferSize(768);
  statusPort.setTxTimeoutMs(1);
  statusPort.begin(115200);
}

void process() {
  // Bound per-loop work, response rate and response size even under hostile USB
  // input. No status is emitted until an explicit, well-formed nonce request.
  for (unsigned count = 0; count < 64 && statusPort.available(); ++count) {
    const uint32_t now = millis();
    if (!request.feed(static_cast<char>(statusPort.read()), now)) continue;
    if (replied && static_cast<uint32_t>(now - lastReply) < 1000) continue;
    replied = true;
    lastReply = now;
    uint8_t table[3072];
    uint8_t digest[32];
    char tableHash[65]{};
    if (esp_flash_read(nullptr, table, 0x8000, sizeof(table)) != ESP_OK ||
        mbedtls_sha256(table, sizeof(table), digest, 0) != 0) continue;
    for (unsigned index = 0; index < sizeof(digest); ++index)
      std::snprintf(tableHash + index * 2, 3, "%02x", digest[index]);
    const auto boot = boot_diagnostics::snapshot();
    const esp_partition_t *running = esp_ota_get_running_partition();
    uint8_t mac[6];
    if (esp_efuse_mac_get_default(mac) != ESP_OK) continue;
    char chipId[18];
    std::snprintf(chipId, sizeof(chipId), "%02x:%02x:%02x:%02x:%02x:%02x",
                  mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    char response[768];
    const int length = std::snprintf(
        response, sizeof(response),
        "{\"type\":\"bicino-usb-status\",\"schemaVersion\":1,\"nonce\":\"%s\","
        "\"target\":\"%s\",\"profile\":\"%s\",\"version\":\"%s\",\"build\":%lu,"
        "\"gitSha\":\"%s\",\"partitionTableSha256\":\"%s\",\"bootSequence\":%lu,"
        "\"appOffset\":%lu,\"chipId\":\"%s\",\"ready\":%s}\n",
        request.nonce(), firmware_metadata::target(), firmware_metadata::buildProfile(),
        firmware_metadata::version(), static_cast<unsigned long>(firmware_metadata::build()),
        firmware_metadata::gitSha(), tableHash, static_cast<unsigned long>(boot.bootSequence),
        static_cast<unsigned long>(running ? running->address : 0),
        chipId,
        boot.ready && !boot.safeMode && !boot.diagnosticHold ? "true" : "false");
    if (length > 0 && static_cast<std::size_t>(length) < sizeof(response) &&
        statusPort.availableForWrite() >= length)
      statusPort.write(reinterpret_cast<const uint8_t *>(response), length);
  }
}
} // namespace usb_recovery_status
#endif
