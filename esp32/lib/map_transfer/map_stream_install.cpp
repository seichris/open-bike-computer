#include "map_stream_install.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace map_transfer {
namespace {

constexpr const char *kInstallingFile = ".installing";
constexpr const char *kCheckpointFile = ".stream-checkpoint";
constexpr const char *kManifestFile = ".manifest.json";
constexpr const char *kManifestReceiptFile = ".verified.sha256";
constexpr const char *kReadyFile = ".ready";
constexpr const char *kConsumedFile = ".activation-consumed";
constexpr const char *kPendingFile = "/VECTMAP/.pending-stream-activation.json";
constexpr size_t kMaximumCheckpointBytes = 4096;

std::string joinPath(const std::string &left, const std::string &right) {
  if (left.empty())
    return right;
  if (right.empty())
    return left;
  if (left.back() == '/')
    return left + (right.front() == '/' ? right.substr(1) : right);
  return left + "/" + (right.front() == '/' ? right.substr(1) : right);
}

std::string dirnameOf(const std::string &path) {
  const size_t slash = path.find_last_of('/');
  if (slash == std::string::npos)
    return "";
  return slash == 0 ? "/" : path.substr(0, slash);
}

bool mkdirs(const std::string &path) {
  if (path.empty())
    return false;
  std::string current = path.front() == '/' ? "/" : "";
  size_t position = path.front() == '/' ? 1 : 0;
  while (position <= path.size()) {
    const size_t slash = path.find('/', position);
    const std::string component =
        path.substr(position, slash == std::string::npos ? std::string::npos
                                                         : slash - position);
    if (!component.empty()) {
      if (current.size() > 1 && current.back() != '/')
        current.push_back('/');
      current += component;
      if (::mkdir(current.c_str(), 0755) != 0 && errno != EEXIST)
        return false;
    }
    if (slash == std::string::npos)
      break;
    position = slash + 1;
  }
  return true;
}

bool regularFileSize(const std::string &path, uint64_t &bytes) {
  struct stat status;
  if (::stat(path.c_str(), &status) != 0 || !S_ISREG(status.st_mode) ||
      status.st_size < 0) {
    return false;
  }
  bytes = static_cast<uint64_t>(status.st_size);
  return true;
}

bool regularFileExists(const std::string &path) {
  uint64_t ignored = 0;
  return regularFileSize(path, ignored);
}

bool removeTree(const std::string &path) {
  struct stat status;
#if defined(ESP_PLATFORM) || defined(ARDUINO_ARCH_ESP32)
  if (::stat(path.c_str(), &status) != 0)
#else
  if (::lstat(path.c_str(), &status) != 0)
#endif
    return errno == ENOENT;
  if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode))
    return ::unlink(path.c_str()) == 0 || errno == ENOENT;
  DIR *directory = ::opendir(path.c_str());
  if (directory == nullptr)
    return false;
  bool ok = true;
  while (struct dirent *entry = ::readdir(directory)) {
    const std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    if (!removeTree(joinPath(path, name)))
      ok = false;
  }
  ::closedir(directory);
  return ok && (::rmdir(path.c_str()) == 0 || errno == ENOENT);
}

bool writeAll(int descriptor, const uint8_t *data, size_t size) {
  while (size > 0) {
    const ssize_t written = ::write(descriptor, data, size);
    if (written < 0) {
      if (errno == EINTR)
        continue;
      return false;
    }
    if (written == 0)
      return false;
    data += static_cast<size_t>(written);
    size -= static_cast<size_t>(written);
  }
  return true;
}

bool readText(const std::string &path, std::string &value, size_t maximumBytes);

bool syncDirectory(const std::string &path) {
#if defined(ESP_PLATFORM) || defined(ARDUINO_ARCH_ESP32)
  // ESP-IDF's FatFs VFS cannot open directories with open(2). File fsync plus
  // rename is the strongest durability primitive exposed by that backend.
  // Treat the unsupported directory barrier as a documented capability, not
  // as an installation failure after the rename already succeeded.
  (void)path;
  return true;
#else
  const int descriptor = ::open(path.c_str(), O_RDONLY);
  if (descriptor < 0)
    return false;
  const bool ok =
      ::fsync(descriptor) == 0 || errno == EINVAL || errno == ENOTSUP;
  ::close(descriptor);
  return ok;
#endif
}

class PosixMapStreamStorage final : public MapStreamStorage {
public:
  bool createDirectories(const std::string &path) override {
    return mkdirs(path);
  }
  bool removeTree(const std::string &path) override {
    return map_transfer::removeTree(path);
  }
  bool regularFileSize(const std::string &path, uint64_t &bytes) override {
    return map_transfer::regularFileSize(path, bytes);
  }
  bool readText(const std::string &path, std::string &value,
                size_t maximumBytes) override {
    return map_transfer::readText(path, value, maximumBytes);
  }
  bool forEachDirectoryEntry(
      const std::string &path,
      const std::function<bool(const MapStreamDirectoryEntry &)> &callback)
      override {
    DIR *directory = ::opendir(path.c_str());
    if (directory == nullptr)
      return errno == ENOENT;
    bool ok = true;
    while (struct dirent *entry = ::readdir(directory)) {
      const std::string name = entry->d_name;
      if (name == "." || name == "..")
        continue;
      struct stat status;
      const std::string child = joinPath(path, name);
#if defined(ESP_PLATFORM) || defined(ARDUINO_ARCH_ESP32)
      const int statResult = ::stat(child.c_str(), &status);
#else
      const int statResult = ::lstat(child.c_str(), &status);
#endif
      if (statResult != 0) {
        ok = false;
        continue;
      }
      if (!callback({name, S_ISDIR(status.st_mode)})) {
        ok = false;
        break;
      }
    }
    ::closedir(directory);
    return ok;
  }
  int openWrite(const std::string &path) override {
    return ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
  }
  bool write(int descriptor, const uint8_t *data, size_t size) override {
    return writeAll(descriptor, data, size);
  }
  bool syncFile(int descriptor) override { return ::fsync(descriptor) == 0; }
  bool closeFile(int descriptor) override { return ::close(descriptor) == 0; }
  bool renamePath(const std::string &from, const std::string &to) override {
    return ::rename(from.c_str(), to.c_str()) == 0;
  }
  bool syncDirectory(const std::string &path) override {
    return map_transfer::syncDirectory(path);
  }
};

bool writeFileAtomic(MapStreamStorage &storage, const std::string &path,
                     std::string_view value) {
  if (!storage.createDirectories(dirnameOf(path)))
    return false;
  const std::string temporary = path + ".tmp";
  const std::string backup = path + ".bak";
  storage.removeTree(temporary);
  const int descriptor = storage.openWrite(temporary);
  if (descriptor < 0)
    return false;
  const bool written =
      storage.write(descriptor, reinterpret_cast<const uint8_t *>(value.data()),
                    value.size());
  const bool synced = written && storage.syncFile(descriptor);
  const bool closed = storage.closeFile(descriptor);
  if (!synced || !closed) {
    storage.removeTree(temporary);
    return false;
  }
  if (storage.renamePath(temporary, path)) {
    storage.removeTree(backup);
    return storage.syncDirectory(dirnameOf(path));
  }
  storage.removeTree(backup);
  uint64_t previousBytes = 0;
  const bool hadPrevious = storage.regularFileSize(path, previousBytes);
  if (!hadPrevious) {
    storage.removeTree(temporary);
    return false;
  }
  if (hadPrevious && !storage.renamePath(path, backup)) {
    storage.removeTree(temporary);
    return false;
  }
  if (!storage.renamePath(temporary, path)) {
    if (hadPrevious)
      storage.renamePath(backup, path);
    storage.removeTree(temporary);
    return false;
  }
  const bool directorySynced = storage.syncDirectory(dirnameOf(path));
  storage.removeTree(backup);
  return directorySynced;
}

bool readText(const std::string &path, std::string &value,
              size_t maximumBytes) {
  uint64_t bytes = 0;
  if (!regularFileSize(path, bytes) || bytes > maximumBytes)
    return false;
  std::ifstream input(path, std::ios::binary);
  if (!input)
    return false;
  value.assign(std::istreambuf_iterator<char>(input),
               std::istreambuf_iterator<char>());
  return input.good() || input.eof();
}

std::string jsonEscape(const std::string &value) {
  std::string escaped;
  escaped.reserve(value.size() + 8);
  for (const char character : value) {
    if (character == '"' || character == '\\') {
      escaped.push_back('\\');
      escaped.push_back(character);
    } else if (character == '\n') {
      escaped += "\\n";
    } else if (character == '\r') {
      escaped += "\\r";
    } else {
      escaped.push_back(character);
    }
  }
  return escaped;
}

std::string jsonString(const std::string &json, const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  size_t position = json.find(needle);
  if (position == std::string::npos)
    return "";
  position = json.find(':', position + needle.size());
  if (position == std::string::npos)
    return "";
  position = json.find('"', position + 1);
  if (position == std::string::npos)
    return "";
  std::string value;
  bool escaped = false;
  for (position++; position < json.size(); position++) {
    const char character = json[position];
    if (escaped) {
      value.push_back(character);
      escaped = false;
    } else if (character == '\\') {
      escaped = true;
    } else if (character == '"') {
      return value;
    } else {
      value.push_back(character);
    }
  }
  return "";
}

uint64_t jsonUnsigned(const std::string &json, const std::string &key,
                      bool &found) {
  found = false;
  const std::string needle = "\"" + key + "\"";
  size_t position = json.find(needle);
  if (position == std::string::npos)
    return 0;
  position = json.find(':', position + needle.size());
  if (position == std::string::npos)
    return 0;
  position++;
  while (position < json.size() &&
         (json[position] == ' ' || json[position] == '\n' ||
          json[position] == '\r' || json[position] == '\t')) {
    position++;
  }
  if (position >= json.size() || json[position] < '0' || json[position] > '9') {
    return 0;
  }
  uint64_t value = 0;
  while (position < json.size() && json[position] >= '0' &&
         json[position] <= '9') {
    const uint64_t digit = static_cast<uint64_t>(json[position++] - '0');
    if (value > (UINT64_MAX - digit) / 10)
      return 0;
    value = value * 10 + digit;
  }
  found = true;
  return value;
}

uint64_t defaultNowMilliseconds() {
  return static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count());
}

std::string filePath(const std::string &root, const MapStreamFileView &file) {
  return joinPath(joinPath(root, std::string(file.tileDirectory)),
                  std::string(file.filename));
}

bool safeSessionIdentifier(const std::string &value) {
  if (value.empty() || value.size() > 80 || value.front() == '.' ||
      value.find("..") != std::string::npos) {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](unsigned char character) {
    return (character >= 'a' && character <= 'z') ||
           (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9') || character == '-' ||
           character == '_' || character == '.';
  });
}

bool safeMapIdentifier(const std::string &value) {
  if (value.empty() || value.size() > MAP_STREAM_MAX_MAP_ID_BYTES ||
      value == "." || value == "..") {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](unsigned char character) {
    return (character >= 'a' && character <= 'z') ||
           (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9') || character == '-' ||
           character == '_' || character == '.';
  });
}

} // namespace

std::shared_ptr<MapStreamStorage> makeDefaultMapStreamStorage() {
  return std::make_shared<PosixMapStreamStorage>();
}

const char *mapStreamInstallStateCode(MapStreamInstallState state) {
  switch (state) {
  case MapStreamInstallState::Idle:
    return "idle";
  case MapStreamInstallState::Receiving:
    return "receiving";
  case MapStreamInstallState::Paused:
    return "paused";
  case MapStreamInstallState::Finalizing:
    return "finalizing";
  case MapStreamInstallState::Ready:
    return "ready";
  case MapStreamInstallState::Failed:
    return "failed";
  }
  return "failed";
}

uint8_t MapStreamInstallSnapshot::step() const { return currentStep; }

uint8_t MapStreamInstallSnapshot::totalSteps() const { return 3; }

uint8_t MapStreamInstallSnapshot::progress() const {
  if (currentStep == 2) {
    if (finalizationTotal == 0)
      return 0;
    return static_cast<uint8_t>(std::min<uint32_t>(
        100, (static_cast<uint32_t>(finalizationCompleted) * 100U) /
                 finalizationTotal));
  }
  if (totalPayloadBytes == 0)
    return 0;
  return static_cast<uint8_t>(std::min<uint64_t>(
      100, (receivedPayloadBytes * 100) / totalPayloadBytes));
}

std::string MapStreamInstallSnapshot::json(bool compact) const {
  std::string value =
      std::string("{\"protocolVersion\":2,\"state\":\"") +
      mapStreamInstallStateCode(state) +
      "\",\"sequence\":" + std::to_string(sequence) +
      ",\"step\":" + std::to_string(step()) +
      ",\"steps\":3,\"progress\":" + std::to_string(progress()) +
      ",\"receivedPayloadBytes\":" + std::to_string(receivedPayloadBytes) +
      ",\"totalPayloadBytes\":" + std::to_string(totalPayloadBytes) +
      ",\"completedFiles\":" + std::to_string(completedFiles) +
      ",\"totalFiles\":" + std::to_string(totalFiles) +
      ",\"durableFilePrefix\":" + std::to_string(durableFilePrefix) +
      ",\"finalizationCompleted\":" + std::to_string(finalizationCompleted) +
      ",\"finalizationTotal\":" + std::to_string(finalizationTotal);
  if (!sessionId.empty())
    value += ",\"sessionId\":\"" + jsonEscape(sessionId) + "\"";
  if (!compact && !mapId.empty())
    value += ",\"mapId\":\"" + jsonEscape(mapId) + "\"";
  if (!compact && !signedManifestReceipt.empty()) {
    value += ",\"signedManifestReceipt\":\"" +
             jsonEscape(signedManifestReceipt) + "\"";
  }
  if (!compact) {
    value += ",\"timings\":{\"sdWriteMilliseconds\":" +
             std::to_string(sdWriteMilliseconds) +
             ",\"fileCommitMilliseconds\":" +
             std::to_string(fileCommitMilliseconds) +
             ",\"checkpointMilliseconds\":" +
             std::to_string(checkpointMilliseconds) +
             ",\"finalizationMilliseconds\":" +
             std::to_string(finalizationMilliseconds) + "}";
  }
  if (!errorCode.empty()) {
    value += ",\"error\":{\"code\":\"" + jsonEscape(errorCode) + "\"";
    if (!compact && !errorMessage.empty())
      value += ",\"message\":\"" + jsonEscape(errorMessage) + "\"";
    value += "}";
  }
  value += "}";
  return value;
}

MapStreamRecoveryResult
readRecoverableMapStreamInstall(const std::string &storageRoot,
                                MapStreamInstallSnapshot &snapshot) {
  snapshot = MapStreamInstallSnapshot();
  const std::string mapsRoot = joinPath(storageRoot, "/VECTMAP/.maps");
  DIR *directory = ::opendir(mapsRoot.c_str());
  if (directory == nullptr)
    return errno == ENOENT ? MapStreamRecoveryResult::None
                           : MapStreamRecoveryResult::Invalid;
  size_t found = 0;
  bool invalid = false;
  while (struct dirent *entry = ::readdir(directory)) {
    const std::string sessionId = entry->d_name;
    if (sessionId == "." || sessionId == ".." ||
        !safeSessionIdentifier(sessionId))
      continue;
    const std::string root = joinPath(mapsRoot, sessionId);
    const bool ready = regularFileExists(joinPath(root, kReadyFile)) ||
                       regularFileExists(joinPath(root, kReadyFile) + ".bak");
    const bool consumed =
        regularFileExists(joinPath(root, kConsumedFile)) ||
        regularFileExists(joinPath(root, kConsumedFile) + ".bak");
    const bool installing =
        regularFileExists(joinPath(root, kInstallingFile)) ||
        regularFileExists(joinPath(root, kInstallingFile) + ".bak");
    if ((!ready || consumed) && !installing)
      continue;
    MapStreamInstallSnapshot candidate;
    std::string marker;
    bool markerValid = false;
    const std::string markerPath =
        joinPath(root, ready ? kReadyFile : kInstallingFile);
    for (const std::string &path : {markerPath, markerPath + ".bak"}) {
      std::string value;
      if (!readText(path, value, 2048))
        continue;
      MapStreamInstallSnapshot parsed;
      parsed.state =
          ready ? MapStreamInstallState::Ready : MapStreamInstallState::Paused;
      parsed.currentStep = ready ? 2 : 1;
      parsed.finalizationCompleted = ready ? parsed.finalizationTotal : 0;
      parsed.sessionId = jsonString(value, "sessionId");
      parsed.mapId = jsonString(value, "mapId");
      parsed.manifestReceipt = jsonString(value, "manifestReceipt");
      parsed.signedManifestReceipt = jsonString(value, "signedManifestReceipt");
      if (parsed.sessionId == sessionId && safeMapIdentifier(parsed.mapId) &&
          parsed.signedManifestReceipt.size() == 64) {
        candidate = std::move(parsed);
        marker = std::move(value);
        markerValid = true;
        break;
      }
    }
    if (!markerValid) {
      invalid = true;
      continue;
    }
    const std::string checkpointPath = joinPath(root, kCheckpointFile);
    const bool checkpointExists = regularFileExists(checkpointPath) ||
                                  regularFileExists(checkpointPath + ".bak");
    bool checkpointValid = false;
    if (checkpointExists) {
      for (const std::string &path :
           {checkpointPath, checkpointPath + ".bak"}) {
        std::string checkpoint;
        if (!readText(path, checkpoint, kMaximumCheckpointBytes))
          continue;
        bool havePrefix = false;
        bool havePayload = false;
        bool haveFiles = false;
        bool haveTotalPayload = false;
        bool haveSequence = false;
        const uint64_t prefix =
            jsonUnsigned(checkpoint, "completedFilePrefix", havePrefix);
        const uint64_t payload =
            jsonUnsigned(checkpoint, "completedPayloadBytes", havePayload);
        const uint64_t files =
            jsonUnsigned(checkpoint, "totalFiles", haveFiles);
        const uint64_t totalPayload =
            jsonUnsigned(checkpoint, "totalPayloadBytes", haveTotalPayload);
        const uint64_t sequence =
            jsonUnsigned(checkpoint, "sequence", haveSequence);
        if (!havePrefix || !havePayload || !haveFiles || !haveTotalPayload ||
            !haveSequence || prefix > files || files > UINT32_MAX ||
            sequence > UINT32_MAX ||
            jsonString(checkpoint, "sessionId") != sessionId ||
            jsonString(checkpoint, "signedManifestReceipt") !=
                candidate.signedManifestReceipt) {
          continue;
        }
        candidate.durableFilePrefix = static_cast<uint32_t>(prefix);
        candidate.completedFiles = static_cast<uint32_t>(prefix);
        candidate.totalFiles = static_cast<uint32_t>(files);
        candidate.completedPayloadBytes = payload;
        candidate.totalPayloadBytes = totalPayload;
        candidate.sequence = static_cast<uint32_t>(sequence);
        checkpointValid = true;
        break;
      }
      if (!checkpointValid) {
        invalid = true;
        continue;
      }
    } else if (ready) {
      bool haveFiles = false;
      const uint64_t totalFiles = jsonUnsigned(marker, "fileCount", haveFiles);
      if (!haveFiles || totalFiles == 0 || totalFiles > UINT32_MAX) {
        invalid = true;
        continue;
      }
      candidate.totalFiles = static_cast<uint32_t>(totalFiles);
      candidate.completedFiles = candidate.totalFiles;
      candidate.durableFilePrefix = candidate.totalFiles;
      bool havePayload = false;
      candidate.totalPayloadBytes =
          jsonUnsigned(marker, "payloadBytes", havePayload);
      candidate.completedPayloadBytes = candidate.totalPayloadBytes;
      if (!havePayload) {
        invalid = true;
        continue;
      }
    }
    snapshot = std::move(candidate);
    found++;
  }
  ::closedir(directory);
  if (found > 1)
    return MapStreamRecoveryResult::Ambiguous;
  if (found == 1)
    return MapStreamRecoveryResult::Found;
  return invalid ? MapStreamRecoveryResult::Invalid
                 : MapStreamRecoveryResult::None;
}

MapStreamInstallSession::MapStreamInstallSession(
    std::string storageRoot, std::string sessionId,
    MapStreamCheckpointPolicy checkpointPolicy, MapStreamNowCallback now,
    std::shared_ptr<MapStreamStorage> storage)
    : storageRoot_(std::move(storageRoot)), sessionId_(std::move(sessionId)),
      checkpointPolicy_(checkpointPolicy), now_(std::move(now)),
      storage_(std::move(storage)) {
  if (!storageRoot_.empty() && storageRoot_.back() == '/')
    storageRoot_.pop_back();
  if (!now_)
    now_ = defaultNowMilliseconds;
  if (!storage_)
    storage_ = makeDefaultMapStreamStorage();
  status_.sessionId = sessionId_;
}

MapStreamInstallSession::~MapStreamInstallSession() { closeCurrentFile(true); }

bool MapStreamInstallSession::onManifest(
    const VerifiedMapStreamManifest &manifest,
    std::string_view canonicalManifest) {
  closeCurrentFile(true);
  nextFileIndex_ = 0;
  status_.sequence++;
  if (status_.sequence == 0)
    status_.sequence = 1;
  status_.state = MapStreamInstallState::Receiving;
  status_.currentStep = 1;
  status_.finalizationCompleted = 0;
  status_.mapId = manifest.manifest.metadata.mapId;
  status_.manifestReceipt = manifest.manifestReceipt;
  status_.signedManifestReceipt = manifest.signedManifestReceipt;
  status_.totalPayloadBytes = manifest.payloadBytes;
  status_.totalFiles = static_cast<uint32_t>(manifest.manifest.files.size());
  canonicalManifest_ = canonicalManifest;
  checkpointAtMilliseconds_ = now_();
  return prepareRoot(manifest, canonicalManifest);
}

MapStreamFileAction
MapStreamInstallSession::onFileBegin(const MapStreamFileView &file,
                                     size_t index) {
  closeCurrentFile(true);
  if (index != nextFileIndex_) {
    fail("stream_file_order", "map stream file callbacks are out of order");
    return MapStreamFileAction::Reject;
  }
  currentFile_ = static_cast<int>(index);
  currentSkipped_ = index < status_.durableFilePrefix;
  if (currentSkipped_)
    return MapStreamFileAction::ConsumeCheckpointed;
  const std::string destination = filePath(inactiveRoot(), file);
  currentPartPath_ = destination + ".part";
  if (!storage_->createDirectories(dirnameOf(destination)) ||
      !storage_->removeTree(currentPartPath_)) {
    fail("stream_file_prepare", "could not prepare map file destination");
    return MapStreamFileAction::Reject;
  }
  currentFd_ = storage_->openWrite(currentPartPath_);
  if (currentFd_ < 0) {
    fail("stream_file_open", "could not open map file for writing");
    return MapStreamFileAction::Reject;
  }
  return MapStreamFileAction::VerifyAndConsume;
}

bool MapStreamInstallSession::onFileData(const MapStreamFileView &,
                                         const uint8_t *data, size_t size) {
  status_.receivedPayloadBytes += size;
  if (currentSkipped_) {
    status_.bytesSkipped += size;
    return true;
  }
  const uint64_t writeStarted = now_();
  if (currentFd_ < 0 || !storage_->write(currentFd_, data, size))
    return fail("stream_file_write", "could not write map payload to SD");
  const uint64_t writeFinished = now_();
  if (writeFinished >= writeStarted)
    status_.sdWriteMilliseconds += writeFinished - writeStarted;
  status_.bytesWritten += size;
  return true;
}

bool MapStreamInstallSession::onFileEnd(const MapStreamFileView &file,
                                        size_t index) {
  if (currentFile_ < 0 || static_cast<size_t>(currentFile_) != index)
    return fail("stream_file_order",
                "map stream file completion is out of order");
  if (currentSkipped_) {
    currentFile_ = -1;
    currentSkipped_ = false;
    status_.completedFiles = std::max<uint32_t>(
        status_.completedFiles, static_cast<uint32_t>(index + 1));
    nextFileIndex_++;
    return true;
  }
  if (currentFd_ < 0)
    return fail("stream_file_sync", "map file descriptor is unavailable");
  const uint64_t commitStarted = now_();
  const bool synced = storage_->syncFile(currentFd_);
  const bool closed = storage_->closeFile(currentFd_);
  if (!synced || !closed) {
    currentFd_ = -1;
    return fail("stream_file_sync", "could not durably finish map file");
  }
  currentFd_ = -1;
  const std::string destination = filePath(inactiveRoot(), file);
  if (!storage_->removeTree(destination) ||
      !storage_->renamePath(currentPartPath_, destination) ||
      !storage_->syncDirectory(dirnameOf(destination))) {
    return fail("stream_file_publish", "could not publish verified map file");
  }
  const uint64_t commitFinished = now_();
  if (commitFinished >= commitStarted)
    status_.fileCommitMilliseconds += commitFinished - commitStarted;
  currentPartPath_.clear();
  currentFile_ = -1;
  status_.completedFiles = static_cast<uint32_t>(index + 1);
  status_.completedPayloadBytes += file.bytes;
  nextFileIndex_++;
  return writeCheckpoint(false);
}

bool MapStreamInstallSession::onComplete(
    const VerifiedMapStreamManifest &manifest) {
  if (status_.completedFiles != status_.totalFiles ||
      status_.completedPayloadBytes != status_.totalPayloadBytes) {
    return fail("stream_completion_mismatch",
                "completed map payload does not match the manifest");
  }
  status_.state = MapStreamInstallState::Finalizing;
  status_.currentStep = 2;
  status_.finalizationCompleted = 0;
  const uint64_t finalizationStarted = now_();
  bool completed = writeCheckpoint(true);
  if (completed) {
    advanceFinalization();
    completed = writeFinalMetadata(manifest);
  }
  const uint64_t finalizationFinished = now_();
  if (finalizationFinished >= finalizationStarted) {
    status_.finalizationMilliseconds +=
        finalizationFinished - finalizationStarted;
  }
  return completed;
}

void MapStreamInstallSession::onAbort(MapStreamParserError error) {
  closeCurrentFile(true);
  if (status_.state == MapStreamInstallState::Ready ||
      status_.state == MapStreamInstallState::Failed)
    return;
  if (error == MapStreamParserError::Truncated) {
    status_.state = MapStreamInstallState::Paused;
    status_.errorCode = "stream_paused";
    status_.errorMessage = "map transfer ended before the declared payload";
  } else {
    status_.state = MapStreamInstallState::Failed;
    status_.errorCode = mapStreamParserErrorCode(error);
    status_.errorMessage = "map stream validation failed";
  }
}

const MapStreamInstallSnapshot &MapStreamInstallSession::snapshot() const {
  return status_;
}

std::string MapStreamInstallSession::inactiveRoot() const {
  return joinPath(storageRoot_, inactiveRootRelative());
}

std::string MapStreamInstallSession::inactiveRootRelative() const {
  return "/VECTMAP/.maps/" + sessionId_;
}

bool MapStreamInstallSession::fail(const std::string &code,
                                   const std::string &message) {
  status_.state = MapStreamInstallState::Failed;
  status_.errorCode = code;
  status_.errorMessage = message;
  return false;
}

void MapStreamInstallSession::advanceFinalization() {
  if (status_.finalizationCompleted < status_.finalizationTotal)
    status_.finalizationCompleted++;
  if (status_.sequence < UINT32_MAX)
    status_.sequence++;
}

bool MapStreamInstallSession::safeId(const std::string &value) const {
  return safeSessionIdentifier(value);
}

bool MapStreamInstallSession::prepareRoot(
    const VerifiedMapStreamManifest &manifest,
    std::string_view canonicalManifest) {
  if (!safeId(sessionId_))
    return fail("stream_session_id", "map stream session ID is invalid");
  if (storageRoot_.empty() || storageRoot_.front() != '/')
    return fail("stream_storage_root", "map storage root is invalid");
  bool resumed = loadMatchingCheckpoint(manifest, canonicalManifest);
  if (status_.state == MapStreamInstallState::Failed)
    return false;
  if (!resumed) {
    std::string active;
    const std::string activePath =
        joinPath(storageRoot_, "/VECTMAP/active-map.json");
    for (const std::string &candidate : {activePath, activePath + ".bak"}) {
      if (storage_->readText(candidate, active, 2048) &&
          (jsonString(active, "root") == inactiveRootRelative() ||
           jsonString(active, "previousRoot") == inactiveRootRelative())) {
        return fail("stream_session_conflict",
                    "cannot replace an active or rollback map root in place");
      }
    }
    if (!storage_->removeTree(inactiveRoot()) ||
        !storage_->createDirectories(inactiveRoot()))
      return fail("stream_root_prepare", "could not prepare inactive map root");
    status_.durableFilePrefix = 0;
    status_.completedFiles = 0;
    status_.completedPayloadBytes = 0;
    checkpointSequence_ = 0;
    const std::string installing =
        std::string("{\"protocolVersion\":2,\"sessionId\":\"") +
        jsonEscape(sessionId_) + "\",\"mapId\":\"" + jsonEscape(status_.mapId) +
        "\",\"signedManifestReceipt\":\"" + status_.signedManifestReceipt +
        "\"}\n";
    if (!writeFileAtomic(*storage_, joinPath(inactiveRoot(), kInstallingFile),
                         installing))
      return fail("stream_installing_marker",
                  "could not create map installation marker");
  }
  if (!removeStalePartFiles(inactiveRoot()))
    return fail("stream_part_cleanup", "could not clear stale map part files");
  bytesAtCheckpoint_ = status_.completedPayloadBytes;
  checkpointAtMilliseconds_ = now_();
  return true;
}

bool MapStreamInstallSession::loadMatchingCheckpoint(
    const VerifiedMapStreamManifest &manifest,
    std::string_view canonicalManifest) {
  const auto resetResume = [&]() {
    status_.durableFilePrefix = 0;
    status_.completedFiles = 0;
    status_.completedPayloadBytes = 0;
    checkpointSequence_ = 0;
  };
  const auto tryReady = [&](const std::string &ready) {
    if (jsonString(ready, "sessionId") != sessionId_ ||
        jsonString(ready, "mapId") != status_.mapId ||
        jsonString(ready, "manifestReceipt") != manifest.manifestReceipt ||
        jsonString(ready, "signedManifestReceipt") !=
            manifest.signedManifestReceipt) {
      return false;
    }
    bool haveFiles = false;
    bool havePayload = false;
    const uint64_t files = jsonUnsigned(ready, "fileCount", haveFiles);
    const uint64_t payload = jsonUnsigned(ready, "payloadBytes", havePayload);
    if (!haveFiles || !havePayload || files != manifest.manifest.files.size() ||
        files > UINT32_MAX || payload != manifest.payloadBytes) {
      return false;
    }
    status_.durableFilePrefix = static_cast<uint32_t>(files);
    status_.completedFiles = static_cast<uint32_t>(files);
    status_.completedPayloadBytes = payload;
    status_.sequence = std::max<uint32_t>(status_.sequence, 1);
    if (validateDurablePrefix(manifest, canonicalManifest))
      return true;
    resetResume();
    return false;
  };
  const auto tryCheckpoint = [&](const std::string &checkpoint) {
    bool haveSchema = false;
    bool haveProtocol = false;
    bool haveFormat = false;
    bool havePrefix = false;
    bool havePayload = false;
    bool haveTotalFiles = false;
    bool haveTotalPayload = false;
    bool haveSequence = false;
    const uint64_t schema =
        jsonUnsigned(checkpoint, "schemaVersion", haveSchema);
    const uint64_t protocol =
        jsonUnsigned(checkpoint, "protocolVersion", haveProtocol);
    const uint64_t format =
        jsonUnsigned(checkpoint, "streamFormatVersion", haveFormat);
    const uint64_t prefix =
        jsonUnsigned(checkpoint, "completedFilePrefix", havePrefix);
    const uint64_t payload =
        jsonUnsigned(checkpoint, "completedPayloadBytes", havePayload);
    const uint64_t totalFiles =
        jsonUnsigned(checkpoint, "totalFiles", haveTotalFiles);
    const uint64_t totalPayload =
        jsonUnsigned(checkpoint, "totalPayloadBytes", haveTotalPayload);
    const uint64_t sequence =
        jsonUnsigned(checkpoint, "sequence", haveSequence);
    if (!haveSchema || !haveProtocol || !haveFormat || !havePrefix ||
        !havePayload || !haveTotalFiles || !haveTotalPayload || !haveSequence ||
        schema != 1 || protocol != 2 || format != 1 ||
        jsonString(checkpoint, "sessionId") != sessionId_ ||
        jsonString(checkpoint, "mapId") != status_.mapId ||
        jsonString(checkpoint, "manifestReceipt") != manifest.manifestReceipt ||
        jsonString(checkpoint, "signedManifestReceipt") !=
            manifest.signedManifestReceipt ||
        prefix > manifest.manifest.files.size() ||
        totalFiles != manifest.manifest.files.size() ||
        totalPayload != manifest.payloadBytes || sequence > UINT32_MAX) {
      return false;
    }
    status_.durableFilePrefix = static_cast<uint32_t>(prefix);
    status_.completedFiles = static_cast<uint32_t>(prefix);
    status_.completedPayloadBytes = payload;
    checkpointSequence_ = static_cast<uint32_t>(sequence);
    const uint32_t resumedSequence = checkpointSequence_ == UINT32_MAX
                                         ? UINT32_MAX
                                         : checkpointSequence_ + 1;
    status_.sequence = std::max(status_.sequence, resumedSequence);
    if (validateDurablePrefix(manifest, canonicalManifest))
      return true;
    resetResume();
    return false;
  };

  std::string value;
  const std::string checkpointPath = joinPath(inactiveRoot(), kCheckpointFile);
  for (const std::string &path : {checkpointPath, checkpointPath + ".bak"}) {
    if (storage_->readText(path, value, kMaximumCheckpointBytes) &&
        tryCheckpoint(value)) {
      return true;
    }
  }
  const std::string readyPath = joinPath(inactiveRoot(), kReadyFile);
  for (const std::string &path : {readyPath, readyPath + ".bak"}) {
    if (storage_->readText(path, value, 2048) && tryReady(value))
      return true;
  }
  resetResume();
  return false;
}

bool MapStreamInstallSession::validateDurablePrefix(
    const VerifiedMapStreamManifest &manifest,
    std::string_view canonicalManifest) {
  uint64_t payloadBytes = 0;
  for (size_t index = 0; index < status_.durableFilePrefix; index++) {
    MapStreamFileView file;
    if (!mapStreamFileView(manifest.manifest, canonicalManifest, index, file))
      return false;
    uint64_t storedBytes = 0;
    if (!storage_->regularFileSize(filePath(inactiveRoot(), file),
                                   storedBytes) ||
        storedBytes != file.bytes || payloadBytes > UINT64_MAX - file.bytes) {
      return false;
    }
    payloadBytes += file.bytes;
  }
  return payloadBytes == status_.completedPayloadBytes;
}

bool MapStreamInstallSession::writeCheckpoint(bool force) {
  const uint64_t now = now_();
  const uint64_t bytesSince =
      status_.completedPayloadBytes - bytesAtCheckpoint_;
  const uint64_t elapsed = now >= checkpointAtMilliseconds_
                               ? now - checkpointAtMilliseconds_
                               : UINT64_MAX;
  if (!force && bytesSince < checkpointPolicy_.maximumReworkBytes &&
      elapsed < checkpointPolicy_.maximumReworkMilliseconds) {
    return true;
  }
  if (checkpointSequence_ < UINT32_MAX)
    checkpointSequence_++;
  const std::string checkpoint =
      std::string("{\"completedFilePrefix\":") +
      std::to_string(status_.completedFiles) + ",\"completedPayloadBytes\":" +
      std::to_string(status_.completedPayloadBytes) +
      ",\"manifestReceipt\":\"" + status_.manifestReceipt + "\",\"mapId\":\"" +
      jsonEscape(status_.mapId) +
      "\",\"protocolVersion\":2,\"schemaVersion\":1,\"sequence\":" +
      std::to_string(checkpointSequence_) + ",\"sessionId\":\"" +
      jsonEscape(sessionId_) + "\",\"signedManifestReceipt\":\"" +
      status_.signedManifestReceipt +
      "\",\"streamFormatVersion\":1,\"totalFiles\":" +
      std::to_string(status_.totalFiles) +
      ",\"totalPayloadBytes\":" + std::to_string(status_.totalPayloadBytes) +
      "}\n";
  const uint64_t checkpointStarted = now_();
  if (!writeFileAtomic(*storage_, joinPath(inactiveRoot(), kCheckpointFile),
                       checkpoint))
    return fail("stream_checkpoint_write",
                "could not persist map stream checkpoint");
  const uint64_t checkpointFinished = now_();
  if (checkpointFinished >= checkpointStarted) {
    status_.checkpointMilliseconds += checkpointFinished - checkpointStarted;
  }
  status_.durableFilePrefix = status_.completedFiles;
  bytesAtCheckpoint_ = status_.completedPayloadBytes;
  checkpointAtMilliseconds_ = now;
  return true;
}

bool MapStreamInstallSession::writeFinalMetadata(
    const VerifiedMapStreamManifest &manifest) {
  if (!removeStalePartFiles(inactiveRoot()))
    return fail("stream_part_cleanup",
                "could not remove partial map files before finalization");
  if (!writeFileAtomic(*storage_, joinPath(inactiveRoot(), kManifestFile),
                       canonicalManifest_))
    return fail("stream_manifest_write",
                "could not publish installed map manifest");
  advanceFinalization();
  if (!writeFileAtomic(*storage_,
                       joinPath(inactiveRoot(), kManifestReceiptFile),
                       status_.manifestReceipt))
    return fail("stream_receipt_write",
                "could not publish installed map receipt");
  advanceFinalization();
  const std::string ready =
      std::string("{\"fileCount\":") + std::to_string(status_.totalFiles) +
      ",\"manifestReceipt\":\"" + status_.manifestReceipt + "\",\"mapId\":\"" +
      jsonEscape(status_.mapId) +
      "\",\"payloadBytes\":" + std::to_string(status_.totalPayloadBytes) +
      ",\"protocolVersion\":2,\"sessionId\":\"" + jsonEscape(sessionId_) +
      "\",\"signedManifestReceipt\":\"" + status_.signedManifestReceipt +
      "\",\"streamFormatVersion\":1}\n";
  if (!writeFileAtomic(*storage_, joinPath(inactiveRoot(), kReadyFile), ready))
    return fail("stream_ready_write", "could not publish map ready marker");
  advanceFinalization();
  const std::string pending =
      std::string("{\"manifestReceipt\":\"") + status_.manifestReceipt +
      "\",\"mapId\":\"" + jsonEscape(status_.mapId) + "\",\"root\":\"" +
      inactiveRootRelative() + "\",\"sessionId\":\"" + jsonEscape(sessionId_) +
      "\",\"signedManifestReceipt\":\"" + status_.signedManifestReceipt +
      "\"}\n";
  if (!writeFileAtomic(*storage_, joinPath(storageRoot_, kPendingFile),
                       pending))
    return fail("stream_pending_write",
                "could not persist pending map activation");
  advanceFinalization();
  if (!storage_->removeTree(joinPath(inactiveRoot(), kInstallingFile)) ||
      !storage_->syncDirectory(inactiveRoot())) {
    return fail("stream_installing_cleanup",
                "map is ready but installation marker cleanup failed");
  }
  advanceFinalization();
  status_.state = MapStreamInstallState::Ready;
  status_.durableFilePrefix = status_.totalFiles;
  status_.errorCode.clear();
  status_.errorMessage.clear();
  (void)manifest;
  return true;
}

bool MapStreamInstallSession::removeStalePartFiles(const std::string &path) {
  bool ok = true;
  const bool enumerated = storage_->forEachDirectoryEntry(
      path, [&](const MapStreamDirectoryEntry &entry) {
        const std::string &name = entry.name;
        const std::string child = joinPath(path, name);
        if (entry.directory) {
          if (!removeStalePartFiles(child))
            ok = false;
        } else if (name.size() >= 5 &&
                   name.substr(name.size() - 5) == ".part" &&
                   !storage_->removeTree(child)) {
          ok = false;
        }
        return true;
      });
  return enumerated && ok;
}

void MapStreamInstallSession::closeCurrentFile(bool removePart) {
  if (currentFd_ >= 0) {
    storage_->closeFile(currentFd_);
    currentFd_ = -1;
  }
  if (removePart && !currentPartPath_.empty())
    storage_->removeTree(currentPartPath_);
  currentPartPath_.clear();
  currentFile_ = -1;
  currentSkipped_ = false;
}

} // namespace map_transfer
