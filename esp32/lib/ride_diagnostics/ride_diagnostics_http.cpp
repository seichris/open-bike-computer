#include "ride_diagnostics_http.hpp"

#include "../storage/storage.hpp"
#include "ride_diagnostics.hpp"

#include <Arduino.h>
#include <dirent.h>
#include <mbedtls/sha256.h>
#include <sys/stat.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

extern Storage storage;

namespace ride_diagnostics {
namespace {

constexpr const char *kPrefix = "/device-diagnostics/v1/";
constexpr std::size_t kMaximumChunks = 256;
constexpr std::size_t kMaximumIndexBytes = 64 * 1024;

struct Chunk {
  uint32_t boot = 0;
  uint32_t number = 0;
  uint32_t bytes = 0;
  std::string path;
  std::string sha256;
};

bool chunkOlder(const Chunk &left, const Chunk &right) {
  return std::tie(left.boot, left.number) <
         std::tie(right.boot, right.number);
}

bool parseUnsigned(const std::string &value, uint32_t &out) {
  if (value.empty() || value.size() > 10)
    return false;
  uint64_t parsed = 0;
  for (char c : value) {
    if (c < '0' || c > '9')
      return false;
    parsed = parsed * 10 + static_cast<unsigned>(c - '0');
    if (parsed > UINT32_MAX)
      return false;
  }
  out = static_cast<uint32_t>(parsed);
  return true;
}

std::string jsonEscape(const std::string &value) {
  std::string escaped;
  escaped.reserve(value.size() + 8);
  for (char c : value) {
    if (c == '"' || c == '\\') {
      escaped.push_back('\\');
      escaped.push_back(c);
    } else if (c == '\n') {
      escaped += "\\n";
    } else if (c == '\r') {
      escaped += "\\r";
    } else {
      escaped.push_back(c);
    }
  }
  return escaped;
}

bool sha256File(const char *path, std::string &out, uint32_t &bytes) {
  FILE *file = storage.open(path, "rb");
  if (file == nullptr)
    return false;
  mbedtls_sha256_context context;
  mbedtls_sha256_init(&context);
  if (mbedtls_sha256_starts(&context, 0) != 0) {
    mbedtls_sha256_free(&context);
    storage.close(file);
    return false;
  }
  uint8_t buffer[4096];
  bytes = 0;
  bool ok = true;
  while (true) {
    const size_t count = storage.read(file, buffer, sizeof(buffer));
    if (count == 0)
      break;
    if (mbedtls_sha256_update(&context, buffer, count) != 0) {
      ok = false;
      break;
    }
    bytes += static_cast<uint32_t>(count);
  }
  uint8_t digest[32] = {};
  if (ok)
    ok = mbedtls_sha256_finish(&context, digest) == 0;
  mbedtls_sha256_free(&context);
  storage.close(file);
  if (!ok)
    return false;
  static constexpr char hex[] = "0123456789abcdef";
  out.clear();
  out.reserve(64);
  for (uint8_t byte : digest) {
    out.push_back(hex[(byte >> 4) & 0x0f]);
    out.push_back(hex[byte & 0x0f]);
  }
  return true;
}

std::vector<Chunk> listChunks() {
  std::vector<Chunk> chunks;
  chunks.reserve(kMaximumChunks);
  DIR *boots = opendir("/sdcard/BICINO/DIAGNOSTICS/v1/boots");
  if (boots == nullptr)
    return chunks;
  while (struct dirent *bootEntry = readdir(boots)) {
    uint32_t boot = 0;
    if (!parseUnsigned(bootEntry->d_name, boot))
      continue;
    char directory[192] = {};
    snprintf(directory, sizeof(directory),
             "/sdcard/BICINO/DIAGNOSTICS/v1/boots/%s",
             bootEntry->d_name);
    DIR *dir = opendir(directory);
    if (dir == nullptr)
      continue;
    while (struct dirent *entry = readdir(dir)) {
      const std::string name(entry->d_name);
      if (name.size() < 14 || name.rfind("events-", 0) != 0 ||
          name.substr(name.size() - 6) != ".jsonl")
        continue;
      const std::string number = name.substr(7, name.size() - 7 - 6);
      uint32_t chunkNumber = 0;
      if (!parseUnsigned(number, chunkNumber) ||
          !isClosedChunk(boot, chunkNumber))
        continue;
      char path[220] = {};
      snprintf(path, sizeof(path), "%s/%s", directory, name.c_str());
      struct stat metadata = {};
      if (::stat(path, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
          metadata.st_size <= 0 ||
          static_cast<uint64_t>(metadata.st_size) > kChunkBytes) {
        continue;
      }
      Chunk candidate = {boot, chunkNumber,
                         static_cast<uint32_t>(metadata.st_size), path, {}};
      if (chunks.size() < kMaximumChunks) {
        chunks.push_back(std::move(candidate));
      } else {
        auto oldest = std::min_element(chunks.begin(), chunks.end(), chunkOlder);
        if (oldest != chunks.end() && chunkOlder(*oldest, candidate))
          *oldest = std::move(candidate);
      }
    }
    closedir(dir);
  }
  closedir(boots);
  std::sort(chunks.begin(), chunks.end(), chunkOlder);
  for (auto chunk = chunks.begin(); chunk != chunks.end();) {
    uint32_t bytes = 0;
    std::string digest;
    if (!sha256File(chunk->path.c_str(), digest, bytes) || bytes == 0 ||
        bytes > kChunkBytes) {
      chunk = chunks.erase(chunk);
      continue;
    }
    chunk->bytes = bytes;
    chunk->sha256 = std::move(digest);
    ++chunk;
  }
  return chunks;
}

bool sendBody(WiFiClient &client, const std::string &body,
              const char *contentType) {
  return device_transfer::sendHttpHead(client, 200, body.size(), contentType) &&
         device_transfer::writeHttpBytes(
             client, reinterpret_cast<const uint8_t *>(body.data()), body.size());
}

bool sendFile(WiFiClient &client, const Chunk &chunk) {
  FILE *file = storage.open(chunk.path.c_str(), "rb");
  if (file == nullptr)
    return device_transfer::sendHttpError(client, 404, "chunk_missing",
                                          "diagnostic chunk is unavailable");
  if (!device_transfer::sendHttpHead(client, 200, chunk.bytes, "application/x-ndjson")) {
    storage.close(file);
    return false;
  }
  uint8_t buffer[4096];
  while (true) {
    const size_t count = storage.read(file, buffer, sizeof(buffer));
    if (count == 0)
      break;
    if (!device_transfer::writeHttpBytes(client, buffer, count)) {
      storage.close(file);
      return false;
    }
  }
  storage.close(file);
  return true;
}

bool resolveClosedChunk(uint32_t boot, uint32_t number, Chunk &chunk) {
  if (!isClosedChunk(boot, number))
    return false;
  char path[220] = {};
  snprintf(path, sizeof(path),
           "/sdcard/BICINO/DIAGNOSTICS/v1/boots/%lu/events-%06lu.jsonl",
           static_cast<unsigned long>(boot),
           static_cast<unsigned long>(number));
  struct stat metadata = {};
  if (::stat(path, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
      metadata.st_size <= 0 ||
      static_cast<uint64_t>(metadata.st_size) > kChunkBytes) {
    return false;
  }
  chunk.boot = boot;
  chunk.number = number;
  chunk.bytes = static_cast<uint32_t>(metadata.st_size);
  chunk.path = path;
  return true;
}

} // namespace

RideDiagnosticsHttp::RideDiagnosticsHttp(device_transfer::HttpTransferServer *server)
    : server_(server) {}

void RideDiagnosticsHttp::configure(device_transfer::HttpTransferServer *server) {
  server_ = server;
}

bool RideDiagnosticsHttp::handleRequest(
    const device_transfer::HttpRequest &request, WiFiClient &client) {
  if (server_ == nullptr || !server_->isRequestAuthorized(request) ||
      server_->status().mode != "diagnostics") {
    device_transfer::sendHttpError(client, 401, "unauthorized",
                                   "diagnostics session is not authorized");
    return true;
  }
  if (request.path == std::string(kPrefix) + "status" &&
      request.method == "GET") {
    const Stats snapshot = stats();
    const std::string body =
        "{\"schema\":1,\"ready\":true,\"bootSequence\":" +
        std::to_string(currentBootSequence()) +
        ",\"activeChunk\":" + std::to_string(currentActiveChunk()) +
        ",\"storageAvailable\":" +
        (snapshot.storageAvailable ? "true" : "false") + "}";
    return sendBody(client, body, "application/json");
  }
  if (request.path == std::string(kPrefix) + "index" && request.method == "GET") {
    const std::vector<Chunk> chunks = listChunks();
    const Stats snapshot = stats();
    std::string body = "{\"schema\":1,\"source\":\"firmware\",\"bootSequence\":" +
                       std::to_string(currentBootSequence()) +
                       ",\"activeChunk\":" + std::to_string(currentActiveChunk()) +
                       ",\"stats\":{\"enqueued\":" + std::to_string(snapshot.enqueued) +
                       ",\"written\":" + std::to_string(snapshot.written) +
                       ",\"dropped\":" + std::to_string(snapshot.dropped) +
                       ",\"storageErrors\":" + std::to_string(snapshot.storageErrors) +
                       "},\"chunks\":[";
    for (std::size_t index = 0; index < chunks.size(); ++index) {
      if (index != 0)
        body += ',';
      const Chunk &chunk = chunks[index];
      body += "{\"bootSequence\":" + std::to_string(chunk.boot) +
              ",\"chunk\":" + std::to_string(chunk.number) +
              ",\"bytes\":" + std::to_string(chunk.bytes) +
              ",\"sha256\":\"" + chunk.sha256 + "\"}";
      if (body.size() > kMaximumIndexBytes)
        return device_transfer::sendHttpError(client, 413, "index_too_large",
                                              "diagnostic index exceeds the response limit");
    }
    body += "]}";
    return sendBody(client, body, "application/json");
  }

  const std::string chunkPrefix = std::string(kPrefix) + "chunks/";
  if (request.method == "GET" && request.path.rfind(chunkPrefix, 0) == 0) {
    const std::string rest = request.path.substr(chunkPrefix.size());
    const std::size_t slash = rest.find('/');
    if (slash == std::string::npos || rest.find('/', slash + 1) != std::string::npos)
      return device_transfer::sendHttpError(client, 400, "invalid_chunk_path",
                                            "chunk path is invalid");
    uint32_t boot = 0;
    uint32_t number = 0;
    if (!parseUnsigned(rest.substr(0, slash), boot) ||
        !parseUnsigned(rest.substr(slash + 1), number) ||
        !isClosedChunk(boot, number))
      return device_transfer::sendHttpError(client, 404, "chunk_unavailable",
                                            "diagnostic chunk is unavailable");
    Chunk chunk;
    if (!resolveClosedChunk(boot, number, chunk))
      return device_transfer::sendHttpError(client, 404, "chunk_unavailable",
                                            "diagnostic chunk is unavailable");
    return sendFile(client, chunk);
  }

  if (request.path == std::string(kPrefix) + "active-tail" && request.method == "GET") {
    return device_transfer::sendHttpError(client, 404, "active_tail_disabled",
                                          "active diagnostic tail is not exposed");
  }

  if (request.path == std::string(kPrefix) + "session/exit" && request.method == "POST") {
    if (request.hasContentLength && request.contentLength != 0)
      return device_transfer::sendHttpError(client, 400, "body_not_allowed",
                                            "session exit does not accept a body");
    exitAfterResponse_ = true;
    return sendBody(client, "{\"ok\":true}", "application/json");
  }

  return device_transfer::sendHttpError(client, 404, "not_found",
                                        "diagnostic endpoint not found");
}

void RideDiagnosticsHttp::responseDidComplete(
    const device_transfer::HttpRequest &, bool peerClosedCleanly) {
  if (exitAfterResponse_ && peerClosedCleanly && server_ != nullptr) {
    exitAfterResponse_ = false;
    server_->setEnabled(false);
  }
}

} // namespace ride_diagnostics
