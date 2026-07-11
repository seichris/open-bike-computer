#include "map_transfer.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <cctype>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace map_transfer {
namespace {

constexpr const char *kVectMapPrefix = "VECTMAP/";
constexpr const char *kActiveMapFile = "/VECTMAP/active-map.json";
constexpr const char *kActivationTransactionFile =
    "/VECTMAP/.activation-transaction.json";
constexpr const char *kInstalledManifestFile = ".manifest.json";
constexpr const char *kInstalledReceiptFile = ".verified.sha256";
constexpr size_t kMaxManifestBytes = 64 * 1024;

static std::string joinPath(const std::string &a, const std::string &b) {
  if (a.empty())
    return b;
  if (b.empty())
    return a;
  if (a.back() == '/')
    return a + (b.front() == '/' ? b.substr(1) : b);
  return a + "/" + (b.front() == '/' ? b.substr(1) : b);
}

static std::string dirnameOf(const std::string &path) {
  size_t slash = path.find_last_of('/');
  if (slash == std::string::npos)
    return "";
  if (slash == 0)
    return "/";
  return path.substr(0, slash);
}

static std::string jsonEscape(const std::string &value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (char c : value) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(c);
    } else if (c == '\n') {
      out += "\\n";
    } else if (c == '\r') {
      out += "\\r";
    } else {
      out.push_back(c);
    }
  }
  return out;
}

static bool startsWith(const std::string &value, const std::string &prefix) {
  return value.size() >= prefix.size() &&
         value.compare(0, prefix.size(), prefix) == 0;
}

static std::string jsonStringValue(const std::string &json,
                                   const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos)
    return "";
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos)
    return "";
  pos = json.find('"', pos + 1);
  if (pos == std::string::npos)
    return "";
  std::string out;
  bool escaped = false;
  for (size_t i = pos + 1; i < json.size(); i++) {
    char c = json[i];
    if (escaped) {
      out.push_back(c);
      escaped = false;
      continue;
    }
    if (c == '\\') {
      escaped = true;
      continue;
    }
    if (c == '"')
      return out;
    out.push_back(c);
  }
  return "";
}

static uint64_t jsonUintValue(const std::string &json,
                              const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos)
    return 0;
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos)
    return 0;
  pos++;
  while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\n' ||
                               json[pos] == '\t' || json[pos] == '\r')) {
    pos++;
  }
  uint64_t value = 0;
  while (pos < json.size() && json[pos] >= '0' && json[pos] <= '9') {
    value = value * 10 + static_cast<uint64_t>(json[pos] - '0');
    pos++;
  }
  return value;
}

static std::vector<std::string> fileObjects(const std::string &json) {
  std::vector<std::string> objects;
  size_t filesPos = json.find("\"files\"");
  if (filesPos == std::string::npos)
    return objects;
  size_t arrayStart = json.find('[', filesPos);
  if (arrayStart == std::string::npos)
    return objects;

  int arrayDepth = 0;
  int objectDepth = 0;
  bool inString = false;
  bool escaped = false;
  size_t objectStart = std::string::npos;

  for (size_t i = arrayStart; i < json.size(); i++) {
    char c = json[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == '\\' && inString) {
      escaped = true;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      continue;
    }
    if (inString)
      continue;
    if (c == '[')
      arrayDepth++;
    else if (c == ']') {
      arrayDepth--;
      if (arrayDepth == 0)
        break;
    } else if (c == '{') {
      if (arrayDepth == 1 && objectDepth == 0)
        objectStart = i;
      objectDepth++;
    } else if (c == '}') {
      objectDepth--;
      if (arrayDepth == 1 && objectDepth == 0 &&
          objectStart != std::string::npos) {
        objects.push_back(json.substr(objectStart, i - objectStart + 1));
        objectStart = std::string::npos;
      }
    }
  }
  return objects;
}

static std::string publishPathFor(const std::string &manifestPath,
                                  const std::string &mapId) {
  const std::string mapPrefix = std::string(kVectMapPrefix) + mapId + "/";
  if (startsWith(manifestPath, mapPrefix)) {
    return std::string(kVectMapPrefix) + manifestPath.substr(mapPrefix.size());
  }
  return manifestPath;
}

static bool isHexSha256(const std::string &value) {
  if (value.size() != 64)
    return false;
  for (char c : value) {
    bool digit = c >= '0' && c <= '9';
    bool lower = c >= 'a' && c <= 'f';
    bool upper = c >= 'A' && c <= 'F';
    if (!digit && !lower && !upper)
      return false;
  }
  return true;
}

static bool hasHiddenPathComponent(const std::string &path) {
  std::stringstream stream(path);
  std::string part;
  while (std::getline(stream, part, '/')) {
    if (!part.empty() && part[0] == '.')
      return true;
  }
  return false;
}

static uint32_t rotr(uint32_t value, uint32_t bits) {
  return (value >> bits) | (value << (32 - bits));
}

static const uint32_t kSha256RoundConstants[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
    0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
    0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
    0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
    0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
    0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
    0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
    0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
    0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

} // namespace

void Sha256Hasher::update(const uint8_t *data, size_t len) {
  totalLen_ += len;
  while (len > 0) {
    size_t n = std::min(len, block_.size() - blockLen_);
    memcpy(block_.data() + blockLen_, data, n);
    blockLen_ += n;
    data += n;
    len -= n;
    if (blockLen_ == block_.size()) {
      transform(block_.data());
      blockLen_ = 0;
    }
  }
}

std::string Sha256Hasher::finalHex() {
  uint64_t bitLen = totalLen_ * 8;
  uint8_t one = 0x80;
  update(&one, 1);
  uint8_t zero = 0;
  while (blockLen_ != 56)
    update(&zero, 1);
  uint8_t lengthBytes[8];
  for (int i = 0; i < 8; i++)
    lengthBytes[i] = static_cast<uint8_t>(bitLen >> (56 - (i * 8)));
  update(lengthBytes, sizeof(lengthBytes));

  static const char hex[] = "0123456789abcdef";
  std::string out;
  out.reserve(64);
  for (uint32_t word : h_) {
    for (int shift = 28; shift >= 0; shift -= 4)
      out.push_back(hex[(word >> shift) & 0x0F]);
  }
  return out;
}

void Sha256Hasher::transform(const uint8_t *chunk) {
  uint32_t w[64] = {};
  for (int i = 0; i < 16; i++) {
    size_t j = static_cast<size_t>(i) * 4;
    w[i] = (static_cast<uint32_t>(chunk[j]) << 24) |
           (static_cast<uint32_t>(chunk[j + 1]) << 16) |
           (static_cast<uint32_t>(chunk[j + 2]) << 8) |
           static_cast<uint32_t>(chunk[j + 3]);
  }
  for (int i = 16; i < 64; i++) {
    uint32_t s0 =
        rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 =
        rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }

  uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3];
  uint32_t e = h_[4], f = h_[5], g = h_[6], hh = h_[7];
  for (int i = 0; i < 64; i++) {
    uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    uint32_t ch = (e & f) ^ ((~e) & g);
    uint32_t temp1 = hh + s1 + ch + kSha256RoundConstants[i] + w[i];
    uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t temp2 = s0 + maj;
    hh = g;
    g = f;
    f = e;
    e = d + temp1;
    d = c;
    c = b;
    b = a;
    a = temp1 + temp2;
  }
  h_[0] += a;
  h_[1] += b;
  h_[2] += c;
  h_[3] += d;
  h_[4] += e;
  h_[5] += f;
  h_[6] += g;
  h_[7] += hh;
}

std::string sha256Hex(const uint8_t *data, size_t len) {
  Sha256Hasher sha;
  sha.update(data, len);
  return sha.finalHex();
}

ActivationBeginResult MapActivationState::begin(const std::string &sessionId) {
  if (state_.running) {
    return state_.sessionId == sessionId
               ? ActivationBeginResult::AlreadyRunning
               : ActivationBeginResult::Busy;
  }
  state_.running = true;
  state_.sequence++;
  if (state_.sequence == 0)
    state_.sequence = 1;
  state_.status = "activating";
  state_.sessionId = sessionId;
  state_.mapId.clear();
  state_.errorCode.clear();
  state_.errorMessage.clear();
  return ActivationBeginResult::Started;
}

void MapActivationState::finish(const std::string &status,
                                const std::string &mapId,
                                const std::string &errorCode,
                                const std::string &errorMessage) {
  state_.running = false;
  state_.status = status;
  state_.mapId = mapId;
  state_.errorCode = errorCode;
  state_.errorMessage = errorMessage;
}

bool MapActivationState::acceptsUploads() const { return !state_.running; }

MapActivationSnapshot MapActivationState::snapshot() const { return state_; }

std::string MapActivationState::json(bool compact) const {
  std::string body = std::string("{\"status\":\"") +
                     jsonEscape(state_.status) + "\",\"sequence\":" +
                     std::to_string(state_.sequence);
  if (!state_.sessionId.empty())
    body += ",\"sessionId\":\"" + jsonEscape(state_.sessionId) + "\"";
  if (!compact && !state_.mapId.empty())
    body += ",\"mapId\":\"" + jsonEscape(state_.mapId) + "\"";
  if (!state_.errorCode.empty()) {
    body += ",\"error\":{\"code\":\"" + jsonEscape(state_.errorCode) + "\"";
    if (!compact && !state_.errorMessage.empty())
      body += ",\"message\":\"" + jsonEscape(state_.errorMessage) + "\"";
    body += "}";
  }
  body += "}";
  return body;
}

MapTransferInstaller::MapTransferInstaller(std::string storageRoot)
    : storageRoot_(std::move(storageRoot)) {
  if (!storageRoot_.empty() && storageRoot_.back() == '/')
    storageRoot_.pop_back();
}

InstallStatus MapTransferInstaller::validateManifestText(
    const std::string &manifestText, MapManifest &manifest) const {
  manifest = MapManifest();
  if (manifestText.empty() || manifestText.size() > kMaxManifestBytes)
    return fail("manifest_size", "manifest size is invalid");

  manifest.schemaVersion =
      static_cast<uint32_t>(jsonUintValue(manifestText, "schemaVersion"));
  manifest.mapId = jsonStringValue(manifestText, "mapId");
  if (manifest.schemaVersion != 1)
    return fail("manifest_schema", "unsupported manifest schema version");
  if (!safeId(manifest.mapId))
    return fail("manifest_map_id", "mapId contains unsafe characters");

  for (const std::string &object : fileObjects(manifestText)) {
    ManifestFile file;
    file.path = jsonStringValue(object, "path");
    file.sha256 = jsonStringValue(object, "sha256");
    file.bytes = jsonUintValue(object, "bytes");
    file.publishPath = publishPathFor(file.path, manifest.mapId);
    const std::string mapPrefix = std::string(kVectMapPrefix) + manifest.mapId + "/";
    if (!safeRelativePath(file.path) || !safeRelativePath(file.publishPath))
      return fail("manifest_path", "manifest contains unsafe file path");
    if (!startsWith(file.path, mapPrefix) ||
        !startsWith(file.publishPath, kVectMapPrefix))
      return fail("manifest_path",
                  "map files must live under VECTMAP/<mapId>");
    if (hasHiddenPathComponent(file.publishPath))
      return fail("manifest_path", "map files may not use hidden folders");
    if (file.publishPath == std::string(kActiveMapFile).substr(1))
      return fail("manifest_path", "manifest may not overwrite active map");
    if (!(file.path.size() >= 4 &&
          (file.path.rfind(".fmb") == file.path.size() - 4 ||
           file.path.rfind(".fmp") == file.path.size() - 4)))
      return fail("manifest_path", "map files must be .fmb or .fmp");
    if (!isHexSha256(file.sha256))
      return fail("manifest_sha256", "map file sha256 is invalid");
    manifest.files.push_back(file);
  }
  if (manifest.files.empty())
    return fail("manifest_files", "manifest contains no map files");
  return {true, "ok", ""};
}

InstallStatus MapTransferInstaller::readStagedManifest(
    const std::string &sessionId, MapManifest &manifest) const {
  if (!safeId(sessionId))
    return fail("session_id", "session id contains unsafe characters");
  std::string manifestText;
  if (!readTextFile(joinPath(stagingRoot(sessionId), "manifest.json"),
                    manifestText, kMaxManifestBytes)) {
    return fail("manifest_missing", "staged manifest is missing");
  }
  return validateManifestText(manifestText, manifest);
}

InstallStatus
MapTransferInstaller::validateStagedMap(const std::string &sessionId,
                                        MapManifest &manifest) const {
  InstallStatus parsed = readStagedManifest(sessionId, manifest);
  if (!parsed.ok)
    return parsed;

  for (const ManifestFile &file : manifest.files) {
    const std::string stagedPath = joinPath(stagingRoot(sessionId), file.path);
    uint64_t size = 0;
    if (!fileSize(stagedPath, size))
      return fail("file_missing", "staged map file is missing: " + file.path);
    if (size != file.bytes)
      return fail("file_size", "staged map file size mismatch: " + file.path);
    if (!stagedFileVerified(sessionId, file)) {
      // Compatibility path for a transfer staged by older firmware. New
      // uploads are hashed while streaming and only reach activation with a
      // verification receipt, so the normal activation path performs no
      // full-file reads.
      std::string sha;
      if (!fileSha256Hex(stagedPath, sha))
        return fail("file_sha256",
                    "could not hash staged map file: " + file.path);
      std::transform(sha.begin(), sha.end(), sha.begin(), ::tolower);
      std::string expected = file.sha256;
      std::transform(expected.begin(), expected.end(), expected.begin(),
                     ::tolower);
      if (sha != expected)
        return fail("file_sha256",
                    "staged map file sha256 mismatch: " + file.path);
      if (!markStagedFileVerified(sessionId, file))
        return fail("file_receipt",
                    "could not record staged map verification: " + file.path);
    }
  }
  return {true, "ok", ""};
}

InstallStatus MapTransferInstaller::expectedStagedFile(
    const std::string &sessionId, const std::string &path,
    ManifestFile &file) const {
  if (!safeId(sessionId) || !safeRelativePath(path))
    return fail("path", "staged map path is invalid");
  MapManifest manifest;
  InstallStatus parsed = readStagedManifest(sessionId, manifest);
  if (!parsed.ok)
    return parsed;
  for (const ManifestFile &candidate : manifest.files) {
    if (candidate.path == path) {
      file = candidate;
      return {true, "ok", ""};
    }
  }
  return fail("manifest_path", "file is not declared by the staged manifest");
}

bool MapTransferInstaller::stagedFileVerified(
    const std::string &sessionId, const ManifestFile &file) const {
  uint64_t size = 0;
  if (!fileSize(joinPath(stagingRoot(sessionId), file.path), size) ||
      size != file.bytes) {
    return false;
  }
  std::string receipt;
  if (!readTextFile(verificationPath(sessionId, file), receipt, 64))
    return false;
  std::transform(receipt.begin(), receipt.end(), receipt.begin(), ::tolower);
  std::string expected = file.sha256;
  std::transform(expected.begin(), expected.end(), expected.begin(), ::tolower);
  return receipt == expected;
}

bool MapTransferInstaller::markStagedFileVerified(
    const std::string &sessionId, const ManifestFile &file) const {
  if (!safeId(sessionId) || !safeRelativePath(file.path) ||
      !isHexSha256(file.sha256)) {
    return false;
  }
  std::string sha = file.sha256;
  std::transform(sha.begin(), sha.end(), sha.begin(), ::tolower);
  return writeTextFileAtomic(verificationPath(sessionId, file), sha);
}

void MapTransferInstaller::clearStagedFileVerification(
    const std::string &sessionId, const ManifestFile &file) const {
  removeTree(verificationPath(sessionId, file));
  removeTree(verificationPath(sessionId, file) + ".bak");
  removeTree(verificationPath(sessionId, file) + ".tmp");
}

InstallStatus MapTransferInstaller::activateStagedMap(
    const std::string &sessionId, const MapManifest &manifest) const {
  if (!safeId(sessionId))
    return fail("session_id", "session id contains unsafe characters");
  if (!safeId(manifest.mapId))
    return fail("manifest_map_id", "mapId contains unsafe characters");

  const std::string transactionPath =
      joinPath(storageRoot_, kActivationTransactionFile);
  const std::string baseRoot = std::string("/VECTMAP/.maps/") + sessionId;
  std::string root = baseRoot;

  ActiveMapSelection previous;
  InstallStatus previousStatus = readActiveMap(previous);
  if (!previousStatus.ok && previousStatus.code != "active_missing")
    return previousStatus;
  if (previousStatus.ok && previous.sessionId == sessionId) {
    const bool stagedReplacement =
        fileExists(joinPath(stagingRoot(sessionId), "manifest.json"));
    if (!stagedReplacement &&
        installedMapReceiptMatches(previous.root, manifest)) {
      removeTree(stagingRoot(sessionId));
      return {true, "ok", ""};
    }
    const std::string repairDigest = sha256Hex(
        reinterpret_cast<const uint8_t *>(sessionId.data()), sessionId.size());
    const std::string repairName =
        sessionId.substr(0, 63) + "-repair-" + repairDigest.substr(0, 8);
    const std::string repairRoot = std::string("/VECTMAP/.maps/") + repairName;
    root = previous.root == repairRoot ? baseRoot : repairRoot;
  }
  const std::string destinationRoot = joinPath(storageRoot_, root);

  const auto transactionJson = [&](const char *phase) {
    return std::string("{\"sessionId\":\"") + sessionId +
           "\",\"mapId\":\"" + manifest.mapId + "\",\"root\":\"" + root +
           "\",\"previousMapId\":\"" + jsonEscape(previous.mapId) +
           "\",\"previousSessionId\":\"" +
           jsonEscape(previous.sessionId) + "\",\"previousRoot\":\"" +
           jsonEscape(previous.root) + "\",\"phase\":\"" + phase +
           "\"}\n";
  };
  const auto abandonNewRoot = [&]() {
    const bool cleaned = removeTree(destinationRoot) &&
                         removeTree(stagingRoot(sessionId)) &&
                         removeTree(transactionPath + ".bak") &&
                         removeTree(transactionPath + ".tmp");
    return cleaned && removeTree(transactionPath);
  };

  if (!removeTree(destinationRoot))
    return fail("install_cleanup", "could not clear incomplete map version");
  if (!writeTextFileAtomic(transactionPath, transactionJson("publishing"))) {
    return fail("transaction", "could not start map activation transaction");
  }
  if (!publishStagedFiles(sessionId, manifest, destinationRoot)) {
    abandonNewRoot();
    return fail("publish_move", "could not publish verified map files");
  }
  if (!publishInstalledMetadata(sessionId, manifest, destinationRoot)) {
    abandonNewRoot();
    return fail("publish_metadata", "could not publish map verification metadata");
  }
  if (!writeTextFileAtomic(transactionPath, transactionJson("ready"))) {
    abandonNewRoot();
    return fail("transaction", "could not prepare map activation switch");
  }

  ActiveMapSelection selected;
  selected.mapId = manifest.mapId;
  selected.sessionId = sessionId;
  selected.root = root;
  if (previousStatus.ok) {
    selected.previousMapId = previous.mapId;
    selected.previousSessionId = previous.sessionId;
    selected.previousRoot = previous.root;
  }
  if (!writeActiveMap(selected)) {
    InstallStatus recovered = recoverInterruptedActivation();
    if (!recovered.ok)
      return fail("active_recovery", recovered.message);
    return fail("active_write", "could not select installed map version");
  }
  if (!writeTextFileAtomic(transactionPath, transactionJson("committed"))) {
    return {true, "cleanup_pending",
            "map selected; activation journal cleanup will retry"};
  }

  const bool cleanupComplete = removeTree(stagingRoot(sessionId)) &&
                               removeTree(transactionPath + ".bak") &&
                               removeTree(transactionPath + ".tmp");
  if (cleanupComplete && removeTree(transactionPath))
    return {true, "ok", ""};
  return {true, "cleanup_pending",
          "map installed; cleanup will retry after restart"};
}

InstallStatus MapTransferInstaller::recoverInterruptedActivation() const {
  const std::string transactionPath =
      joinPath(storageRoot_, kActivationTransactionFile);
  const std::string activePath = joinPath(storageRoot_, kActiveMapFile);
  std::string transaction;
  if (!readTextFile(transactionPath, transaction, 1024)) {
    const std::string backupPath = transactionPath + ".bak";
    if (!fileExists(backupPath)) {
      removeTree(transactionPath + ".tmp");
      ActiveMapSelection selected;
      InstallStatus active = readActiveMap(selected);
      if (!active.ok || activeRootExists(selected.root)) {
        if (active.ok || active.code == "active_missing")
          return {true, "ok", ""};
        if (active.code == "active_invalid") {
          const std::string activeBackup = activePath + ".bak";
          removeTree(activePath);
          if (fileExists(activeBackup) &&
              ::rename(activeBackup.c_str(), activePath.c_str()) == 0) {
            ActiveMapSelection backup;
            InstallStatus backupStatus = readActiveMap(backup);
            if (backupStatus.ok && activeRootExists(backup.root)) {
              removeTree(activePath + ".tmp");
              return {true, "recovered_rollback",
                      "restored valid active map metadata backup"};
            }
            removeTree(activePath);
          }
          removeTree(activeBackup);
          removeTree(activePath + ".tmp");
          return {true, "recovered_rollback",
                  "cleared invalid active map metadata"};
        }
        return active;
      }
      if (!selected.previousRoot.empty() &&
          activeRootExists(selected.previousRoot)) {
        ActiveMapSelection rollback;
        rollback.mapId = selected.previousMapId;
        rollback.sessionId = selected.previousSessionId;
        rollback.root = selected.previousRoot;
        if (!writeActiveMap(rollback))
          return fail("active_recovery", "could not restore previous map selection");
        return {true, "recovered_rollback",
                "restored previous map selection"};
      }
      if (!removeTree(activePath) || !removeTree(activePath + ".bak") ||
          !removeTree(activePath + ".tmp")) {
        return fail("active_recovery",
                    "could not clear missing active map selection");
      }
      return {true, "recovered_rollback",
              "cleared missing active map selection"};
    }
    if (::rename(backupPath.c_str(), transactionPath.c_str()) != 0 ||
        !readTextFile(transactionPath, transaction, 1024)) {
      return fail("transaction_recovery",
                  "could not recover map activation journal");
    }
  }

  const std::string sessionId = jsonStringValue(transaction, "sessionId");
  const std::string mapId = jsonStringValue(transaction, "mapId");
  const std::string root = jsonStringValue(transaction, "root");
  const std::string previousMapId =
      jsonStringValue(transaction, "previousMapId");
  const std::string previousSessionId =
      jsonStringValue(transaction, "previousSessionId");
  const std::string previousRoot =
      jsonStringValue(transaction, "previousRoot");
  const std::string phase = jsonStringValue(transaction, "phase");
  if (!safeId(sessionId) || !safeId(mapId) || !safeActiveRoot(root) ||
      (!previousRoot.empty() &&
       (!safeActiveRoot(previousRoot) || !safeId(previousMapId) ||
        (!previousSessionId.empty() && !safeId(previousSessionId)))) ||
      (phase != "publishing" && phase != "ready" && phase != "committed")) {
    const auto clearInvalidTransaction = [&]() {
      return removeTree(transactionPath) &&
             removeTree(transactionPath + ".bak") &&
             removeTree(transactionPath + ".tmp");
    };
    ActiveMapSelection selected;
    InstallStatus active = readActiveMap(selected);
    if (active.ok && selected.root != "/VECTMAP") {
      MapManifest installed;
      if (readInstalledManifest(selected.root, installed).ok &&
          installed.mapId == selected.mapId &&
          installedMapContentsMatch(selected.root, installed)) {
        if (!clearInvalidTransaction())
          return fail("transaction_invalid",
                      "could not clear invalid map activation transaction");
        return {true, "recovered_commit",
                "verified selected map after clearing invalid transaction"};
      }
      if (!selected.previousRoot.empty() &&
          activeRootExists(selected.previousRoot)) {
        ActiveMapSelection rollback;
        rollback.mapId = selected.previousMapId;
        rollback.sessionId = selected.previousSessionId;
        rollback.root = selected.previousRoot;
        if (!writeActiveMap(rollback))
          return fail("transaction_recovery",
                      "could not restore previous map after invalid transaction");
        if (!clearInvalidTransaction())
          return fail("transaction_invalid",
                      "could not clear invalid map activation transaction");
        if (!removeTree(joinPath(storageRoot_, selected.root)))
          return fail("transaction_cleanup",
                      "restored previous map but could not remove invalid version");
        return {true, "recovered_rollback",
                "restored previous map after invalid transaction"};
      }
      if (!removeTree(activePath)) {
        return fail("transaction_recovery",
                    "could not clear invalid selected map metadata");
      }
      if (!clearInvalidTransaction() ||
          !removeTree(joinPath(storageRoot_, selected.root))) {
        return fail("transaction_recovery",
                    "could not clear unverifiable map transaction");
      }
      return {true, "recovered_rollback",
              "discarded unverifiable map after invalid transaction"};
    }
    if (!clearInvalidTransaction())
      return fail("transaction_invalid",
                  "could not clear invalid map activation transaction");
    InstallStatus recovered = recoverInterruptedActivation();
    if (!recovered.ok)
      return recovered;
    return {true, "recovered_rollback",
            "cleared invalid map activation transaction"};
  }

  ActiveMapSelection active;
  InstallStatus activeStatus = readActiveMap(active);
  const bool activePointsToNewRoot = activeStatus.ok && active.root == root;
  const bool selectedNewRoot = activePointsToNewRoot &&
                               active.mapId == mapId &&
                               active.sessionId == sessionId;
  MapManifest installedManifest;
  const bool selectedRootVerified =
      selectedNewRoot && readInstalledManifest(root, installedManifest).ok &&
      installedManifest.mapId == mapId &&
      installedMapContentsMatch(root, installedManifest);
  if (selectedRootVerified) {
    const bool cleanupComplete = removeTree(stagingRoot(sessionId)) &&
                                 removeTree(activePath + ".bak") &&
                                 removeTree(activePath + ".tmp") &&
                                 removeTree(transactionPath + ".bak") &&
                                 removeTree(transactionPath + ".tmp");
    if (!cleanupComplete || !removeTree(transactionPath))
      return fail("transaction_cleanup", "could not finish map commit cleanup");
    return {true, "recovered_commit", "completed interrupted map commit"};
  }

  bool restoredPrevious = false;
  if ((!activeStatus.ok || activePointsToNewRoot) && !previousRoot.empty() &&
      activeRootExists(previousRoot)) {
    ActiveMapSelection rollback;
    rollback.mapId = previousMapId;
    rollback.sessionId = previousSessionId;
    rollback.root = previousRoot;
    if (!writeActiveMap(rollback))
      return fail("transaction_recovery", "could not restore previous map selection");
    restoredPrevious = true;
  }

  const bool discardInvalidActive = !activeStatus.ok &&
                                    activeStatus.code == "active_invalid" &&
                                    !restoredPrevious;
  const bool discardIncompleteSelection = activePointsToNewRoot &&
                                           !restoredPrevious;
  const bool cleanupComplete =
      (!(discardInvalidActive || discardIncompleteSelection) ||
       removeTree(activePath)) &&
      removeTree(joinPath(storageRoot_, root)) &&
      removeTree(stagingRoot(sessionId)) &&
      removeTree(activePath + ".bak") &&
      removeTree(activePath + ".tmp") &&
      removeTree(transactionPath + ".bak") &&
      removeTree(transactionPath + ".tmp");
  if (!cleanupComplete || !removeTree(transactionPath))
    return fail("transaction_cleanup",
                "could not clear interrupted map version");
  return {true, "recovered_rollback", "rolled back interrupted map activation"};
}

bool MapTransferInstaller::hasInterruptedActivation() const {
  const std::string transactionPath =
      joinPath(storageRoot_, kActivationTransactionFile);
  return fileExists(transactionPath) || fileExists(transactionPath + ".bak");
}

InstallStatus
MapTransferInstaller::readActiveMap(ActiveMapSelection &selection) const {
  selection = ActiveMapSelection();
  const std::string activePath = joinPath(storageRoot_, kActiveMapFile);
  std::string text;
  if (!readTextFile(activePath, text, 2048))
    return fail("active_missing", "active map metadata is missing");
  selection.mapId = jsonStringValue(text, "mapId");
  selection.sessionId = jsonStringValue(text, "sessionId");
  selection.root = jsonStringValue(text, "root");
  selection.previousMapId = jsonStringValue(text, "previousMapId");
  selection.previousSessionId = jsonStringValue(text, "previousSessionId");
  selection.previousRoot = jsonStringValue(text, "previousRoot");
  if (selection.root.empty())
    selection.root = "/VECTMAP";
  if (!safeId(selection.mapId) || !safeActiveRoot(selection.root) ||
      (!selection.sessionId.empty() && !safeId(selection.sessionId)) ||
      (!selection.previousRoot.empty() &&
       (!safeActiveRoot(selection.previousRoot) ||
        !safeId(selection.previousMapId) ||
        (!selection.previousSessionId.empty() &&
         !safeId(selection.previousSessionId)))) ||
      (selection.previousRoot.empty() &&
       (!selection.previousMapId.empty() ||
        !selection.previousSessionId.empty()))) {
    return fail("active_invalid", "active map metadata is invalid");
  }
  return {true, "ok", ""};
}

InstallStatus
MapTransferInstaller::readActiveMapId(std::string &mapId) const {
  ActiveMapSelection selection;
  InstallStatus status = readActiveMap(selection);
  if (status.ok)
    mapId = selection.mapId;
  return status;
}

bool MapTransferInstaller::pruneStagingSessions(
    const std::string &keepSessionId) const {
  if (!safeId(keepSessionId))
    return false;
  const std::string root = joinPath(storageRoot_, "VECTMAP/.staging");
  DIR *dir = ::opendir(root.c_str());
  if (!dir)
    return errno == ENOENT;
  bool ok = true;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    const std::string name = entry->d_name;
    if (name == "." || name == ".." || name == keepSessionId)
      continue;
    if (!safeId(name) || !removeTree(joinPath(root, name)))
      ok = false;
  }
  ::closedir(dir);
  return ok;
}

bool MapTransferInstaller::pruneObsoleteInstalledMaps() const {
  ActiveMapSelection selected;
  InstallStatus status = readActiveMap(selected);
  if (!status.ok && status.code != "active_missing")
    return false;
  const std::string root = joinPath(storageRoot_, "VECTMAP/.maps");
  DIR *dir = ::opendir(root.c_str());
  if (!dir)
    return errno == ENOENT;
  bool ok = true;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    const std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    const std::string candidate = std::string("/VECTMAP/.maps/") + name;
    if (candidate == selected.root)
      continue;
    if (!safeId(name) || !removeTree(joinPath(root, name)))
      ok = false;
  }
  ::closedir(dir);
  if (selected.root != "/VECTMAP" && selected.previousRoot == "/VECTMAP") {
    const std::string vectmapRoot = joinPath(storageRoot_, "VECTMAP");
    DIR *legacy = ::opendir(vectmapRoot.c_str());
    if (!legacy)
      return false;
    while ((entry = ::readdir(legacy)) != nullptr) {
      const std::string name = entry->d_name;
      if (name == "." || name == ".." || name[0] == '.' ||
          startsWith(name, "active-map.json")) {
        continue;
      }
      if (!removeTree(joinPath(vectmapRoot, name)))
        ok = false;
    }
    ::closedir(legacy);
  }
  return ok;
}

std::string MapTransferInstaller::stagingRoot(const std::string &sessionId) const {
  return joinPath(joinPath(storageRoot_, "VECTMAP/.staging"), sessionId);
}

InstallStatus MapTransferInstaller::fail(const std::string &code,
                                         const std::string &message) const {
  return {false, code, message};
}

bool MapTransferInstaller::safeId(const std::string &value) const {
  if (value.empty() || value.size() > 80 || value[0] == '.')
    return false;
  for (char c : value) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) {
      return false;
    }
  }
  return value.find("..") == std::string::npos;
}

bool MapTransferInstaller::safeActiveRoot(const std::string &value) const {
  if (value == "/VECTMAP")
    return true;
  const std::string prefix = "/VECTMAP/.maps/";
  return startsWith(value, prefix) && safeId(value.substr(prefix.size())) &&
         value.find('/', prefix.size()) == std::string::npos;
}

bool MapTransferInstaller::safeRelativePath(const std::string &path) const {
  if (path.empty() || path[0] == '/' || path.size() > 240 ||
      path.find('\\') != std::string::npos || path.find("//") != std::string::npos)
    return false;
  std::stringstream stream(path);
  std::string part;
  while (std::getline(stream, part, '/')) {
    if (part.empty() || part == "." || part == "..")
      return false;
  }
  return path.find("..") == std::string::npos;
}

bool MapTransferInstaller::mkdirs(const std::string &path) const {
  if (path.empty())
    return false;
  std::string current;
  size_t i = 0;
  if (path[0] == '/') {
    current = "/";
    i = 1;
  }
  while (i <= path.size()) {
    size_t slash = path.find('/', i);
    std::string part = path.substr(i, slash == std::string::npos ? slash : slash - i);
    if (!part.empty()) {
      if (current.size() > 1)
        current += "/";
      current += part;
      if (::mkdir(current.c_str(), 0755) != 0 && errno != EEXIST)
        return false;
    }
    if (slash == std::string::npos)
      break;
    i = slash + 1;
  }
  return true;
}

bool MapTransferInstaller::copyFile(const std::string &from,
                                    const std::string &to) const {
  std::ifstream input(from, std::ios::binary);
  if (!input)
    return false;
  std::ofstream output(to, std::ios::binary | std::ios::trunc);
  if (!output)
    return false;
  std::array<char, 4096> buffer = {};
  while (input.good()) {
    input.read(buffer.data(), buffer.size());
    const std::streamsize count = input.gcount();
    if (count > 0)
      output.write(buffer.data(), count);
    if (!output.good())
      return false;
  }
  output.flush();
  if (!input.eof() || !output.good())
    return false;
  output.close();
  return !output.fail();
}

bool MapTransferInstaller::copyTree(const std::string &from,
                                    const std::string &to) const {
  struct stat st;
  if (::stat(from.c_str(), &st) != 0)
    return false;
  if (!S_ISDIR(st.st_mode))
    return copyFile(from, to);
  if (!mkdirs(to))
    return false;
  DIR *dir = ::opendir(from.c_str());
  if (!dir)
    return false;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    if (!copyTree(joinPath(from, name), joinPath(to, name))) {
      ::closedir(dir);
      return false;
    }
  }
  ::closedir(dir);
  return true;
}

bool MapTransferInstaller::movePath(const std::string &from,
                                    const std::string &to) const {
  if (!mkdirs(dirnameOf(to)))
    return false;
  if (::rename(from.c_str(), to.c_str()) == 0)
    return true;
  if (!copyTree(from, to))
    return false;
  return removeTree(from);
}

bool MapTransferInstaller::removeTree(const std::string &path) const {
  struct stat st;
  if (::stat(path.c_str(), &st) != 0)
    return true;
  if (!S_ISDIR(st.st_mode))
    return ::unlink(path.c_str()) == 0;
  DIR *dir = ::opendir(path.c_str());
  if (!dir)
    return false;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    if (!removeTree(joinPath(path, name))) {
      ::closedir(dir);
      return false;
    }
  }
  ::closedir(dir);
  return ::rmdir(path.c_str()) == 0;
}

std::string MapTransferInstaller::verificationPath(
    const std::string &sessionId, const ManifestFile &file) const {
  const std::string key = sha256Hex(
      reinterpret_cast<const uint8_t *>(file.path.data()), file.path.size());
  return joinPath(joinPath(stagingRoot(sessionId), ".verified"),
                  key + ".sha256");
}

bool MapTransferInstaller::publishStagedFiles(
    const std::string &sessionId, const MapManifest &manifest,
    const std::string &destinationRoot) const {
  const std::string sourcePrefix =
      std::string(kVectMapPrefix) + manifest.mapId + "/";
  if (!mkdirs(destinationRoot))
    return false;
  for (const ManifestFile &file : manifest.files) {
    if (!startsWith(file.path, sourcePrefix))
      return false;
    const std::string relative = file.path.substr(sourcePrefix.size());
    const std::string source = joinPath(stagingRoot(sessionId), file.path);
    const std::string destination = joinPath(destinationRoot, relative);
    if (!movePath(source, destination))
      return false;
  }
  return true;
}

bool MapTransferInstaller::publishInstalledMetadata(
    const std::string &sessionId, const MapManifest &manifest,
    const std::string &destinationRoot) const {
  std::string manifestText;
  if (!readTextFile(joinPath(stagingRoot(sessionId), "manifest.json"),
                    manifestText, kMaxManifestBytes)) {
    return false;
  }
  return writeTextFileAtomic(joinPath(destinationRoot, kInstalledManifestFile),
                             manifestText) &&
         writeTextFileAtomic(joinPath(destinationRoot, kInstalledReceiptFile),
                             manifestReceipt(manifest));
}

std::string
MapTransferInstaller::manifestReceipt(const MapManifest &manifest) const {
  std::string value = std::to_string(manifest.schemaVersion) + "\n" +
                      manifest.mapId + "\n";
  for (const ManifestFile &file : manifest.files) {
    value += file.path + "\n" + file.publishPath + "\n" +
             std::to_string(file.bytes) + "\n" + file.sha256 + "\n";
  }
  return sha256Hex(reinterpret_cast<const uint8_t *>(value.data()),
                   value.size());
}

InstallStatus MapTransferInstaller::readInstalledManifest(
    const std::string &root, MapManifest &manifest) const {
  if (!safeActiveRoot(root) || !activeRootExists(root))
    return fail("installed_root", "installed map root is missing");
  std::string text;
  if (!readTextFile(
          joinPath(joinPath(storageRoot_, root), kInstalledManifestFile), text,
          kMaxManifestBytes)) {
    return fail("installed_manifest", "installed map manifest is missing");
  }
  return validateManifestText(text, manifest);
}

bool MapTransferInstaller::installedMapReceiptMatches(
    const std::string &root, const MapManifest &manifest) const {
  if (!activeRootExists(root))
    return false;
  MapManifest installedManifest;
  if (!readInstalledManifest(root, installedManifest).ok ||
      manifestReceipt(installedManifest) != manifestReceipt(manifest)) {
    return false;
  }
  std::string receipt;
  if (!readTextFile(
          joinPath(joinPath(storageRoot_, root), kInstalledReceiptFile), receipt,
          64) ||
      receipt != manifestReceipt(manifest)) {
    return false;
  }
  const std::string publishPrefix = kVectMapPrefix;
  for (const ManifestFile &file : manifest.files) {
    if (!startsWith(file.publishPath, publishPrefix))
      return false;
    const std::string relative = file.publishPath.substr(publishPrefix.size());
    const std::string path = joinPath(joinPath(storageRoot_, root), relative);
    uint64_t size = 0;
    if (!fileSize(path, size) || size != file.bytes)
      return false;
  }
  return true;
}

bool MapTransferInstaller::installedMapContentsMatch(
    const std::string &root, const MapManifest &manifest) const {
  if (!installedMapReceiptMatches(root, manifest))
    return false;
  const std::string publishPrefix = kVectMapPrefix;
  for (const ManifestFile &file : manifest.files) {
    const std::string relative = file.publishPath.substr(publishPrefix.size());
    const std::string path = joinPath(joinPath(storageRoot_, root), relative);
    std::string actual;
    if (!fileSha256Hex(path, actual))
      return false;
    std::transform(actual.begin(), actual.end(), actual.begin(), ::tolower);
    std::string expected = file.sha256;
    std::transform(expected.begin(), expected.end(), expected.begin(),
                   ::tolower);
    if (actual != expected)
      return false;
  }
  return true;
}

bool MapTransferInstaller::writeActiveMap(
    const ActiveMapSelection &selection) const {
  if (!safeId(selection.mapId) || !safeActiveRoot(selection.root) ||
      (!selection.sessionId.empty() && !safeId(selection.sessionId)) ||
      (!selection.previousRoot.empty() &&
       (!safeActiveRoot(selection.previousRoot) ||
        !safeId(selection.previousMapId) ||
        (!selection.previousSessionId.empty() &&
         !safeId(selection.previousSessionId)))) ||
      (selection.previousRoot.empty() &&
       (!selection.previousMapId.empty() ||
        !selection.previousSessionId.empty()))) {
    return false;
  }
  std::string json = std::string("{\"mapId\":\"") +
                     jsonEscape(selection.mapId) + "\",\"sessionId\":\"" +
                     jsonEscape(selection.sessionId) + "\",\"root\":\"" +
                     jsonEscape(selection.root) + "\"";
  if (!selection.previousRoot.empty()) {
    json += ",\"previousMapId\":\"" + jsonEscape(selection.previousMapId) +
            "\",\"previousSessionId\":\"" +
            jsonEscape(selection.previousSessionId) +
            "\",\"previousRoot\":\"" +
            jsonEscape(selection.previousRoot) + "\"";
  }
  json += "}\n";
  return writeTextFileAtomic(joinPath(storageRoot_, kActiveMapFile), json);
}

bool MapTransferInstaller::activeRootExists(const std::string &root) const {
  return safeActiveRoot(root) && dirExists(joinPath(storageRoot_, root));
}

bool MapTransferInstaller::fileExists(const std::string &path) const {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

bool MapTransferInstaller::dirExists(const std::string &path) const {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool MapTransferInstaller::fileSize(const std::string &path,
                                    uint64_t &size) const {
  struct stat st;
  if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode))
    return false;
  size = static_cast<uint64_t>(st.st_size);
  return true;
}

bool MapTransferInstaller::fileSha256Hex(const std::string &path,
                                         std::string &hex) const {
  std::ifstream input(path, std::ios::binary);
  if (!input)
    return false;
  Sha256Hasher sha;
  std::array<uint8_t, 1024> buffer = {};
  while (input.good()) {
    input.read(reinterpret_cast<char *>(buffer.data()), buffer.size());
    std::streamsize n = input.gcount();
    if (n > 0)
      sha.update(buffer.data(), static_cast<size_t>(n));
  }
  if (!input.eof())
    return false;
  hex = sha.finalHex();
  return true;
}

bool MapTransferInstaller::writeTextFile(const std::string &path,
                                         const std::string &text) const {
  if (!mkdirs(dirnameOf(path)))
    return false;
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output)
    return false;
  output << text;
  output.flush();
  if (!output.good())
    return false;
  output.close();
  return !output.fail();
}

bool MapTransferInstaller::writeTextFileAtomic(const std::string &path,
                                               const std::string &text) const {
  const std::string temporaryPath = path + ".tmp";
  const std::string backupPath = path + ".bak";
  removeTree(temporaryPath);
  if (!writeTextFile(temporaryPath, text))
    return false;

  // POSIX filesystems replace the destination atomically. Some embedded FAT
  // implementations reject replacement, so retain a recoverable backup while
  // using their two-rename fallback.
  if (::rename(temporaryPath.c_str(), path.c_str()) == 0) {
    removeTree(backupPath);
    return true;
  }

  removeTree(backupPath);
  const bool hadPrevious = fileExists(path);
  if (hadPrevious && ::rename(path.c_str(), backupPath.c_str()) != 0) {
    removeTree(temporaryPath);
    return false;
  }
  if (::rename(temporaryPath.c_str(), path.c_str()) != 0) {
    if (hadPrevious)
      ::rename(backupPath.c_str(), path.c_str());
    removeTree(temporaryPath);
    return false;
  }
  removeTree(backupPath);
  return true;
}

bool MapTransferInstaller::readTextFile(const std::string &path,
                                        std::string &text,
                                        size_t maxBytes) const {
  uint64_t size = 0;
  if (!fileSize(path, size) || size > maxBytes)
    return false;
  std::ifstream input(path, std::ios::binary);
  if (!input)
    return false;
  text.assign((std::istreambuf_iterator<char>(input)),
              std::istreambuf_iterator<char>());
  return true;
}

} // namespace map_transfer
