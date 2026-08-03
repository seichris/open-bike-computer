#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace device_transfer {

constexpr size_t HTTP_MAX_LINE_BYTES = 512;
constexpr size_t HTTP_MAX_HEADER_BYTES = 8192;
constexpr size_t HTTP_MAX_HEADER_LINES = 64;
constexpr uint32_t HTTP_REQUEST_HEADER_TIMEOUT_MS = 5000;

inline uint32_t nextHttpTransferGeneration(uint32_t current) {
  current++;
  return current == 0 ? 1 : current;
}

inline bool isHttpTransferGenerationCurrent(bool enabled, uint32_t current,
                                            uint32_t request) {
  return enabled && current != 0 && current == request;
}

struct HttpResponseCompletionToken {
  uint32_t transferGeneration = 0;
  std::string method;
  std::string path;

  bool matches(uint32_t generation, const std::string &requestMethod,
               const std::string &requestPath) const {
    return transferGeneration != 0 && transferGeneration == generation &&
           method == requestMethod && path == requestPath;
  }
};

inline bool validHttpHeaderName(const std::string &name) {
  if (name.empty())
    return false;
  for (const unsigned char character : name) {
    const bool alphaNumeric =
        (character >= 'a' && character <= 'z') ||
        (character >= 'A' && character <= 'Z') ||
        (character >= '0' && character <= '9');
    const bool punctuation =
        character == '!' || character == '#' || character == '$' ||
        character == '%' || character == '&' || character == '\'' ||
        character == '*' || character == '+' || character == '-' ||
        character == '.' || character == '^' || character == '_' ||
        character == '`' || character == '|' || character == '~';
    if (!alphaNumeric && !punctuation)
      return false;
  }
  return true;
}

struct HttpHeaderBudget {
  size_t totalBytes = 0;
  size_t lineBytes = 0;
  size_t lines = 0;

  bool acceptDataByte() {
    if (totalBytes >= HTTP_MAX_HEADER_BYTES ||
        lineBytes >= HTTP_MAX_LINE_BYTES)
      return false;
    totalBytes++;
    lineBytes++;
    return true;
  }

  bool acceptDelimiterByte() {
    if (totalBytes >= HTTP_MAX_HEADER_BYTES)
      return false;
    totalBytes++;
    return true;
  }

  bool finishLine() {
    if (lines >= HTTP_MAX_HEADER_LINES)
      return false;
    lines++;
    lineBytes = 0;
    return true;
  }

  static bool timedOut(uint32_t elapsedMilliseconds) {
    return elapsedMilliseconds >= HTTP_REQUEST_HEADER_TIMEOUT_MS;
  }
};

inline bool parseHttpUint64(const std::string &text, uint64_t &value) {
  if (text.empty())
    return false;
  uint64_t parsed = 0;
  for (char character : text) {
    if (character < '0' || character > '9')
      return false;
    const uint64_t digit = static_cast<uint64_t>(character - '0');
    if (parsed > (UINT64_MAX - digit) / 10)
      return false;
    parsed = parsed * 10 + digit;
  }
  value = parsed;
  return true;
}

struct HttpSecurityHeaders {
  std::string transferToken;
  std::string contentType;
  uint64_t contentLength = 0;
  bool hasContentLength = false;
  bool transferTokenSeen = false;
  bool contentTypeSeen = false;
  bool contentLengthSeen = false;
  bool transferEncodingSeen = false;

  void accept(const std::string &name, const std::string &value) {
    if (name == "content-length") {
      hasContentLength = !contentLengthSeen &&
                         parseHttpUint64(value, contentLength);
      contentLengthSeen = true;
      if (!hasContentLength)
        contentLength = 0;
    } else if (name == "content-type") {
      contentType = contentTypeSeen ? "" : value;
      contentTypeSeen = true;
    } else if (name == "x-bikecomputer-transfer-token") {
      transferToken = transferTokenSeen ? "" : value;
      transferTokenSeen = true;
    } else if (name == "transfer-encoding") {
      transferEncodingSeen = true;
    }
  }

  bool hasAmbiguousFraming() const { return transferEncodingSeen; }
};

} // namespace device_transfer
