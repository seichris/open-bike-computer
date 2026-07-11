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

class Sha256 {
public:
  void update(const uint8_t *data, size_t len) {
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

  std::string finalHex() {
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

private:
  std::array<uint8_t, 64> block_ = {};
  size_t blockLen_ = 0;
  uint64_t totalLen_ = 0;
  uint32_t h_[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

  void transform(const uint8_t *chunk) {
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
};

} // namespace

std::string sha256Hex(const uint8_t *data, size_t len) {
  Sha256 sha;
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

InstallStatus
MapTransferInstaller::validateStagedMap(const std::string &sessionId,
                                        MapManifest &manifest) const {
  if (!safeId(sessionId))
    return fail("session_id", "session id contains unsafe characters");
  std::string manifestText;
  if (!readTextFile(joinPath(stagingRoot(sessionId), "manifest.json"),
                    manifestText, kMaxManifestBytes))
    return fail("manifest_missing", "staged manifest is missing");
  InstallStatus parsed = validateManifestText(manifestText, manifest);
  if (!parsed.ok)
    return parsed;

  for (const ManifestFile &file : manifest.files) {
    const std::string stagedPath = joinPath(stagingRoot(sessionId), file.path);
    uint64_t size = 0;
    if (!fileSize(stagedPath, size))
      return fail("file_missing", "staged map file is missing: " + file.path);
    if (size != file.bytes)
      return fail("file_size", "staged map file size mismatch: " + file.path);
    std::string sha;
    if (!fileSha256Hex(stagedPath, sha))
      return fail("file_sha256", "could not hash staged map file: " + file.path);
    std::transform(sha.begin(), sha.end(), sha.begin(), ::tolower);
    std::string expected = file.sha256;
    std::transform(expected.begin(), expected.end(), expected.begin(), ::tolower);
    if (sha != expected)
      return fail("file_sha256", "staged map file sha256 mismatch: " + file.path);
  }
  return {true, "ok", ""};
}

InstallStatus MapTransferInstaller::activateStagedMap(
    const std::string &sessionId, const MapManifest &manifest) const {
  if (!safeId(sessionId))
    return fail("session_id", "session id contains unsafe characters");
  if (!safeId(manifest.mapId))
    return fail("manifest_map_id", "mapId contains unsafe characters");

  const std::string vectmapRoot = joinPath(storageRoot_, "VECTMAP");
  if (!mkdirs(vectmapRoot))
    return fail("mkdir", "could not create VECTMAP root");

  const std::string activationRoot =
      joinPath(storageRoot_, std::string("VECTMAP/.activation/") + sessionId);
  const std::string rollbackRoot =
      joinPath(storageRoot_, std::string("VECTMAP/.rollback/") + sessionId);

  removeTree(activationRoot);
  removeTree(rollbackRoot);

  for (const ManifestFile &file : manifest.files) {
    const std::string stagedPath = joinPath(stagingRoot(sessionId), file.path);
    const std::string destination = joinPath(activationRoot, file.publishPath);
    if (!mkdirs(dirnameOf(destination)))
      return fail("mkdir", "could not create destination folder");
    if (!copyFile(stagedPath, destination))
      return fail("copy", "could not stage published map file: " + file.publishPath);
  }

  if (!backupPublishedMap(rollbackRoot)) {
    restorePublishedMap(rollbackRoot);
    removeTree(activationRoot);
    return fail("rollback", "could not backup current map before activation");
  }
  if (!clearPublishedMap()) {
    restorePublishedMap(rollbackRoot);
    removeTree(activationRoot);
    return fail("publish_clear", "could not clear current published map");
  }
  if (!publishActivation(activationRoot)) {
    clearPublishedMap();
    restorePublishedMap(rollbackRoot);
    removeTree(activationRoot);
    return fail("publish_copy", "could not publish activated map");
  }

  const std::string activeJson = std::string("{\"mapId\":\"") + manifest.mapId +
                                 "\",\"root\":\"/VECTMAP\"}\n";
  if (!writeTextFile(joinPath(storageRoot_, kActiveMapFile), activeJson)) {
    clearPublishedMap();
    restorePublishedMap(rollbackRoot);
    removeTree(activationRoot);
    return fail("active_write", "could not write active map metadata");
  }

  removeTree(rollbackRoot);
  removeTree(activationRoot);
  removeTree(stagingRoot(sessionId));
  return {true, "ok", ""};
}

InstallStatus
MapTransferInstaller::readActiveMapId(std::string &mapId) const {
  std::string text;
  if (!readTextFile(joinPath(storageRoot_, kActiveMapFile), text, 1024))
    return fail("active_missing", "active map metadata is missing");
  mapId = jsonStringValue(text, "mapId");
  if (!safeId(mapId))
    return fail("active_invalid", "active map metadata is invalid");
  return {true, "ok", ""};
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
  output << input.rdbuf();
  return output.good();
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

bool MapTransferInstaller::backupPublishedMap(
    const std::string &backupRoot) const {
  const std::string vectmapRoot = joinPath(storageRoot_, "VECTMAP");
  if (!dirExists(vectmapRoot))
    return true;
  if (!mkdirs(backupRoot))
    return false;
  DIR *dir = ::opendir(vectmapRoot.c_str());
  if (!dir)
    return false;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    std::string name = entry->d_name;
    if (name == "." || name == ".." || name[0] == '.' ||
        name == "active-map.json")
      continue;
    if (!movePath(joinPath(vectmapRoot, name), joinPath(backupRoot, name))) {
      ::closedir(dir);
      return false;
    }
  }
  ::closedir(dir);
  return true;
}

bool MapTransferInstaller::restorePublishedMap(
    const std::string &backupRoot) const {
  if (!dirExists(backupRoot))
    return true;
  const std::string vectmapRoot = joinPath(storageRoot_, "VECTMAP");
  if (!mkdirs(vectmapRoot))
    return false;
  DIR *dir = ::opendir(backupRoot.c_str());
  if (!dir)
    return false;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    if (!movePath(joinPath(backupRoot, name), joinPath(vectmapRoot, name))) {
      ::closedir(dir);
      return false;
    }
  }
  ::closedir(dir);
  removeTree(backupRoot);
  return true;
}

bool MapTransferInstaller::clearPublishedMap() const {
  const std::string vectmapRoot = joinPath(storageRoot_, "VECTMAP");
  if (!dirExists(vectmapRoot))
    return true;
  DIR *dir = ::opendir(vectmapRoot.c_str());
  if (!dir)
    return false;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    std::string name = entry->d_name;
    if (name == "." || name == ".." || name[0] == '.' ||
        name == "active-map.json")
      continue;
    if (!removeTree(joinPath(vectmapRoot, name))) {
      ::closedir(dir);
      return false;
    }
  }
  ::closedir(dir);
  return true;
}

bool MapTransferInstaller::publishActivation(
    const std::string &activationRoot) const {
  const std::string sourceRoot = joinPath(activationRoot, "VECTMAP");
  const std::string vectmapRoot = joinPath(storageRoot_, "VECTMAP");
  DIR *dir = ::opendir(sourceRoot.c_str());
  if (!dir)
    return false;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    if (!movePath(joinPath(sourceRoot, name), joinPath(vectmapRoot, name))) {
      ::closedir(dir);
      return false;
    }
  }
  ::closedir(dir);
  return true;
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
  Sha256 sha;
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
  return output.good();
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
