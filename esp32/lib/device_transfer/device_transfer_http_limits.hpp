#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace device_transfer {

constexpr size_t HTTP_MAX_LINE_BYTES = 512;
constexpr size_t HTTP_MAX_HEADER_BYTES = 8192;
constexpr size_t HTTP_MAX_HEADER_LINES = 64;
constexpr uint32_t HTTP_REQUEST_HEADER_TIMEOUT_MS = 5000;
// A TLS client that completes its handshake but sends no HTTP bytes is a
// speculative/preconnection socket, not useful debug traffic. Release it
// quickly enough that the single worker can still serve the app's pinned
// request before its five-second deadline. The normal header deadline still
// bounds the remaining header lines after a complete request line arrives.
constexpr uint32_t HTTP_INITIAL_REQUEST_IDLE_TIMEOUT_MS = 1000;
// The transfer server has one TLS/HTTP worker. A completed authenticated
// request may reuse that worker, but an idle persistent client must release it
// well before the iOS client's five-second request deadline so a different
// pinned URLSession (for example the secure sweep after closing WKWebView) can
// connect without being starved behind the old socket.
constexpr uint32_t HTTP_PERSISTENT_REQUEST_IDLE_TIMEOUT_MS = 2000;
constexpr size_t HTTP_MAX_REQUESTS_PER_TLS_CONNECTION = 4096;

inline uint32_t httpRequestLineTimeoutMs(size_t requestIndex) {
  return requestIndex == 0 ? HTTP_INITIAL_REQUEST_IDLE_TIMEOUT_MS
                           : HTTP_PERSISTENT_REQUEST_IDLE_TIMEOUT_MS;
}

inline uint32_t nextHttpTransferGeneration(uint32_t current) {
  current++;
  return current == 0 ? 1 : current;
}

inline bool isHttpTransferGenerationCurrent(bool enabled, uint32_t current,
                                            uint32_t request) {
  return enabled && current != 0 && current == request;
}

inline bool shouldReuseAuthenticatedHttpConnection(
    bool authorized, bool generationStillCurrent, bool clientRequestedClose,
    bool responseKeepAlive, bool connected) {
  return authorized && generationStillCurrent && !clientRequestedClose &&
         responseKeepAlive && connected;
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
  bool connectionSeen = false;
  bool connectionClose = false;
  bool connectionReuseSeen = false;
  bool connectionReuseRequested = false;

  static bool containsConnectionToken(const std::string &value,
                                      const char *expected) {
    size_t tokenStart = 0;
    while (tokenStart <= value.size()) {
      const size_t comma = value.find(',', tokenStart);
      size_t begin = tokenStart;
      size_t end = comma == std::string::npos ? value.size() : comma;
      while (begin < end && (value[begin] == ' ' || value[begin] == '\t'))
        begin++;
      while (end > begin &&
             (value[end - 1] == ' ' || value[end - 1] == '\t'))
        end--;
      const size_t expectedLength = std::char_traits<char>::length(expected);
      if (end - begin == expectedLength) {
        bool matches = true;
        for (size_t index = 0; index < expectedLength; ++index) {
          char character = value[begin + index];
          if (character >= 'A' && character <= 'Z')
            character = static_cast<char>(character - 'A' + 'a');
          if (character != expected[index]) {
            matches = false;
            break;
          }
        }
        if (matches)
          return true;
      }
      if (comma == std::string::npos)
        break;
      tokenStart = comma + 1;
    }
    return false;
  }

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
    } else if (name == "connection") {
      // Duplicate Connection fields are unnecessary for the app and make a
      // persistent-session decision harder to audit. Fail closed to the
      // one-request behavior without rejecting the otherwise valid request.
      connectionClose = connectionClose || connectionSeen ||
                        containsConnectionToken(value, "close");
      connectionSeen = true;
    } else if (name == "x-bikecomputer-connection-reuse") {
      // Persistence is an explicit app-client capability. WebKit may open
      // parallel or speculative connections for the secure console, which
      // cannot safely share this single HTTP worker. Duplicate or unexpected
      // values fail closed to one response per TLS connection.
      connectionReuseRequested = !connectionReuseSeen && value == "1";
      connectionReuseSeen = true;
    }
  }

  bool hasAmbiguousFraming() const { return transferEncodingSeen; }
};

} // namespace device_transfer
