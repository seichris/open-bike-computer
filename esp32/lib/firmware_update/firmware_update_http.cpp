#include "firmware_update_http.hpp"
#include "firmware_update_policy.hpp"

#include "../firmware_maintenance/firmware_maintenance.hpp"
#include "../firmware_metadata/firmware_metadata.hpp"
#include "../status_json/status_json.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <esp_app_format.h>
#include <esp_ota_ops.h>
#include <mbedtls/base64.h>
#include <mbedtls/md.h>
#include <mbedtls/pk.h>
#include <mbedtls/sha256.h>
#include <sstream>
#include <vector>

namespace firmware_update {
namespace {

static constexpr const char *kStatusPath = "/firmware-update/status";
static constexpr const char *kBeginPath = "/firmware-update/begin";
static constexpr const char *kImagePath = "/firmware-update/image";
static constexpr const char *kFinalizePath = "/firmware-update/finalize";
static constexpr const char *kCancelPath = "/firmware-update/cancel";
static constexpr uint64_t kMaxBeginBodyBytes = 2048;
static constexpr const char *kManifestSigningPublicKeyPem =
    "-----BEGIN PUBLIC KEY-----\n"
    "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEtohCWc591a7u6+lRHZX82FuT3ab3\n"
    "kEv4w/ai84IAaR/g3R4OEw0fhxOIPyDqqbQiACLb/F7Sw04y8IwZjA+UKw==\n"
    "-----END PUBLIC KEY-----\n";

static bool startsWith(const std::string &value, const std::string &prefix) {
  return value.size() >= prefix.size() &&
         value.compare(0, prefix.size(), prefix) == 0;
}

static bool isHexSha256(const std::string &value) {
  if (value.size() != 64)
    return false;
  for (char c : value) {
    if (!std::isxdigit(static_cast<unsigned char>(c)))
      return false;
  }
  return true;
}

static void skipSpaces(const std::string &body, size_t &index) {
  while (index < body.size() &&
         std::isspace(static_cast<unsigned char>(body[index]))) {
    index++;
  }
}

static bool findJsonValueStart(const std::string &body, const char *field,
                               size_t &index) {
  const std::string key = std::string("\"") + field + "\"";
  size_t found = body.find(key);
  if (found == std::string::npos)
    return false;
  found = body.find(':', found + key.size());
  if (found == std::string::npos)
    return false;
  index = found + 1;
  skipSpaces(body, index);
  return index < body.size();
}

static bool findJsonString(const std::string &body, const char *field,
                           std::string &value) {
  size_t index = 0;
  if (!findJsonValueStart(body, field, index) || body[index] != '"')
    return false;
  index++;
  value.clear();
  while (index < body.size()) {
    char c = body[index++];
    if (c == '"')
      return true;
    if (c == '\\' && index < body.size()) {
      char escaped = body[index++];
      if (escaped == 'n') {
        value.push_back('\n');
      } else if (escaped == 'r') {
        value.push_back('\r');
      } else {
        value.push_back(escaped);
      }
    } else {
      value.push_back(c);
    }
  }
  return false;
}

static bool findJsonUint(const std::string &body, const char *field,
                         uint32_t &value) {
  size_t index = 0;
  if (!findJsonValueStart(body, field, index))
    return false;
  uint64_t parsed = 0;
  bool foundDigit = false;
  while (index < body.size() &&
         std::isdigit(static_cast<unsigned char>(body[index]))) {
    foundDigit = true;
    parsed = parsed * 10 + static_cast<uint64_t>(body[index] - '0');
    if (parsed > UINT32_MAX)
      return false;
    index++;
  }
  if (!foundDigit)
    return false;
  value = static_cast<uint32_t>(parsed);
  return true;
}

static bool findJsonBool(const std::string &body, const char *field,
                         bool &value) {
  size_t index = 0;
  if (!findJsonValueStart(body, field, index))
    return false;
  if (body.compare(index, 4, "true") == 0) {
    value = true;
    return true;
  }
  if (body.compare(index, 5, "false") == 0) {
    value = false;
    return true;
  }
  return false;
}

static std::string partitionLabel(const esp_partition_t *partition) {
  return partition == nullptr ? "" : std::string(partition->label);
}

static bool otaPartitionEligible(const esp_partition_t *running,
                                 const esp_partition_t *inactive,
                                 std::string &reason) {
  const bool inactiveIsOtaApplication =
      inactive != nullptr && inactive->type == ESP_PARTITION_TYPE_APP &&
      inactive->subtype >= ESP_PARTITION_SUBTYPE_APP_OTA_MIN &&
      inactive->subtype <= ESP_PARTITION_SUBTYPE_APP_OTA_MAX;
  const policy::Eligibility eligibility = policy::otaEligibility(
      running != nullptr, inactive != nullptr, inactive != running,
      inactiveIsOtaApplication, inactive == nullptr ? 0 : inactive->size);
  reason = policy::eligibilityCode(eligibility);
  return eligibility == policy::Eligibility::Eligible;
}

static std::string otaStateName(const esp_partition_t *partition) {
  if (partition == nullptr)
    return "unknown";
  esp_ota_img_states_t state;
  esp_err_t result = esp_ota_get_state_partition(partition, &state);
  if (result == ESP_ERR_NOT_FOUND)
    return "untracked"; // USB/factory image with no OTA state entry
  if (result != ESP_OK)
    return "unknown";
  switch (state) {
  case ESP_OTA_IMG_NEW:
    return "new";
  case ESP_OTA_IMG_PENDING_VERIFY:
    return "pending_verify";
  case ESP_OTA_IMG_VALID:
    return "valid";
  case ESP_OTA_IMG_INVALID:
    return "invalid";
  case ESP_OTA_IMG_ABORTED:
    return "aborted";
  case ESP_OTA_IMG_UNDEFINED:
  default:
    return "undefined";
  }
}

static std::string sha256Hex(const uint8_t digest[32]) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string out;
  out.reserve(64);
  for (size_t i = 0; i < 32; ++i) {
    out.push_back(kHex[(digest[i] >> 4) & 0x0F]);
    out.push_back(kHex[digest[i] & 0x0F]);
  }
  return out;
}

static bool base64Decode(const std::string &value, std::vector<uint8_t> &out) {
  size_t decodedLength = 0;
  int result = mbedtls_base64_decode(
      nullptr, 0, &decodedLength,
      reinterpret_cast<const unsigned char *>(value.data()), value.size());
  if (result != MBEDTLS_ERR_BASE64_BUFFER_TOO_SMALL || decodedLength == 0)
    return false;
  out.resize(decodedLength);
  result = mbedtls_base64_decode(
      out.data(), out.size(), &decodedLength,
      reinterpret_cast<const unsigned char *>(value.data()), value.size());
  if (result != 0)
    return false;
  out.resize(decodedLength);
  return true;
}

static std::string manifestPayload(uint32_t schemaVersion,
                                   const std::string &target,
                                   const std::string &version, uint32_t build,
                                   const std::string &gitSha, uint32_t size,
                                   const std::string &sha256,
                                   const std::string &releaseUrl,
                                   uint32_t minUpdaterProtocol) {
  std::ostringstream payload;
  payload << "schemaVersion=" << schemaVersion << "\n"
          << "target=" << target << "\n"
          << "version=" << version << "\n"
          << "build=" << build << "\n"
          << "gitSha=" << gitSha << "\n"
          << "size=" << size << "\n"
          << "sha256=" << sha256 << "\n"
          << "url=" << releaseUrl << "\n"
          << "minUpdaterProtocol=" << minUpdaterProtocol << "\n";
  return payload.str();
}

static bool verifyManifestSignature(const std::string &payload,
                                    const std::string &signatureBase64) {
  std::vector<uint8_t> signature;
  if (!base64Decode(signatureBase64, signature))
    return false;

  uint8_t digest[32];
  mbedtls_sha256_context sha;
  mbedtls_sha256_init(&sha);
  mbedtls_sha256_starts(&sha, 0);
  mbedtls_sha256_update(
      &sha, reinterpret_cast<const unsigned char *>(payload.data()),
      payload.size());
  mbedtls_sha256_finish(&sha, digest);
  mbedtls_sha256_free(&sha);

  mbedtls_pk_context publicKey;
  mbedtls_pk_init(&publicKey);
  int result = mbedtls_pk_parse_public_key(
      &publicKey,
      reinterpret_cast<const unsigned char *>(kManifestSigningPublicKeyPem),
      strlen(kManifestSigningPublicKeyPem) + 1);
  if (result == 0) {
    result = mbedtls_pk_verify(&publicKey, MBEDTLS_MD_SHA256, digest,
                               sizeof(digest), signature.data(),
                               signature.size());
  }
  mbedtls_pk_free(&publicKey);
  return result == 0;
}

} // namespace

void FirmwareUpdateHttpServer::configure(
    device_transfer::HttpTransferServer *sharedServer, uint16_t port) {
  if (stateMutex_ == nullptr)
    stateMutex_ = xSemaphoreCreateMutexStatic(&stateMutexStorage_);
  configASSERT(stateMutex_ != nullptr);
  transferServer_ = sharedServer == nullptr ? &ownedTransferServer_ : sharedServer;
  if (sharedServer == nullptr)
    transferServer_->configure(port, "BikeComputer-Transfer");
  transferServer_->registerHandler("/firmware-update", this);
}

bool FirmwareUpdateHttpServer::setEnabled(bool enabled) {
  // UI/callback callers revoke admission only. The HTTP owner aborts after
  // the last begin/write/end call has unwound, including idle uploads.
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  if (enabled && !firmware_maintenance::active()) {
    setLastError("firmware_maintenance_required",
                 "reboot into firmware maintenance before starting OTA");
    return false;
  }
#endif
  return transferServer_->setEnabled(enabled, enabled ? "firmware" : "");
}

void FirmwareUpdateHttpServer::workerWillStop() { resetUploadState(); }

void FirmwareUpdateHttpServer::setLastError(const std::string &code,
                                            const std::string &message) {
  lockState();
  rememberError(code, message);
  unlockState();
  transferServer_->setLastError(code, message);
}

void FirmwareUpdateHttpServer::process() { transferServer_->process(); }

FirmwareUpdateStatus FirmwareUpdateHttpServer::status() const {
  const esp_partition_t *running = esp_ota_get_running_partition();
  const esp_partition_t *inactive = esp_ota_get_next_update_partition(nullptr);

  lockState();
  FirmwareUpdateStatus snapshot;
  snapshot.status = status_;
  snapshot.target = firmware_metadata::target();
  snapshot.runningVersion = firmware_metadata::version();
  snapshot.runningBuild = firmware_metadata::build();
  snapshot.runningGitSha = firmware_metadata::gitSha();
  snapshot.runningProfile = firmware_metadata::buildProfile();
  snapshot.runningPartition = partitionLabel(running);
  snapshot.inactivePartition = partitionLabel(inactive);
  snapshot.otaState = otaStateName(running);
  snapshot.otaEligible =
      otaPartitionEligible(running, inactive, snapshot.eligibilityCode);
  snapshot.maxImageBytes = inactive == nullptr ? 0 : inactive->size;
  snapshot.receivedBytes = receivedBytes_;
  snapshot.totalBytes = totalBytes_;
  snapshot.sha256 = actualSha256_.empty() ? expectedSha256_ : actualSha256_;
  snapshot.errorCode = errorCode_;
  snapshot.errorMessage = errorMessage_;
  unlockState();
  return snapshot;
}

std::string FirmwareUpdateHttpServer::statusJson() const {
  FirmwareUpdateStatus snapshot = status();
  std::string body;
  body.reserve(768);
  body = "{\"status\":\"";
  body += status_json::escape(snapshot.status);
  body += "\"";
  status_json::appendStringField(body, "target", snapshot.target);
  status_json::appendStringField(body, "runningVersion",
                                 snapshot.runningVersion);
  status_json::appendUnsignedField(body, "runningBuild",
                                   snapshot.runningBuild);
  status_json::appendStringField(body, "runningGitSha",
                                 snapshot.runningGitSha);
  status_json::appendStringField(body, "runningPartition",
                                 snapshot.runningPartition);
  status_json::appendStringField(body, "inactivePartition",
                                 snapshot.inactivePartition);
  status_json::appendBoolField(body, "otaEligible", snapshot.otaEligible);
  status_json::appendStringField(body, "eligibilityCode",
                                 snapshot.eligibilityCode);
  status_json::appendStringField(body, "runningProfile",
                                 snapshot.runningProfile);
  status_json::appendStringField(body, "otaState", snapshot.otaState);
  status_json::appendUnsignedField(body, "maxImageBytes",
                                   snapshot.maxImageBytes);
  status_json::appendUnsignedField(body, "receivedBytes",
                                   snapshot.receivedBytes);
  status_json::appendUnsignedField(body, "totalBytes", snapshot.totalBytes);
  if (!snapshot.sha256.empty()) {
    status_json::appendStringField(body, "sha256", snapshot.sha256);
  } else {
    body += ",\"sha256\":null";
  }
  if (!snapshot.errorCode.empty()) {
    status_json::appendFieldPrefix(body, "lastError");
    body += "{\"code\":\"";
    body += status_json::escape(snapshot.errorCode);
    body += "\"";
    status_json::appendStringField(body, "message", snapshot.errorMessage);
    body += "}";
  } else {
    body += ",\"lastError\":null";
  }
  body += ",\"device\":" + firmware_metadata::json() + "}";
  return body;
}

std::string FirmwareUpdateHttpServer::bootAcceptanceJson(bool ready) const {
  return firmware_metadata::bootAcceptanceJson(
      ready, otaStateName(esp_ota_get_running_partition()).c_str());
}

bool FirmwareUpdateHttpServer::markRunningAppValid() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  if (running == nullptr)
    return false;
  esp_ota_img_states_t state = ESP_OTA_IMG_UNDEFINED;
  const esp_err_t query = esp_ota_get_state_partition(running, &state);
  // USB/factory provisioning has no pending OTA record. It still needs the
  // application's readiness checks, but there is nothing to confirm.
  if (query == ESP_ERR_NOT_FOUND ||
      (query == ESP_OK && (state == ESP_OTA_IMG_VALID ||
                           state == ESP_OTA_IMG_UNDEFINED)))
    return true;
  if (query != ESP_OK || state != ESP_OTA_IMG_PENDING_VERIFY)
    return false;
  const esp_err_t result = esp_ota_mark_app_valid_cancel_rollback();
  if (result != ESP_OK)
    return false;
  return esp_ota_get_state_partition(running, &state) == ESP_OK &&
         state == ESP_OTA_IMG_VALID;
}

void FirmwareUpdateHttpServer::rejectRunningApp() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  esp_ota_img_states_t state;
  if (running != nullptr &&
      esp_ota_get_state_partition(running, &state) == ESP_OK &&
      state == ESP_OTA_IMG_PENDING_VERIFY) {
    // Returns only on failure (e.g. no eligible previous slot). Never proceed
    // to readiness; restarting leaves bootloader rollback in control.
    (void)esp_ota_mark_app_invalid_rollback_and_reboot();
    ESP.restart();
  }
}

bool FirmwareUpdateHttpServer::handleRequest(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  if (!startsWith(request.path, "/firmware-update"))
    return false;
  Serial.printf("FIRMWARE_UPDATE_HTTP: %s %s length=%llu\n",
                request.method.c_str(), request.path.c_str(),
                static_cast<unsigned long long>(request.contentLength));
  if (transferServer_->status().mode != "firmware") {
    reject(client, 403, "transfer_mode_mismatch",
           "firmware transfer mode is not active");
    return true;
  }
  if (!transferServer_->isRequestAuthorized(request)) {
    reject(client, 401, "transfer_token_invalid",
           "firmware transfer token is missing or invalid");
    return true;
  }
  if (request.method == "GET" && request.path == kStatusPath) {
    handleStatus(client);
    return true;
  }
  if (request.method == "POST" && request.path == kBeginPath) {
    handleBegin(request, client);
    return true;
  }
  if (request.method == "PUT" && request.path == kImagePath) {
    handleImage(request, client);
    return true;
  }
  if (request.method == "POST" && request.path == kFinalizePath) {
    handleFinalize(request, client);
    return true;
  }
  if (request.method == "POST" && request.path == kCancelPath) {
    handleCancel(client);
    return true;
  }
  reject(client, 404, "not_found", "firmware update endpoint not found");
  return true;
}

void FirmwareUpdateHttpServer::handleStatus(device_transfer::TransferClient &client) {
  device_transfer::sendHttpJson(client, 200, statusJson());
}

void FirmwareUpdateHttpServer::handleBegin(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  std::string body;
  if (!device_transfer::readHttpBody(client, request.contentLength,
                                     kMaxBeginBodyBytes, body)) {
    fail(client, 413, "begin_body_invalid", "invalid begin request body");
    return;
  }
  if (!transferServer_->isRequestAuthorized(request)) {
    fail(client, 409, "transfer_cancelled",
         "firmware transfer authorization was revoked");
    return;
  }

  std::string version;
  std::string target;
  std::string sha256;
  std::string gitSha;
  std::string releaseUrl;
  std::string manifestSignature;
  uint32_t schemaVersion = 0;
  uint32_t build = 0;
  uint32_t size = 0;
  uint32_t minUpdaterProtocol = 0;
  bool allowDowngrade = false;
  if (!findJsonUint(body, "schemaVersion", schemaVersion) ||
      !findJsonString(body, "version", version) ||
      !findJsonString(body, "target", target) ||
      !findJsonString(body, "gitSha", gitSha) ||
      !findJsonString(body, "sha256", sha256) ||
      !findJsonString(body, "releaseUrl", releaseUrl) ||
      !findJsonString(body, "manifestSignature", manifestSignature) ||
      !findJsonUint(body, "build", build) ||
      !findJsonUint(body, "size", size) ||
      !findJsonUint(body, "minUpdaterProtocol", minUpdaterProtocol)) {
    fail(client, 400, "begin_body_invalid", "missing firmware metadata");
    return;
  }
  findJsonBool(body, "allowDowngrade", allowDowngrade);

  if (schemaVersion != 1 ||
      minUpdaterProtocol > firmware_metadata::kUpdaterProtocolVersion) {
    fail(client, 400, "manifest_unsupported",
         "firmware manifest is not supported");
    return;
  }
  if (target != firmware_metadata::target()) {
    fail(client, 400, "target_mismatch", "firmware target does not match");
    return;
  }
  if (version.empty() || gitSha.empty() || releaseUrl.empty() ||
      !isHexSha256(sha256)) {
    fail(client, 400, "metadata_invalid", "firmware metadata is invalid");
    return;
  }
  const std::string signedPayload =
      manifestPayload(schemaVersion, target, version, build, gitSha, size,
                      sha256, releaseUrl, minUpdaterProtocol);
  if (!verifyManifestSignature(signedPayload, manifestSignature)) {
    fail(client, 400, "manifest_signature_invalid",
         "firmware manifest signature is invalid");
    return;
  }
  if (build <= firmware_metadata::build() && !allowDowngrade) {
    fail(client, 409, "not_newer", "firmware build is not newer");
    return;
  }

  const esp_partition_t *updatePartition =
      esp_ota_get_next_update_partition(nullptr);
  const esp_partition_t *runningPartition = esp_ota_get_running_partition();
  std::string eligibilityCode;
  if (!otaPartitionEligible(runningPartition, updatePartition,
                            eligibilityCode)) {
    fail(client, 409, eligibilityCode,
         "a distinct inactive OTA partition is required");
    return;
  }
  if (size == 0 || size > updatePartition->size) {
    fail(client, 413, "image_too_large", "firmware image does not fit");
    return;
  }

  resetUploadState();
  esp_ota_handle_t handle = 0;
  esp_err_t result = esp_ota_begin(updatePartition, size, &handle);
  if (result != ESP_OK) {
    fail(client, 500, "ota_begin_failed", esp_err_to_name(result));
    return;
  }
  if (!transaction_.begin()) {
    esp_ota_abort(handle);
    fail(client, 409, "ota_owner_busy",
         "another firmware transaction owns the OTA lifecycle");
    return;
  }

  lockState();
  status_ = "receiving";
  totalBytes_ = size;
  expectedSha256_ = sha256;
  pendingVersion_ = version;
  pendingBuild_ = build;
  allowDowngrade_ = allowDowngrade;
  updatePartition_ = updatePartition;
  otaHandle_ = handle;
  otaOpen_ = true;
  errorCode_.clear();
  errorMessage_.clear();
  unlockState();

  firmware_maintenance::setStage(firmware_maintenance::Stage::Receiving);
  transferServer_->noteStatusChanged("ota_begin");

  device_transfer::sendHttpJson(client, 200, statusJson());
}

void FirmwareUpdateHttpServer::handleImage(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  lockState();
  const bool ready = status_ == "receiving" && otaOpen_;
  const uint32_t expectedSize = totalBytes_;
  esp_ota_handle_t handle = otaHandle_;
  unlockState();
  if (!ready) {
    fail(client, 409, "upload_not_started", "firmware upload was not started");
    return;
  }
  if (request.contentLength != expectedSize) {
    resetUploadState();
    fail(client, 400, "size_mismatch", "firmware upload size mismatch");
    return;
  }

  mbedtls_sha256_context sha;
  mbedtls_sha256_init(&sha);
  mbedtls_sha256_starts(&sha, 0);

  uint8_t buffer[2048];
  uint64_t remaining = request.contentLength;
  uint32_t lastReadMs = millis();
  while (remaining > 0 && millis() - lastReadMs < 10000) {
    if (!transferServer_->isRequestAuthorized(request)) {
      mbedtls_sha256_free(&sha);
      resetUploadState();
      fail(client, 409, "transfer_cancelled",
           "firmware transfer authorization was revoked");
      return;
    }
    int available = client.available();
    if (available <= 0) {
      delay(1);
      continue;
    }
    size_t toRead = std::min<uint64_t>(sizeof(buffer), remaining);
    toRead = std::min<size_t>(toRead, static_cast<size_t>(available));
    int bytesRead = client.read(buffer, toRead);
    if (bytesRead <= 0) {
      delay(1);
      continue;
    }
    esp_err_t result = esp_ota_write(handle, buffer, bytesRead);
    if (result != ESP_OK) {
      mbedtls_sha256_free(&sha);
      resetUploadState();
      fail(client, 500, "ota_write_failed", esp_err_to_name(result));
      return;
    }
    mbedtls_sha256_update(&sha, buffer, bytesRead);
    remaining -= static_cast<uint64_t>(bytesRead);
    lastReadMs = millis();

    lockState();
    receivedBytes_ += static_cast<uint32_t>(bytesRead);
    const uint32_t receivedBytes = receivedBytes_;
    unlockState();
    if ((receivedBytes & ((256U * 1024U) - 1U)) <
        static_cast<uint32_t>(bytesRead)) {
      transferServer_->sampleResources("ota_write");
    }
  }

  if (!transferServer_->isRequestAuthorized(request)) {
    mbedtls_sha256_free(&sha);
    resetUploadState();
    fail(client, 409, "transfer_cancelled",
         "firmware transfer authorization was revoked");
    return;
  }

  if (remaining != 0) {
    mbedtls_sha256_free(&sha);
    resetUploadState();
    fail(client, 408, "upload_timeout", "firmware upload timed out");
    return;
  }

  uint8_t digest[32];
  mbedtls_sha256_finish(&sha, digest);
  mbedtls_sha256_free(&sha);
  const std::string actualSha256 = sha256Hex(digest);

  lockState();
  const std::string expectedSha256 = expectedSha256_;
  unlockState();
  if (actualSha256 != expectedSha256) {
    resetUploadState();
    fail(client, 400, "sha256_mismatch", "firmware image hash mismatch");
    return;
  }
  if (!transaction_.verify()) {
    resetUploadState();
    fail(client, 409, "ota_state_invalid",
         "firmware transaction did not reach the verified state");
    return;
  }

  lockState();
  actualSha256_ = actualSha256;
  status_ = "verified";
  unlockState();
  firmware_maintenance::setStage(firmware_maintenance::Stage::Verifying);
  transferServer_->noteStatusChanged("image_verified");
  device_transfer::sendHttpJson(client, 200, statusJson());
}

void FirmwareUpdateHttpServer::handleFinalize(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  lockState();
  const bool ready = status_ == "verified" && otaOpen_;
  const esp_ota_handle_t handle = otaHandle_;
  const esp_partition_t *updatePartition = updatePartition_;
  const std::string expectedSha256 = expectedSha256_;
  const std::string actualSha256 = actualSha256_;
  const std::string pendingVersion = pendingVersion_;
  const uint32_t pendingBuild = pendingBuild_;
  unlockState();
  if (!ready || updatePartition == nullptr) {
    fail(client, 409, "finalize_not_ready", "firmware image is not ready");
    return;
  }
  if (expectedSha256.empty() || actualSha256 != expectedSha256 ||
      pendingVersion.empty() || pendingBuild == 0) {
    resetUploadState();
    fail(client, 409, "finalize_metadata_invalid",
         "verified firmware metadata is missing or inconsistent");
    return;
  }
  if (!transferServer_->isRequestAuthorized(request)) {
    resetUploadState();
    fail(client, 409, "transfer_cancelled",
         "firmware transfer authorization was revoked");
    return;
  }

  esp_err_t result = esp_ota_end(handle);
  lockState();
  otaOpen_ = false;
  otaHandle_ = 0;
  unlockState();
  if (result != ESP_OK) {
    resetUploadState();
    fail(client, 400, "ota_end_failed", esp_err_to_name(result));
    return;
  }
  if (!transferServer_->isRequestAuthorized(request)) {
    resetUploadState();
    fail(client, 409, "transfer_cancelled",
         "firmware transfer authorization was revoked before activation");
    return;
  }

  esp_app_desc_t appDescription;
  result = esp_ota_get_partition_description(updatePartition, &appDescription);
  if (result != ESP_OK) {
    resetUploadState();
    fail(client, 400, "image_description_failed", esp_err_to_name(result));
    return;
  }

  if (!transferServer_->beginAuthorizedCommit(request)) {
    resetUploadState();
    fail(client, 409, "transfer_cancelled",
         "firmware transfer authorization was revoked before activation");
    return;
  }
  if (!transaction_.beginCommit()) {
    transferServer_->endAuthorizedCommit();
    resetUploadState();
    fail(client, 409, "ota_commit_state_invalid",
         "firmware transaction could not enter the commit boundary");
    return;
  }

  firmware_maintenance::setStage(firmware_maintenance::Stage::Committing);
  transferServer_->noteStatusChanged("commit_boundary");
  result = esp_ota_set_boot_partition(updatePartition);
  if (result != ESP_OK) {
    transferServer_->endAuthorizedCommit();
    resetUploadState();
    fail(client, 500, "set_boot_partition_failed", esp_err_to_name(result));
    return;
  }
  const bool rebootSelected = transaction_.selectReboot();
  configASSERT(rebootSelected);

  lockState();
  status_ = "rebooting";
  unlockState();
  firmware_maintenance::setStage(firmware_maintenance::Stage::Rebooting);
  transferServer_->noteStatusChanged("boot_selected");
  device_transfer::sendHttpJson(client, 202, statusJson());
  Serial.printf("FIRMWARE_UPDATE: boot partition set to %s manifest=%s(%u) "
                "app=%s project=%s; rebooting\n",
                updatePartition->label, pendingVersion.c_str(),
                static_cast<unsigned>(pendingBuild), appDescription.version,
                appDescription.project_name);
  delay(750);
  ESP.restart();
}

void FirmwareUpdateHttpServer::handleCancel(device_transfer::TransferClient &client) {
  resetUploadState();
  (void)transaction_.cancel();
  lockState();
  status_ = "cancelled";
  unlockState();
  firmware_maintenance::requestExit();
  transferServer_->noteStatusChanged("cancelled");
  device_transfer::sendHttpJson(client, 200, statusJson());
}

void FirmwareUpdateHttpServer::resetUploadState() {
  lockState();
  const bool otaOpen = otaOpen_;
  const esp_ota_handle_t handle = otaHandle_;
  otaOpen_ = false;
  otaHandle_ = 0;
  status_ = "idle";
  receivedBytes_ = 0;
  totalBytes_ = 0;
  expectedSha256_.clear();
  actualSha256_.clear();
  pendingVersion_.clear();
  pendingBuild_ = 0;
  allowDowngrade_ = false;
  updatePartition_ = nullptr;
  transaction_.reset();
  unlockState();
  if (otaOpen) {
    esp_ota_abort(handle);
  }
}

void FirmwareUpdateHttpServer::reject(device_transfer::TransferClient &client, int httpStatus,
                                      const std::string &code,
                                      const std::string &message) {
  transferServer_->setLastError(code, message);
  device_transfer::sendHttpError(client, httpStatus, code, message);
}

void FirmwareUpdateHttpServer::fail(device_transfer::TransferClient &client, int httpStatus,
                                    const std::string &code,
                                    const std::string &message) {
  transaction_.fail();
  lockState();
  status_ = "failed";
  unlockState();
  firmware_maintenance::setStage(firmware_maintenance::Stage::Failed);
  setLastError(code, message);
  device_transfer::sendHttpError(client, httpStatus, code, message);
}

void FirmwareUpdateHttpServer::rememberError(const std::string &code,
                                             const std::string &message) {
  errorCode_ = code;
  errorMessage_ = message;
}

void FirmwareUpdateHttpServer::lockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreTake(stateMutex_, portMAX_DELAY);
}

void FirmwareUpdateHttpServer::unlockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreGive(stateMutex_);
}

} // namespace firmware_update
