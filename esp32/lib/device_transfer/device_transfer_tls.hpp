#pragma once

#include <Arduino.h>
#include <WiFi.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include "../utils/src/runtime_ownership.hpp"
#include "../utils/src/runtime_mutex.hpp"

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

struct HttpResponseWriteDiagnostics {
  size_t bytesWritten = 0;
  uint32_t writeCalls = 0;
  uint32_t zeroWriteCalls = 0;
  uint32_t shortWriteCalls = 0;
  uint32_t activeTlsWriteUs = 0;
  uint32_t noProgressWaitMs = 0;
  uint32_t intentionalDelayMs = 0;
};

enum class TransferTlsFailureStage : uint8_t {
  None = 0,
  Input,
  SocketOwnership,
  ContextAllocation,
  Setup,
  Handshake,
};

struct TransferTlsMemorySnapshot {
  uint32_t internalFree = 0;
  uint32_t internalLargest = 0;
  uint32_t dmaFree = 0;
  uint32_t dmaLargest = 0;
  uint32_t psramFree = 0;
  uint32_t psramLargest = 0;
};

// Fixed-size, non-secret evidence for the first failed response. Values are
// captured before TLS and file handles are torn down.
enum class TransferFailureReason : uint8_t {
  None, InvalidWrite, TlsWrite, SocketPoll, TlsRead, SocketInterrupted,
  Disconnected, NoProgressTimeout, FileRead, Authorization, HandlerAbort
};
const char *transferFailureReasonName(TransferFailureReason reason);
enum class TransferFileAbortBranch : uint8_t {
  None, AuthorizationBeforeOpen, Header, AuthorizationDuringBody,
  Read, Write, Close
};
const char *transferFileAbortBranchName(TransferFileAbortBranch branch);

struct TransferFailureRecord {
  TransferFailureReason reason = TransferFailureReason::None;
  uint32_t atMs = 0;
  uint32_t generation = 0;
  uint32_t responseHeaderBytes = 0;
  uint32_t responseBodyBytes = 0;
  uint32_t inputBytes = 0;
  uint32_t offsetBytes = 0;
  uint32_t attemptedBytes = 0;
  uint32_t elapsedSinceProgressMs = 0;
  int32_t rawTlsResult = 0;
  int32_t immediateErrno = 0;
  int32_t firstFatalTlsResult = 0;
  int32_t firstFatalErrno = 0;
  bool firstFatalSeen = false;
  int32_t pollResult = 0;
  int16_t pollFlags = 0;
  uint32_t tlsWriteCalls = 0;
  uint32_t wantReadCalls = 0;
  uint32_t wantWriteCalls = 0;
  uint32_t rawZeroCalls = 0;
  uint32_t fatalWriteCalls = 0;
  uint32_t positivePartialCalls = 0;
  uint32_t lastWriteDurationUs = 0;
  uint32_t fileRequested = 0;
  uint32_t fileReturned = 0;
  int32_t fileErrno = 0;
  bool fileError = false;
  bool fileEof = false;
  TransferFileAbortBranch fileAbortBranch = TransferFileAbortBranch::None;
  // Bits: enabled, token-present, token-match, generation-match,
  // BLE-bound, diagnostics-mode-match. These are decisions, never token data.
  uint8_t authorizationBits = 0;
  TransferTlsMemorySnapshot memory;
};

// Captures only non-secret failure metadata. Certificate/key bytes, the
// transfer token, and Wi-Fi credentials never enter this structure.
struct TransferTlsHandshakeDiagnostics {
  TransferTlsFailureStage stage = TransferTlsFailureStage::None;
  int32_t sessionResult = 0;
  int32_t lastEspError = 0;
  int32_t tlsErrorCode = 0;
  int32_t tlsFlags = 0;
  TransferTlsMemorySnapshot before;
  TransferTlsMemorySnapshot after;
};

const char *transferTlsFailureStageName(TransferTlsFailureStage stage);
const char *transferTlsFailureCode(
    const TransferTlsHandshakeDiagnostics &diagnostics);

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
  const TransferTlsHandshakeDiagnostics &handshakeDiagnostics() const {
    return handshakeDiagnostics_;
  }
  const TransferFailureRecord &failureRecord() const { return failureRecord_; }
  void noteFailure(TransferFailureReason reason, size_t input = 0,
                   size_t offset = 0, size_t attempted = 0,
                   uint32_t elapsed = 0);
  void noteWriteAttempt(size_t input, size_t offset, size_t attempted,
                        uint32_t elapsed) {
    writeInputBytes_ = input;
    writeOffsetBytes_ = offset;
    writeAttemptedBytes_ = attempted;
    writeElapsedMs_ = elapsed;
  }
  void noteFileRead(size_t requested, size_t returned, int errorNumber,
                    bool error, bool eof);
  void noteFileAbortBranch(TransferFileAbortBranch branch) {
    failureRecord_.fileAbortBranch = branch;
  }
  void noteResponseHeaderComplete() {
    responseHeaderBytes_ = responseBytesWritten_;
    responseHeaderInProgress_ = false;
  }
  void noteResponseHeaderStarted() { responseHeaderInProgress_ = true; }
  void resetHttpResponsePolicy(bool persistenceAllowed);
  void setHttpRequestBodyLength(uint64_t contentLength) {
    requestBodyConsumed_ = contentLength == 0;
  }
  void markHttpRequestBodyConsumed() { requestBodyConsumed_ = true; }
  void requestHttpResponseKeepAlive();
  void requestHttpResponseClose() { responseKeepAlive_ = false; }
  void noteHttpResponseWriteStarted() { responseWriteStarted_ = true; }
  void noteHttpResponseWriteProgress(size_t bytes) {
    responseBytesWritten_ += bytes;
  }
  void noteHttpResponseNoProgressWait(uint32_t milliseconds) {
    responseNoProgressWaitMs_ += milliseconds;
  }
  void noteHttpResponseIntentionalDelay(uint32_t milliseconds) {
    responseIntentionalDelayMs_ += milliseconds;
  }
  void noteHttpResponseWriteFailed() {
    responseWriteStarted_ = true;
    responseWriteFailed_ = true;
    responseKeepAlive_ = false;
  }
  bool httpResponseWriteStarted() const { return responseWriteStarted_; }
  bool httpResponseWriteFailed() const { return responseWriteFailed_; }
  size_t httpResponseBytesWritten() const { return responseBytesWritten_; }
  HttpResponseWriteDiagnostics httpResponseWriteDiagnostics() const {
    return {responseBytesWritten_, responseWriteCalls_,
            responseZeroWriteCalls_, responseShortWriteCalls_,
            responseActiveTlsWriteUs_, responseNoProgressWaitMs_,
            responseIntentionalDelayMs_};
  }
  bool httpResponseKeepAlive() const {
    return responseKeepAlive_ && requestBodyConsumed_;
  }
  const char *httpResponseConnectionValue() const {
    return httpResponseKeepAlive() ? "keep-alive" : "close";
  }
  void interruptSocket();
  bool finishResponse(uint32_t timeoutMs);
  void stop();
  explicit operator bool() { return connected() != 0; }

private:
  WiFiClient socketOwner_;
  esp_tls *tls_ = nullptr;
  int socket_ = -1;
  runtime_ownership::SocketInterruptLease<runtime_ownership::StaticMutex>
      interruptLease_;
  bool connected_ = false;
  bool responsePersistenceAllowed_ = false;
  bool responseKeepAlive_ = false;
  bool requestBodyConsumed_ = true;
  bool responseWriteStarted_ = false;
  bool responseWriteFailed_ = false;
  size_t responseBytesWritten_ = 0;
  uint32_t responseWriteCalls_ = 0;
  uint32_t responseZeroWriteCalls_ = 0;
  uint32_t responseShortWriteCalls_ = 0;
  uint32_t responseActiveTlsWriteUs_ = 0;
  uint32_t responseNoProgressWaitMs_ = 0;
  uint32_t responseIntentionalDelayMs_ = 0;
  size_t responseHeaderBytes_ = 0;
  bool responseHeaderInProgress_ = false;
  TransferFailureRecord failureRecord_;
  uint32_t wantReadCalls_ = 0;
  uint32_t wantWriteCalls_ = 0;
  uint32_t rawZeroCalls_ = 0;
  uint32_t fatalWriteCalls_ = 0;
  uint32_t positivePartialCalls_ = 0;
  uint32_t lastWriteDurationUs_ = 0;
  int32_t lastRawTlsResult_ = 0;
  int32_t lastWriteErrno_ = 0;
  int32_t firstFatalTlsResult_ = 0;
  int32_t firstFatalErrno_ = 0;
  bool firstFatalSeen_ = false;
  int32_t lastPollResult_ = 0;
  int16_t lastPollFlags_ = 0;
  size_t writeInputBytes_ = 0;
  size_t writeOffsetBytes_ = 0;
  size_t writeAttemptedBytes_ = 0;
  uint32_t writeElapsedMs_ = 0;
  TransferTlsHandshakeDiagnostics handshakeDiagnostics_;
};

} // namespace device_transfer
