#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace map_transfer {

struct ManifestFile {
  std::string path;
  std::string publishPath;
  std::string sha256;
  uint64_t bytes = 0;
};

struct MapManifest {
  uint32_t schemaVersion = 0;
  std::string mapId;
  std::string renderer;
  uint32_t formatVersion = 0;
  std::string minimumFirmwareVersion;
  std::vector<ManifestFile> files;
};

struct InstallStatus {
  bool ok = false;
  std::string code;
  std::string message;
};

struct ActivationProgress {
  uint8_t step = 1;
  uint8_t totalSteps = 5;
  uint64_t completed = 0;
  uint64_t total = 0;
};

using ActivationProgressCallback =
    std::function<void(const ActivationProgress &progress)>;

struct ActiveMapSelection {
  std::string mapId;
  std::string sessionId;
  std::string root;
  std::string previousMapId;
  std::string previousSessionId;
  std::string previousRoot;
  std::string previousManifestReceipt;
  std::string previousSignedManifestReceipt;
  std::string manifestReceipt;
  std::string signedManifestReceipt;
};

struct ReadyStreamMap {
  std::string sessionId;
  std::string mapId;
  std::string root;
  std::string manifestReceipt;
  std::string signedManifestReceipt;
  uint32_t fileCount = 0;
  uint64_t payloadBytes = 0;
};

class Sha256Hasher {
public:
  void update(const uint8_t *data, size_t len);
  std::string finalHex();

private:
  std::array<uint8_t, 64> block_ = {};
  size_t blockLen_ = 0;
  uint64_t totalLen_ = 0;
  uint32_t h_[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

  void transform(const uint8_t *chunk);
};

enum class ActivationBeginResult {
  Started,
  AlreadyRunning,
  AlreadyInstalled,
  Busy,
};

struct MapActivationSnapshot {
  bool running = false;
  uint32_t sequence = 0;
  std::string status = "idle";
  std::string sessionId;
  std::string mapId;
  uint8_t step = 0;
  uint8_t totalSteps = 5;
  uint8_t progress = 0;
  std::string errorCode;
  std::string errorMessage;
};

class MapActivationState {
public:
  ActivationBeginResult begin(const std::string &sessionId,
                              uint8_t totalSteps = 5);
  void updateProgress(const ActivationProgress &progress);
  void finish(const std::string &status, const std::string &mapId,
              const std::string &errorCode, const std::string &errorMessage);
  bool acceptsUploads() const;
  MapActivationSnapshot snapshot() const;
  std::string json(bool compact = false) const;

private:
  MapActivationSnapshot state_;
};

class MapTransferInstaller {
public:
  explicit MapTransferInstaller(std::string storageRoot = "/sdcard");
  virtual ~MapTransferInstaller() = default;

  InstallStatus validateManifestText(const std::string &manifestText,
                                     MapManifest &manifest) const;
  InstallStatus readStagedManifest(const std::string &sessionId,
                                   MapManifest &manifest) const;
  InstallStatus
  validateStagedMap(const std::string &sessionId, MapManifest &manifest,
                    const ActivationProgressCallback &onProgress = {}) const;
  InstallStatus
  prepareStagedArchive(const std::string &sessionId,
                       const ActivationProgressCallback &onProgress = {}) const;
  InstallStatus expectedStagedFile(const std::string &sessionId,
                                   const std::string &path,
                                   ManifestFile &file) const;
  bool stagedFileVerified(const std::string &sessionId,
                          const ManifestFile &file) const;
  bool markStagedFileVerified(const std::string &sessionId,
                              const ManifestFile &file) const;
  void clearStagedFileVerification(const std::string &sessionId,
                                   const ManifestFile &file) const;
  InstallStatus
  activateStagedMap(const std::string &sessionId, const MapManifest &manifest,
                    const ActivationProgressCallback &onProgress = {}) const;
  InstallStatus recoverInterruptedActivation() const;
  InstallStatus activateReadyStreamMap(
      const std::string &sessionId,
      const ActivationProgressCallback &onProgress = {}) const;
  InstallStatus recoverPendingStreamActivation(
      const ActivationProgressCallback &onProgress = {}) const;
  bool hasInterruptedActivation() const;
  InstallStatus readActiveMap(ActiveMapSelection &selection) const;
  InstallStatus readActiveMapId(std::string &mapId) const;
  bool pruneStagingSessions(const std::string &keepSessionId) const;
  bool pruneObsoleteInstalledMaps() const;
  bool markPendingArchiveActivation(const std::string &sessionId) const;
  bool readPendingArchiveActivation(std::string &sessionId) const;
  bool clearPendingArchiveActivation() const;
  bool discardStagedSession(const std::string &sessionId) const;

  std::string stagingRoot(const std::string &sessionId) const;
  std::string stagedArchivePath(const std::string &sessionId) const;

protected:
  virtual bool writeTextFileAtomic(const std::string &path,
                                   const std::string &text) const;

private:
  std::string storageRoot_;

  InstallStatus fail(const std::string &code, const std::string &message) const;
  bool safeId(const std::string &value) const;
  bool safeMapId(const std::string &value) const;
  bool safeActiveRoot(const std::string &value) const;
  bool safeRelativePath(const std::string &path) const;
  bool mkdirs(const std::string &path) const;
  bool copyFile(const std::string &from, const std::string &to) const;
  bool copyTree(const std::string &from, const std::string &to) const;
  bool movePath(const std::string &from, const std::string &to) const;
  bool removeTree(const std::string &path) const;
  std::string verificationPath(const std::string &sessionId,
                               const ManifestFile &file) const;
  bool publishStagedFiles(const std::string &sessionId,
                          const MapManifest &manifest,
                          const std::string &destinationRoot,
                          const ActivationProgressCallback &onProgress) const;
  bool publishInstalledMetadata(const std::string &sessionId,
                                const MapManifest &manifest,
                                const std::string &destinationRoot) const;
  std::string manifestReceipt(const MapManifest &manifest) const;
  InstallStatus readInstalledManifest(const std::string &root,
                                      MapManifest &manifest) const;
  bool installedMapReceiptMatches(const std::string &root,
                                  const MapManifest &manifest) const;
  bool installedMapContentsMatch(const std::string &root,
                                 const MapManifest &manifest) const;
  bool writeActiveMap(const ActiveMapSelection &selection) const;
  InstallStatus readReadyStreamMap(const std::string &sessionId,
                                   ReadyStreamMap &ready) const;
  InstallStatus
  recoverStreamActivationTransaction(const std::string &transaction) const;
  bool clearPendingStreamActivation(const std::string &sessionId) const;
  bool markStreamActivationConsumed(const ReadyStreamMap &ready) const;
  bool rollbackRootMatches(const std::string &root, const std::string &mapId,
                           const std::string &manifestReceipt,
                           const std::string &signedManifestReceipt) const;
  bool activeRootExists(const std::string &root) const;
  bool fileExists(const std::string &path) const;
  bool dirExists(const std::string &path) const;
  bool fileSize(const std::string &path, uint64_t &size) const;
  bool fileSha256Hex(const std::string &path, std::string &hex) const;
  bool writeTextFile(const std::string &path, const std::string &text) const;
  bool readTextFile(const std::string &path, std::string &text,
                    size_t maxBytes) const;
};

std::string sha256Hex(const uint8_t *data, size_t len);

} // namespace map_transfer
