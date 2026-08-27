#pragma once

#include <Arduino.h>
#include <WiFi.h>

#include <cstddef>
#include <cstdint>
#include <string>

struct esp_tls;

namespace device_transfer {

constexpr uint32_t TLS_IDENTITY_SCHEMA_VERSION = 1;
constexpr size_t TLS_CERTIFICATE_SHA256_HEX_BYTES = 64;

bool validTlsCertificateSha256(const std::string &value);

struct TransferTlsIdentity {
  std::string certificatePem;
  std::string privateKeyPem;
  std::string certificateSha256;
  uint32_t version = 0;

  bool valid() const;
};

// Owns a versioned, device-local transfer identity. A first boot creates one
// identity. Once an identity record exists, corruption fails closed instead of
// silently replacing the certificate that an authenticated app has pinned.
// Rotation is two phase: prepare writes the inactive slot and commit switches
// it only after the caller names the exact pending fingerprint.
class TransferTlsIdentityStore {
public:
  bool begin();
  const TransferTlsIdentity &active() const { return active_; }
  const TransferTlsIdentity &pending() const { return pending_; }
  bool prepareRotation();
  bool commitRotation(const std::string &expectedCertificateSha256);
  bool cancelRotation();
  const std::string &lastError() const { return lastError_; }

private:
  TransferTlsIdentity active_;
  TransferTlsIdentity pending_;
  uint8_t activeSlot_ = 0;
  bool initialized_ = false;
  std::string lastError_;

  bool load();
  bool generate(uint32_t version, TransferTlsIdentity &identity);
  bool persistSlot(uint8_t slot, const TransferTlsIdentity &identity);
  bool clearSlot(uint8_t slot);
};

// Small TLS stream adapter around an accepted Arduino socket. begin() takes
// ownership of the socket handle and clears the caller's plaintext wrapper
// before handshaking. Every device transfer handler consumes this type, so
// plaintext clients never reach HTTP parsing or authorization-token handling.
class TransferClient {
public:
  TransferClient() = default;
  TransferClient(const TransferClient &) = delete;
  TransferClient &operator=(const TransferClient &) = delete;
  ~TransferClient();

  bool begin(WiFiClient &accepted, const TransferTlsIdentity &identity,
             uint32_t handshakeTimeoutMs = 5000);
  int available();
  int read();
  int read(uint8_t *buffer, size_t length);
  size_t write(const uint8_t *buffer, size_t length);
  uint8_t connected();
  int fd() const { return socket_; }
  bool finishResponse(uint32_t timeoutMs);
  void stop();
  explicit operator bool() { return connected() != 0; }

private:
  WiFiClient socketOwner_;
  esp_tls *tls_ = nullptr;
  int socket_ = -1;
  bool connected_ = false;
};

} // namespace device_transfer
