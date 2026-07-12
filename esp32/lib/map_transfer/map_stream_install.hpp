#pragma once

#include "map_stream_parser.hpp"

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>

namespace map_transfer {

enum class MapStreamInstallState {
  Idle,
  Receiving,
  Paused,
  Finalizing,
  Ready,
  Failed,
};

const char *mapStreamInstallStateCode(MapStreamInstallState state);

struct MapStreamCheckpointPolicy {
  uint64_t maximumReworkBytes = 8ULL * 1024ULL * 1024ULL;
  uint64_t maximumReworkMilliseconds = 15000;
};

struct MapStreamInstallSnapshot {
  MapStreamInstallState state = MapStreamInstallState::Idle;
  uint32_t sequence = 0;
  std::string sessionId;
  std::string mapId;
  std::string manifestReceipt;
  std::string signedManifestReceipt;
  uint64_t receivedPayloadBytes = 0;
  uint64_t totalPayloadBytes = 0;
  uint64_t completedPayloadBytes = 0;
  uint64_t bytesWritten = 0;
  uint64_t bytesSkipped = 0;
  uint64_t sdWriteMilliseconds = 0;
  uint64_t fileCommitMilliseconds = 0;
  uint64_t checkpointMilliseconds = 0;
  uint64_t finalizationMilliseconds = 0;
  uint32_t completedFiles = 0;
  uint32_t totalFiles = 0;
  uint32_t durableFilePrefix = 0;
  uint8_t currentStep = 1;
  uint8_t finalizationCompleted = 0;
  uint8_t finalizationTotal = 6;
  std::string errorCode;
  std::string errorMessage;

  uint8_t step() const;
  uint8_t totalSteps() const;
  uint8_t progress() const;
  std::string json(bool compact = false) const;
};

enum class MapStreamRecoveryResult { None, Found, Ambiguous, Invalid };

MapStreamRecoveryResult
readRecoverableMapStreamInstall(const std::string &storageRoot,
                                MapStreamInstallSnapshot &snapshot);

using MapStreamNowCallback = std::function<uint64_t()>;

struct MapStreamDirectoryEntry {
  std::string name;
  bool directory = false;
};

// Filesystem boundary for stream installation. The production implementation
// uses the ESP-IDF/POSIX VFS, while host tests can fail individual write,
// flush, close, rename, directory-sync, and metadata operations at exact crash
// boundaries.
class MapStreamStorage {
public:
  virtual ~MapStreamStorage() = default;
  virtual bool createDirectories(const std::string &path) = 0;
  virtual bool removeTree(const std::string &path) = 0;
  virtual bool regularFileSize(const std::string &path, uint64_t &bytes) = 0;
  virtual bool readText(const std::string &path, std::string &value,
                        size_t maximumBytes) = 0;
  virtual bool forEachDirectoryEntry(
      const std::string &path,
      const std::function<bool(const MapStreamDirectoryEntry &)> &callback) = 0;
  virtual int openWrite(const std::string &path) = 0;
  virtual bool write(int descriptor, const uint8_t *data, size_t size) = 0;
  virtual bool syncFile(int descriptor) = 0;
  virtual bool closeFile(int descriptor) = 0;
  virtual bool renamePath(const std::string &from, const std::string &to) = 0;
  virtual bool syncDirectory(const std::string &path) = 0;
};

std::shared_ptr<MapStreamStorage> makeDefaultMapStreamStorage();

// Consumes an authenticated map stream directly into an inactive installed-map
// root. Final files are written once through `.part`, checkpoints are one
// atomic compact journal, and the active-map pointer is never touched here.
class MapStreamInstallSession final : public MapStreamConsumer {
public:
  MapStreamInstallSession(std::string storageRoot, std::string sessionId,
                          MapStreamCheckpointPolicy checkpointPolicy = {},
                          MapStreamNowCallback now = {},
                          std::shared_ptr<MapStreamStorage> storage = {});
  ~MapStreamInstallSession() override;

  bool onManifest(const VerifiedMapStreamManifest &manifest,
                  std::string_view canonicalManifest) override;
  MapStreamFileAction onFileBegin(const MapStreamFileView &file,
                                  size_t index) override;
  bool onFileData(const MapStreamFileView &file, const uint8_t *data,
                  size_t size) override;
  bool onFileEnd(const MapStreamFileView &file, size_t index) override;
  bool onComplete(const VerifiedMapStreamManifest &manifest) override;
  void onAbort(MapStreamParserError error) override;

  const MapStreamInstallSnapshot &snapshot() const;
  std::string inactiveRoot() const;
  std::string inactiveRootRelative() const;

private:
  std::string storageRoot_;
  std::string sessionId_;
  MapStreamCheckpointPolicy checkpointPolicy_;
  MapStreamNowCallback now_;
  std::shared_ptr<MapStreamStorage> storage_;
  MapStreamInstallSnapshot status_;
  std::string_view canonicalManifest_;
  int currentFd_ = -1;
  int currentFile_ = -1;
  size_t nextFileIndex_ = 0;
  std::string currentPartPath_;
  bool currentSkipped_ = false;
  uint64_t bytesAtCheckpoint_ = 0;
  uint64_t checkpointAtMilliseconds_ = 0;
  uint32_t checkpointSequence_ = 0;

  bool fail(const std::string &code, const std::string &message);
  bool safeId(const std::string &value) const;
  bool prepareRoot(const VerifiedMapStreamManifest &manifest,
                   std::string_view canonicalManifest);
  bool loadMatchingCheckpoint(const VerifiedMapStreamManifest &manifest,
                              std::string_view canonicalManifest);
  bool validateDurablePrefix(const VerifiedMapStreamManifest &manifest,
                             std::string_view canonicalManifest);
  void advanceFinalization();
  bool writeCheckpoint(bool force);
  bool writeFinalMetadata(const VerifiedMapStreamManifest &manifest);
  bool removeStalePartFiles(const std::string &path);
  void closeCurrentFile(bool removePart);
};

} // namespace map_transfer
