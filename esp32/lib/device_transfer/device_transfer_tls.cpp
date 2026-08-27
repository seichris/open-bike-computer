#include "device_transfer_tls.hpp"

#include <Preferences.h>
#include <esp_system.h>
#include <esp_tls.h>
#include <fcntl.h>
#include <mbedtls/ecp.h>
#include <mbedtls/error.h>
#include <mbedtls/pk.h>
#include <mbedtls/sha256.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <climits>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

namespace device_transfer {
namespace {

constexpr char kNamespace[] = "transferTls";
constexpr char kSelectorKey[] = "selector";
constexpr char kSlotAVersionKey[] = "aVer";
constexpr char kSlotACertificateKey[] = "aCert";
constexpr char kSlotAPrivateKeyKey[] = "aKey";
constexpr char kSlotAFingerprintKey[] = "aSha";
constexpr char kSlotBVersionKey[] = "bVer";
constexpr char kSlotBCertificateKey[] = "bCert";
constexpr char kSlotBPrivateKeyKey[] = "bKey";
constexpr char kSlotBFingerprintKey[] = "bSha";
constexpr size_t kMaximumCertificatePemBytes = 2048;
constexpr size_t kMaximumPrivateKeyPemBytes = 768;

uint16_t encodeSelector(uint8_t activeSlot) {
  return static_cast<uint16_t>(TLS_IDENTITY_SCHEMA_VERSION << 8) |
         activeSlot;
}

const char *versionKey(uint8_t slot) {
  return slot == 0 ? kSlotAVersionKey : kSlotBVersionKey;
}

const char *certificateKey(uint8_t slot) {
  return slot == 0 ? kSlotACertificateKey : kSlotBCertificateKey;
}

const char *privateKeyKey(uint8_t slot) {
  return slot == 0 ? kSlotAPrivateKeyKey : kSlotBPrivateKeyKey;
}

const char *fingerprintKey(uint8_t slot) {
  return slot == 0 ? kSlotAFingerprintKey : kSlotBFingerprintKey;
}

int fillRandom(void *, unsigned char *output, size_t length) {
  if (output == nullptr)
    return -1;
  esp_fill_random(output, length);
  return 0;
}

std::string hexEncode(const uint8_t *data, size_t length) {
  static constexpr char kDigits[] = "0123456789abcdef";
  if (data == nullptr)
    return "";
  std::string encoded(length * 2, '0');
  for (size_t index = 0; index < length; ++index) {
    encoded[index * 2] = kDigits[(data[index] >> 4) & 0x0f];
    encoded[index * 2 + 1] = kDigits[data[index] & 0x0f];
  }
  return encoded;
}

bool certificateFingerprint(const std::string &certificatePem,
                            std::string &fingerprint) {
  fingerprint.clear();
  if (certificatePem.empty() || certificatePem.back() != '\0')
    return false;
  mbedtls_x509_crt certificate;
  mbedtls_x509_crt_init(&certificate);
  const int parsed = mbedtls_x509_crt_parse(
      &certificate,
      reinterpret_cast<const unsigned char *>(certificatePem.data()),
      certificatePem.size());
  std::array<uint8_t, 32> digest{};
  const bool valid = parsed == 0 && certificate.raw.p != nullptr &&
                     certificate.raw.len > 0 &&
                     mbedtls_sha256_ret(certificate.raw.p,
                                        certificate.raw.len, digest.data(),
                                        0) == 0;
  mbedtls_x509_crt_free(&certificate);
  if (valid)
    fingerprint = hexEncode(digest.data(), digest.size());
  return valid;
}

bool keyMatchesCertificate(const TransferTlsIdentity &identity) {
  mbedtls_x509_crt certificate;
  mbedtls_pk_context key;
  mbedtls_x509_crt_init(&certificate);
  mbedtls_pk_init(&key);
  const int certificateResult = mbedtls_x509_crt_parse(
      &certificate,
      reinterpret_cast<const unsigned char *>(identity.certificatePem.data()),
      identity.certificatePem.size());
  const int keyResult = mbedtls_pk_parse_key(
      &key,
      reinterpret_cast<const unsigned char *>(identity.privateKeyPem.data()),
      identity.privateKeyPem.size(), nullptr, 0, fillRandom, nullptr);
  const bool matches =
      certificateResult == 0 && keyResult == 0 &&
      mbedtls_pk_check_pair(&certificate.pk, &key, fillRandom, nullptr) == 0;
  mbedtls_pk_free(&key);
  mbedtls_x509_crt_free(&certificate);
  return matches;
}

bool readBoundedBlob(Preferences &preferences, const char *key,
                     size_t maximumBytes, std::string &value) {
  value.clear();
  const size_t length = preferences.getBytesLength(key);
  if (length == 0 || length > maximumBytes)
    return false;
  value.resize(length);
  if (preferences.getBytes(key, value.data(), length) != length) {
    value.clear();
    return false;
  }
  return value.back() == '\0';
}

bool loadSlot(Preferences &preferences, uint8_t slot,
              TransferTlsIdentity &identity) {
  identity = {};
  identity.version = preferences.getUInt(versionKey(slot), 0);
  if (identity.version == 0 ||
      !readBoundedBlob(preferences, certificateKey(slot),
                       kMaximumCertificatePemBytes,
                       identity.certificatePem) ||
      !readBoundedBlob(preferences, privateKeyKey(slot),
                       kMaximumPrivateKeyPemBytes,
                       identity.privateKeyPem)) {
    identity = {};
    return false;
  }
  identity.certificateSha256 =
      preferences.getString(fingerprintKey(slot), "").c_str();
  return identity.valid();
}

bool namespaceContainsIdentityState(Preferences &preferences) {
  return preferences.isKey(kSelectorKey) ||
         preferences.isKey(kSlotAVersionKey) ||
         preferences.isKey(kSlotACertificateKey) ||
         preferences.isKey(kSlotAPrivateKeyKey) ||
         preferences.isKey(kSlotAFingerprintKey) ||
         preferences.isKey(kSlotBVersionKey) ||
         preferences.isKey(kSlotBCertificateKey) ||
         preferences.isKey(kSlotBPrivateKeyKey) ||
         preferences.isKey(kSlotBFingerprintKey);
}

} // namespace

bool validTlsCertificateSha256(const std::string &value) {
  return value.size() == TLS_CERTIFICATE_SHA256_HEX_BYTES &&
         std::all_of(value.begin(), value.end(), [](unsigned char character) {
           return (character >= '0' && character <= '9') ||
                  (character >= 'a' && character <= 'f');
         });
}

bool TransferTlsIdentity::valid() const {
  if (version == 0 || certificatePem.empty() || privateKeyPem.empty() ||
      certificatePem.back() != '\0' || privateKeyPem.back() != '\0' ||
      !validTlsCertificateSha256(certificateSha256)) {
    return false;
  }
  std::string actualFingerprint;
  return certificateFingerprint(certificatePem, actualFingerprint) &&
         actualFingerprint == certificateSha256 &&
         keyMatchesCertificate(*this);
}

bool TransferTlsIdentityStore::begin() {
  if (initialized_)
    return active_.valid();
  initialized_ = true;
  return load();
}

bool TransferTlsIdentityStore::load() {
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) {
    lastError_ = "tls_identity_storage";
    return false;
  }
  const bool hasState = namespaceContainsIdentityState(preferences);
  const uint16_t selector = preferences.getUShort(kSelectorKey, 0xffff);
  const uint8_t schema = static_cast<uint8_t>(selector >> 8);
  const uint8_t selected = static_cast<uint8_t>(selector & 0xff);
  TransferTlsIdentity slots[2];
  const bool validSlots[2] = {loadSlot(preferences, 0, slots[0]),
                              loadSlot(preferences, 1, slots[1])};

  if (!hasState) {
    preferences.end();
    TransferTlsIdentity generated;
    if (!generate(1, generated) || !persistSlot(0, generated)) {
      lastError_ = "tls_identity_create";
      return false;
    }
    if (!preferences.begin(kNamespace, false)) {
      lastError_ = "tls_identity_storage";
      return false;
    }
    const bool selectedWritten =
        preferences.putUShort(kSelectorKey, encodeSelector(0)) == 2;
    preferences.end();
    if (!selectedWritten) {
      lastError_ = "tls_identity_commit";
      return false;
    }
    active_ = std::move(generated);
    activeSlot_ = 0;
    pending_ = {};
    lastError_.clear();
    return true;
  }

  // A first-boot power cut can leave a complete slot before the atomic selector
  // is published. Recover only that exact state; any selected or
  // partially initialized namespace still fails closed so a previously pinned
  // identity is never silently replaced.
  if (selector == 0xffff && validSlots[0] && !validSlots[1]) {
    const bool selectedWritten =
        preferences.putUShort(kSelectorKey, encodeSelector(0)) == 2;
    preferences.end();
    if (!selectedWritten) {
      lastError_ = "tls_identity_commit";
      return false;
    }
    active_ = std::move(slots[0]);
    activeSlot_ = 0;
    pending_ = {};
    lastError_.clear();
    return true;
  }

  if (schema != TLS_IDENTITY_SCHEMA_VERSION || selected > 1 ||
      !validSlots[selected]) {
    preferences.end();
    lastError_ = "tls_identity_invalid";
    return false;
  }
  activeSlot_ = selected;
  active_ = std::move(slots[selected]);
  const uint8_t inactive = selected ^ 1U;
  if (validSlots[inactive] && slots[inactive].version > active_.version)
    pending_ = std::move(slots[inactive]);
  preferences.end();
  lastError_.clear();
  return true;
}

bool TransferTlsIdentityStore::generate(uint32_t version,
                                        TransferTlsIdentity &identity) {
  identity = {};
  if (version == 0)
    return false;
  mbedtls_pk_context key;
  mbedtls_x509write_cert certificate;
  mbedtls_pk_init(&key);
  mbedtls_x509write_crt_init(&certificate);
  std::array<uint8_t, 16> serial{};
  esp_fill_random(serial.data(), serial.size());
  serial[0] &= 0x7f;
  serial[0] |= 0x01;

  bool generated = false;
  do {
    const mbedtls_pk_info_t *keyInfo =
        mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY);
    if (keyInfo == nullptr || mbedtls_pk_setup(&key, keyInfo) != 0 ||
        mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(key),
                            fillRandom, nullptr) != 0) {
      break;
    }
    const std::string distinguishedName =
        "CN=BikeComputer Transfer v" + std::to_string(version);
    mbedtls_x509write_crt_set_version(&certificate,
                                      MBEDTLS_X509_CRT_VERSION_3);
    mbedtls_x509write_crt_set_md_alg(&certificate, MBEDTLS_MD_SHA256);
    mbedtls_x509write_crt_set_subject_key(&certificate, &key);
    mbedtls_x509write_crt_set_issuer_key(&certificate, &key);
    if (mbedtls_x509write_crt_set_subject_name(
            &certificate, distinguishedName.c_str()) != 0 ||
        mbedtls_x509write_crt_set_issuer_name(
            &certificate, distinguishedName.c_str()) != 0 ||
        mbedtls_x509write_crt_set_serial_raw(&certificate, serial.data(),
                                             serial.size()) != 0 ||
        mbedtls_x509write_crt_set_validity(&certificate, "20260101000000",
                                           "20491231235959") != 0 ||
        mbedtls_x509write_crt_set_basic_constraints(&certificate, 0, -1) !=
            0 ||
        mbedtls_x509write_crt_set_key_usage(
            &certificate, MBEDTLS_X509_KU_DIGITAL_SIGNATURE |
                              MBEDTLS_X509_KU_KEY_AGREEMENT) != 0) {
      break;
    }
    std::array<unsigned char, kMaximumPrivateKeyPemBytes> keyPem{};
    std::array<unsigned char, kMaximumCertificatePemBytes> certificatePem{};
    if (mbedtls_pk_write_key_pem(&key, keyPem.data(), keyPem.size()) != 0 ||
        mbedtls_x509write_crt_pem(&certificate, certificatePem.data(),
                                  certificatePem.size(), fillRandom,
                                  nullptr) != 0) {
      break;
    }
    identity.privateKeyPem.assign(
        reinterpret_cast<const char *>(keyPem.data()),
        std::strlen(reinterpret_cast<const char *>(keyPem.data())) + 1);
    identity.certificatePem.assign(
        reinterpret_cast<const char *>(certificatePem.data()),
        std::strlen(reinterpret_cast<const char *>(certificatePem.data())) +
            1);
    identity.version = version;
    if (!certificateFingerprint(identity.certificatePem,
                                identity.certificateSha256) ||
        !identity.valid()) {
      identity = {};
      break;
    }
    generated = true;
  } while (false);

  mbedtls_x509write_crt_free(&certificate);
  mbedtls_pk_free(&key);
  return generated;
}

bool TransferTlsIdentityStore::persistSlot(
    uint8_t slot, const TransferTlsIdentity &identity) {
  if (slot > 1 || !identity.valid())
    return false;
  Preferences preferences;
  if (!preferences.begin(kNamespace, false))
    return false;
  // Publish the version last so a power cut cannot make a partial slot valid.
  preferences.remove(versionKey(slot));
  const bool written =
      preferences.putBytes(certificateKey(slot), identity.certificatePem.data(),
                           identity.certificatePem.size()) ==
          identity.certificatePem.size() &&
      preferences.putBytes(privateKeyKey(slot), identity.privateKeyPem.data(),
                           identity.privateKeyPem.size()) ==
          identity.privateKeyPem.size() &&
      preferences.putString(fingerprintKey(slot),
                            identity.certificateSha256.c_str()) ==
          identity.certificateSha256.size() &&
      preferences.putUInt(versionKey(slot), identity.version) == 4;
  preferences.end();
  return written;
}

bool TransferTlsIdentityStore::clearSlot(uint8_t slot) {
  if (slot > 1)
    return false;
  Preferences preferences;
  if (!preferences.begin(kNamespace, false))
    return false;
  const bool hadVersion = preferences.isKey(versionKey(slot));
  const bool hadCertificate = preferences.isKey(certificateKey(slot));
  const bool hadPrivateKey = preferences.isKey(privateKeyKey(slot));
  const bool hadFingerprint = preferences.isKey(fingerprintKey(slot));
  const bool versionCleared =
      !hadVersion || preferences.remove(versionKey(slot));
  const bool certificateCleared =
      !hadCertificate || preferences.remove(certificateKey(slot));
  const bool privateKeyCleared =
      !hadPrivateKey || preferences.remove(privateKeyKey(slot));
  const bool fingerprintCleared =
      !hadFingerprint || preferences.remove(fingerprintKey(slot));
  preferences.end();
  return versionCleared && certificateCleared && privateKeyCleared &&
         fingerprintCleared;
}

bool TransferTlsIdentityStore::prepareRotation() {
  if (!initialized_ || !active_.valid() || pending_.valid() ||
      active_.version == std::numeric_limits<uint32_t>::max()) {
    lastError_ = "tls_rotation_state";
    return false;
  }
  TransferTlsIdentity candidate;
  const uint8_t inactive = activeSlot_ ^ 1U;
  if (!generate(active_.version + 1, candidate) ||
      !persistSlot(inactive, candidate)) {
    lastError_ = "tls_rotation_prepare";
    return false;
  }
  pending_ = std::move(candidate);
  lastError_.clear();
  return true;
}

bool TransferTlsIdentityStore::commitRotation(
    const std::string &expectedCertificateSha256) {
  if (!pending_.valid() ||
      expectedCertificateSha256 != pending_.certificateSha256) {
    lastError_ = "tls_rotation_fingerprint";
    return false;
  }
  const uint8_t nextSlot = activeSlot_ ^ 1U;
  Preferences preferences;
  if (!preferences.begin(kNamespace, false)) {
    lastError_ = "tls_identity_storage";
    return false;
  }
  const bool committed =
      preferences.putUShort(kSelectorKey, encodeSelector(nextSlot)) == 2;
  preferences.end();
  if (!committed) {
    lastError_ = "tls_rotation_commit";
    return false;
  }
  const uint8_t oldSlot = activeSlot_;
  activeSlot_ = nextSlot;
  active_ = std::move(pending_);
  pending_ = {};
  if (!clearSlot(oldSlot)) {
    // The selected identity is already durable. Retaining an inactive old slot
    // is safe and lets a later maintenance pass clean it without rollback.
    lastError_ = "tls_rotation_cleanup";
    return true;
  }
  lastError_.clear();
  return true;
}

bool TransferTlsIdentityStore::cancelRotation() {
  if (!pending_.valid()) {
    lastError_.clear();
    return true;
  }
  const uint8_t inactive = activeSlot_ ^ 1U;
  if (!clearSlot(inactive)) {
    lastError_ = "tls_rotation_cleanup";
    return false;
  }
  pending_ = {};
  lastError_.clear();
  return true;
}

TransferClient::~TransferClient() { stop(); }

bool TransferClient::begin(WiFiClient &accepted,
                           const TransferTlsIdentity &identity,
                           uint32_t handshakeTimeoutMs) {
  stop();
  if (!identity.valid() || accepted.fd() < 0)
    return false;
  socket_ = ::dup(accepted.fd());
  accepted.stop();
  if (socket_ < 0)
    return false;
  const int flags = ::fcntl(socket_, F_GETFL, 0);
  if (flags >= 0)
    ::fcntl(socket_, F_SETFL, flags & ~O_NONBLOCK);
  timeval timeout = {
      static_cast<time_t>(handshakeTimeoutMs / 1000),
      static_cast<suseconds_t>((handshakeTimeoutMs % 1000) * 1000)};
  ::setsockopt(socket_, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  ::setsockopt(socket_, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

  tls_ = esp_tls_init();
  if (tls_ == nullptr) {
    ::close(socket_);
    socket_ = -1;
    return false;
  }
  esp_tls_cfg_server_t configuration{};
  configuration.servercert_buf = reinterpret_cast<const unsigned char *>(
      identity.certificatePem.data());
  configuration.servercert_bytes = identity.certificatePem.size();
  configuration.serverkey_buf = reinterpret_cast<const unsigned char *>(
      identity.privateKeyPem.data());
  configuration.serverkey_bytes = identity.privateKeyPem.size();
  configuration.tls_handshake_timeout_ms = handshakeTimeoutMs;
  if (esp_tls_server_session_create(&configuration, socket_, tls_) != 0) {
    const int failedSocket = socket_;
    esp_tls_server_session_delete(tls_);
    tls_ = nullptr;
    socket_ = -1;
    ::close(failedSocket);
    return false;
  }
  connected_ = true;
  return true;
}

int TransferClient::available() {
  if (!connected_ || tls_ == nullptr)
    return 0;
  const ssize_t buffered = esp_tls_get_bytes_avail(tls_);
  if (buffered > 0)
    return buffered > INT_MAX ? INT_MAX : static_cast<int>(buffered);
  pollfd descriptor{socket_, POLLIN, 0};
  const int ready = ::poll(&descriptor, 1, 0);
  if (ready > 0 && (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL))) {
    connected_ = false;
    return 0;
  }
  return ready > 0 && (descriptor.revents & POLLIN) ? 1 : 0;
}

int TransferClient::read() {
  uint8_t byte = 0;
  return read(&byte, 1) == 1 ? byte : -1;
}

int TransferClient::read(uint8_t *buffer, size_t length) {
  if (!connected_ || tls_ == nullptr || buffer == nullptr || length == 0)
    return 0;
  const ssize_t result = esp_tls_conn_read(tls_, buffer, length);
  if (result > 0)
    return result > INT_MAX ? INT_MAX : static_cast<int>(result);
  if (result == 0) {
    connected_ = false;
    return 0;
  }
  if (result == ESP_TLS_ERR_SSL_WANT_READ ||
      result == ESP_TLS_ERR_SSL_WANT_WRITE) {
    return 0;
  }
  connected_ = false;
  return -1;
}

size_t TransferClient::write(const uint8_t *buffer, size_t length) {
  if (!connected_ || tls_ == nullptr || (buffer == nullptr && length != 0))
    return 0;
  const ssize_t result = esp_tls_conn_write(tls_, buffer, length);
  if (result > 0)
    return static_cast<size_t>(result);
  if (result != ESP_TLS_ERR_SSL_WANT_READ &&
      result != ESP_TLS_ERR_SSL_WANT_WRITE) {
    connected_ = false;
  }
  return 0;
}

uint8_t TransferClient::connected() {
  if (!connected_ || tls_ == nullptr || socket_ < 0)
    return 0;
  pollfd descriptor{socket_, POLLIN, 0};
  if (::poll(&descriptor, 1, 0) > 0 &&
      (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL))) {
    connected_ = false;
  }
  return connected_ ? 1 : 0;
}

bool TransferClient::finishResponse(uint32_t timeoutMs) {
  if (!connected_ || tls_ == nullptr)
    return false;
  auto *context = static_cast<mbedtls_ssl_context *>(
      esp_tls_get_ssl_context(tls_));
  if (context == nullptr)
    return false;
  timeval timeout = {
      static_cast<time_t>(timeoutMs / 1000),
      static_cast<suseconds_t>((timeoutMs % 1000) * 1000)};
  ::setsockopt(socket_, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  ::setsockopt(socket_, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
  const uint32_t started = millis();
  int result = MBEDTLS_ERR_SSL_WANT_WRITE;
  while (millis() - started < timeoutMs) {
    result = mbedtls_ssl_close_notify(context);
    if (result == 0)
      break;
    if (result != MBEDTLS_ERR_SSL_WANT_READ &&
        result != MBEDTLS_ERR_SSL_WANT_WRITE)
      return false;
    vTaskDelay(pdMS_TO_TICKS(2));
  }
  if (result != 0)
    return false;

  // Connection: close is also the commit boundary for activation handlers.
  // Wait for the peer's TLS close-notify instead of treating a successful
  // socket write as proof that the authenticated client consumed the response.
  uint8_t byte = 0;
  while (millis() - started < timeoutMs) {
    const uint32_t remaining = timeoutMs - (millis() - started);
    pollfd descriptor{socket_, POLLIN, 0};
    const int ready = ::poll(
        &descriptor, 1,
        static_cast<int>(std::min<uint32_t>(remaining, 20)));
    if (ready < 0 ||
        (ready > 0 &&
         (descriptor.revents & (POLLERR | POLLNVAL)))) {
      return false;
    }
    if (ready == 0)
      continue;
    result = esp_tls_conn_read(tls_, &byte, sizeof(byte));
    if (result == 0)
      return true;
    if (result != ESP_TLS_ERR_SSL_WANT_READ &&
        result != ESP_TLS_ERR_SSL_WANT_WRITE && result < 0) {
      return false;
    }
    vTaskDelay(pdMS_TO_TICKS(2));
  }
  return false;
}

void TransferClient::stop() {
  connected_ = false;
  if (tls_ != nullptr) {
    const int activeSocket = socket_;
    esp_tls_server_session_delete(tls_);
    tls_ = nullptr;
    socket_ = -1;
    if (activeSocket >= 0)
      ::close(activeSocket);
    return;
  }
  if (socket_ >= 0)
    ::close(socket_);
  socket_ = -1;
}

} // namespace device_transfer
