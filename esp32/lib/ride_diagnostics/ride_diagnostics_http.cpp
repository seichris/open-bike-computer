#include "ride_diagnostics_http.hpp"

#include "../storage/storage.hpp"
#include "ride_diagnostics.hpp"
#include "ride_diagnostics_http_policy.hpp"
#include "ride_diagnostics_index_policy.hpp"

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

struct ChunkIndex {
  std::vector<Chunk> chunks;
  bool readable = true;
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

bool requestStillAuthorized(
    device_transfer::HttpTransferServer *server,
    const device_transfer::HttpRequest &request) {
  return server != nullptr && server->isRequestAuthorized(request) &&
         server->status().mode == "diagnostics";
}

bool sha256File(const char *path, std::string &out, uint32_t &bytes,
                device_transfer::HttpTransferServer *server,
                const device_transfer::HttpRequest &request) {
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
    if (!requestStillAuthorized(server, request)) {
      ok = false;
      break;
    }
    const size_t count = storage.read(file, buffer, sizeof(buffer));
    if (count == 0) {
      if (storage.hasError(file))
        ok = false;
      break;
    }
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
  if (storage.close(file) != 0)
    ok = false;
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

ChunkIndex listChunks(
    device_transfer::HttpTransferServer *server,
    const device_transfer::HttpRequest &request) {
  ChunkIndex index;
  std::vector<Chunk> &chunks = index.chunks;
  chunks.reserve(kMaximumChunks);
  char bootsRoot[192] = {};
  snprintf(bootsRoot, sizeof(bootsRoot),
           "%s/BICINO/DIAGNOSTICS/v1/boots",
           storage.diagnosticsRootPath());
  DIR *boots = opendir(bootsRoot);
  if (boots == nullptr) {
    index.readable = false;
    return index;
  }
  while (struct dirent *bootEntry = readdir(boots)) {
    if (!requestStillAuthorized(server, request)) {
      closedir(boots);
      index.readable = false;
      return index;
    }
    uint32_t boot = 0;
    if (!parseUnsigned(bootEntry->d_name, boot))
      continue;
    char directory[192] = {};
    snprintf(directory, sizeof(directory), "%s/%s", bootsRoot,
             bootEntry->d_name);
    DIR *dir = opendir(directory);
    if (dir == nullptr) {
      index.readable = false;
      continue;
    }
    while (struct dirent *entry = readdir(dir)) {
      if (!requestStillAuthorized(server, request)) {
        closedir(dir);
        closedir(boots);
        index.readable = false;
        return index;
      }
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
      if (::stat(path, &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
        index.readable = false;
        continue;
      }
      const index_policy::CandidateDisposition disposition =
          index_policy::classifyCandidate(metadata.st_size, kChunkBytes);
      // FAT can retain a zero-byte crash artifact when power is lost between
      // create and the first complete JSONL write. It contains no evidence and
      // is deliberately omitted. Non-empty invalid candidates fail the index
      // instead of being silently hidden from the phone.
      if (disposition == index_policy::CandidateDisposition::IgnoreEmpty)
        continue;
      if (disposition == index_policy::CandidateDisposition::Reject) {
        index.readable = false;
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
    if (!sha256File(chunk->path.c_str(), digest, bytes, server, request) ||
        bytes == 0 ||
        bytes != chunk->bytes || bytes > kChunkBytes) {
      index.readable = false;
      chunk = chunks.erase(chunk);
      continue;
    }
    chunk->bytes = bytes;
    chunk->sha256 = std::move(digest);
    ++chunk;
  }
  return index;
}

bool sendBody(WiFiClient &client, const std::string &body,
              const char *contentType,
              device_transfer::HttpTransferServer *server,
              const device_transfer::HttpRequest &request) {
  if (!requestStillAuthorized(server, request) ||
      !device_transfer::sendHttpHead(client, 200, body.size(), contentType)) {
    return false;
  }
  std::size_t offset = 0;
  while (offset < body.size()) {
    if (!requestStillAuthorized(server, request)) {
      client.stop();
      return false;
    }
    const std::size_t count =
        std::min<std::size_t>(4096, body.size() - offset);
    if (!device_transfer::writeHttpBytes(
            client,
            reinterpret_cast<const uint8_t *>(body.data() + offset),
            count)) {
      return false;
    }
    offset += count;
  }
  return true;
}

bool sendFile(WiFiClient &client, const Chunk &chunk,
              device_transfer::HttpTransferServer *server,
              const device_transfer::HttpRequest &request) {
  if (!requestStillAuthorized(server, request)) {
    client.stop();
    return false;
  }
  FILE *file = storage.open(chunk.path.c_str(), "rb");
  if (file == nullptr)
    return device_transfer::sendHttpError(client, 404, "chunk_missing",
                                          "diagnostic chunk is unavailable");
  if (!device_transfer::sendHttpHead(client, 200, chunk.bytes, "application/x-ndjson")) {
    storage.close(file);
    return false;
  }
  uint8_t buffer[4096];
  uint32_t sent = 0;
  while (sent < chunk.bytes) {
    if (!requestStillAuthorized(server, request)) {
      storage.close(file);
      client.stop();
      return false;
    }
    const size_t remaining = chunk.bytes - sent;
    const size_t count =
        storage.read(file, buffer, std::min(remaining, sizeof(buffer)));
    if (count == 0 || storage.hasError(file)) {
      storage.close(file);
      return false;
    }
    if (!device_transfer::writeHttpBytes(client, buffer, count)) {
      storage.close(file);
      return false;
    }
    sent += static_cast<uint32_t>(count);
  }
  return sent == chunk.bytes && storage.close(file) == 0;
}

bool resolveClosedChunk(uint32_t boot, uint32_t number, Chunk &chunk) {
  if (!isClosedChunk(boot, number))
    return false;
  char path[220] = {};
  snprintf(path, sizeof(path),
           "%s/BICINO/DIAGNOSTICS/v1/boots/%lu/events-%06lu.jsonl",
           storage.diagnosticsRootPath(),
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
  exitAfterResponse_ = false;
  endTransferSnapshotLease();
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
  const http_policy::Route route =
      http_policy::parseRoute(request.method, request.path, kPrefix);
  if (route.kind != http_policy::RouteKind::Exit) {
    // A prior peer may have failed to close its exit response cleanly. Any
    // authenticated non-exit request belongs to the live session and cancels
    // that stale deferred shutdown.
    exitAfterResponse_ = false;
    refreshTransferSnapshotLease();
  }
  if (route.kind == http_policy::RouteKind::Unknown) {
    return device_transfer::sendHttpError(client, 404, "not_found",
                                          "diagnostic endpoint not found");
  }
  if (route.kind == http_policy::RouteKind::Status) {
    const Stats snapshot = stats();
    const std::string body =
        "{\"schema\":1,\"ready\":true,\"bootSequence\":" +
        std::to_string(currentBootSequence()) +
        ",\"activeChunk\":" + std::to_string(currentActiveChunk()) +
        ",\"storageAvailable\":" +
        (snapshot.storageAvailable ? "true" : "false") + "}";
    return sendBody(client, body, "application/json", server_, request);
  }
  if (route.kind == http_policy::RouteKind::Index) {
    beginTransferSnapshotLease();
    const ChunkIndex index = listChunks(server_, request);
    if (!requestStillAuthorized(server_, request)) {
      endTransferSnapshotLease();
      client.stop();
      return false;
    }
    if (!index.readable) {
      endTransferSnapshotLease();
      return device_transfer::sendHttpError(
          client, 500, "diagnostics_index_unreadable",
          "one or more non-empty diagnostic chunks could not be read safely");
    }
    const std::vector<Chunk> &chunks = index.chunks;
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
      if (!requestStillAuthorized(server_, request)) {
        endTransferSnapshotLease();
        client.stop();
        return false;
      }
      if (index != 0)
        body += ',';
      const Chunk &chunk = chunks[index];
      body += "{\"bootSequence\":" + std::to_string(chunk.boot) +
              ",\"chunk\":" + std::to_string(chunk.number) +
              ",\"bytes\":" + std::to_string(chunk.bytes) +
              ",\"sha256\":\"" + chunk.sha256 + "\"}";
      if (body.size() > kMaximumIndexBytes) {
        endTransferSnapshotLease();
        return device_transfer::sendHttpError(client, 413, "index_too_large",
                                              "diagnostic index exceeds the response limit");
      }
    }
    body += "]}";
    return sendBody(client, body, "application/json", server_, request);
  }

  if (route.kind == http_policy::RouteKind::Chunk) {
    if (!isClosedChunk(route.boot, route.chunk))
      return device_transfer::sendHttpError(client, 404, "chunk_unavailable",
                                            "diagnostic chunk is unavailable");
    Chunk chunk;
    if (!resolveClosedChunk(route.boot, route.chunk, chunk))
      return device_transfer::sendHttpError(client, 404, "chunk_unavailable",
                                            "diagnostic chunk is unavailable");
    return sendFile(client, chunk, server_, request);
  }

  if (route.kind == http_policy::RouteKind::ActiveTail) {
    return device_transfer::sendHttpError(client, 404, "active_tail_disabled",
                                          "active diagnostic tail is not exposed");
  }

  if (route.kind == http_policy::RouteKind::Exit) {
    if (request.hasContentLength && request.contentLength != 0)
      return device_transfer::sendHttpError(client, 400, "body_not_allowed",
                                            "session exit does not accept a body");
    exitAfterResponse_ = true;
    endTransferSnapshotLease();
    return sendBody(client, "{\"ok\":true}", "application/json", server_,
                    request);
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
