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

struct MapPresentationMetadata {
  std::string displayName;
  std::array<int32_t, 4> boundsE7 = {};
  bool hasBoundsE7 = false;
};

struct MapPresentationRevision {
  uint64_t bytes = 0;
  int64_t modifiedSeconds = 0;
  uint64_t inode = 0;
};

struct MapManifest {
  uint32_t schemaVersion = 0;
  std::string mapId;
  std::string displayName;
  std::array<int32_t, 4> boundsE7 = {};
  bool hasBoundsE7 = false;
  std::string renderer;
  uint32_t formatVersion = 0;
  uint32_t labelProfileVersion = 0;
  std::vector<std::string> labelLanguages;
  std::string internationalFallback;
  uint32_t buildingProfileVersion = 0;
  uint32_t topographyProfileVersion = 0;
  uint32_t buildingRecordCount = 0;
  uint32_t buildingProvenanceCounts[5] = {0, 0, 0, 0, 0};
  uint32_t contourRecordCount = 0;
  uint32_t contourPointCount = 0;
  uint32_t contourMinorIntervalM = 0;
  uint32_t contourIndexIntervalM = 0;
  uint32_t contourNoDataMillionths = 0;
  std::string contourQualityMode;
  std::string topographySourcePolicySha256;
  std::string topographyIntermediateSha256;
  std::string topographyAttributionSha256;
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

struct MapTargetMetadata {
  std::string renderer;
  uint32_t formatVersion = 0;
  uint32_t labelProfileVersion = 0;
  std::vector<std::string> labelLanguages;
  std::string internationalFallback;
  uint32_t buildingProfileVersion = 0;
  uint32_t topographyProfileVersion = 0;
  std::string topographyQualityMode;
  uint32_t contourMinorIntervalM = 0;
  uint32_t contourIndexIntervalM = 0;
  uint32_t contourRecordCount = 0;
  uint32_t contourNoDataMillionths = 0;
  std::string topographySourcePolicySha256;
};

struct ActiveMapSelection {
  std::string mapId;
  std::string sessionId;
  std::string root;
  MapTargetMetadata target;
  std::string previousMapId;
  std::string previousSessionId;
  std::string previousRoot;
  MapTargetMetadata previousTarget;
  std::string previousManifestReceipt;
  std::string previousSignedManifestReceipt;
  std::string manifestReceipt;
  std::string signedManifestReceipt;
};

struct ReadyStreamMap {
  std::string operationID;
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
  std::array<char, 64> ownerRecoveryCode{};
  std::array<char, 64> terminalCode{};
};

class MapActivationState {
public:
  ActivationBeginResult begin(const std::string &sessionId,
                              uint8_t totalSteps = 5,
                              uint32_t minimumSequence = 0);
  void updateProgress(const ActivationProgress &progress);
  void finish(std::string status, std::string mapId,
              std::string errorCode, std::string errorMessage);
  void rememberOwnerRecovery(const char *code) noexcept;
  bool acceptsUploads() const;
  MapActivationSnapshot snapshot() const;
  std::string json(bool compact = false) const;
  const std::array<char, 64> &ownerRecoveryCode() const { return state_.ownerRecoveryCode; }
  const std::array<char, 64> &terminalCode() const { return state_.terminalCode; }

private:
  MapActivationSnapshot state_;
};

class MapTransferInstaller {
public:
  explicit MapTransferInstaller(std::string storageRoot = "/sdcard");
  virtual ~MapTransferInstaller() = default;
  InstallStatus readReadyStreamMap(const std::string &sessionId,
                                   ReadyStreamMap &ready) const;
  InstallStatus readPreparedOperation(const std::string &sessionId,
                                      ReadyStreamMap &prepared) const;
  InstallStatus cancelOperationStaging(const std::string &sessionId,
                                       const std::string &operationID) const;
  InstallStatus finalizeOperation(const std::string &sessionId,
                                  const std::string &operationID) const;
  InstallStatus promotePreparedOperation(const std::string &sessionId,
                                         const std::string &operationID) const;
  void setOperationDeviceID(std::string device) { operationDeviceID_ = std::move(device); }
  using StorageProgressCallback = void (*)(void *);
  void setStorageProgressCallback(StorageProgressCallback callback, void *context) {
    storageProgressCallback_ = callback; storageProgressContext_ = context;
  }

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
  using ActivationRecoveryCallback = void (*)(void *, const char *);
  InstallStatus activateReadyStreamMap(
      const std::string &sessionId,
      const ActivationProgressCallback &onProgress = {},
      ActivationRecoveryCallback onRecovery = nullptr, void *recoveryContext = nullptr) const;
  InstallStatus recoverPendingStreamActivation(
      const ActivationProgressCallback &onProgress = {},
      ActivationRecoveryCallback onRecovery = nullptr, void *recoveryContext = nullptr) const;
  bool hasInterruptedActivation() const;
  InstallStatus readActiveMap(ActiveMapSelection &selection) const;
  // Signed streams persist their manifest receipt in the active pointer.
  // Legacy archives predate that pointer field, so use the bounded canonical
  // receipt that activation persisted after verifying their manifest.
  InstallStatus readActiveMapContentReceipt(ActiveMapSelection &selection,
                                            std::string &receipt) const;
  InstallStatus readActiveManifest(MapManifest &manifest) const;
  InstallStatus readActiveMapPresentation(
      ActiveMapSelection &selection,
      MapPresentationMetadata &presentation) const;
  bool readActiveMapPresentationRevision(
      const ActiveMapSelection &selection,
      MapPresentationRevision &revision) const;
  InstallStatus readActiveMapId(std::string &mapId) const;
  InstallStatus rollbackActiveMap(const std::string &sessionId) const;
  InstallStatus discardIncompleteStreamMap(
      const std::string &sessionId) const;
  InstallStatus discardUnselectedStreamMap(
      const std::string &sessionId) const;
  InstallStatus discardAllUnselectedStreamMaps() const;
  bool pruneStagingSessions(const std::string &keepSessionId) const;
  bool pruneObsoleteInstalledMaps(
      const std::string &keepInstallingSessionId = "") const;
  bool markPendingArchiveActivation(const std::string &sessionId) const;
  bool readPendingArchiveActivation(std::string &sessionId) const;
  bool clearPendingArchiveActivation() const;
  bool discardStagedSession(const std::string &sessionId) const;

  std::string stagingRoot(const std::string &sessionId) const;
  std::string stagedArchivePath(const std::string &sessionId) const;

protected:
  virtual int renameStoragePath(const char *from, const char *to) const;
  // Exact mutation boundary seam for crash qualification. Production is a
  // no-op; host faults can interrupt before or after the real IO operation.
  virtual void storageMutationBoundary(const char *operation,
                                       const std::string &path,
                                       bool after) const {
    (void)operation; (void)path; (void)after;
  }
  virtual bool writeTextFileAtomic(const std::string &path,
                                   const std::string &text) const;

private:
  // These phases run on the fixed internal owner stack. Keep the selection
  // locals out of recovery and unwind pending resolution before activation.
  __attribute__((noinline)) InstallStatus recoverStreamSelection() const;
  __attribute__((noinline)) InstallStatus selectReadyStreamMap(
      const std::string &sessionId, const ActivationProgressCallback &onProgress,
      bool &needsSelectionRecovery) const;
  __attribute__((noinline)) InstallStatus resolvePendingStreamActivation(
      std::string &sessionId) const;
  __attribute__((noinline)) InstallStatus recoverActiveSelection() const;
  bool preparationBlocksActivation(const ReadyStreamMap &ready) const;
  InstallStatus readStreamMapMetadata(const std::string &sessionId,
                                      ReadyStreamMap &ready, bool prepared) const;
  std::string storageRoot_;
  std::string operationDeviceID_;
  StorageProgressCallback storageProgressCallback_ = nullptr;
  void *storageProgressContext_ = nullptr;

  // Share error-result construction across the many validation exits. Owning
  // parameters move into the result rather than allocating a second copy.
  __attribute__((noinline)) InstallStatus fail(const char *code,
                                              std::string message) const;
  __attribute__((noinline)) InstallStatus fail(const char *code,
                                              const char *message) const;
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
  __attribute__((noinline)) bool writeActiveMap(const ActiveMapSelection &selection) const;
  __attribute__((noinline)) bool writeCanonicalActiveMap(const ActiveMapSelection &selection) const;
  InstallStatus parseActiveMapText(const std::string &text, ActiveMapSelection &selection) const;
  __attribute__((noinline)) bool persistPredecessorAnchor(const ActiveMapSelection &incoming) const;
  InstallStatus recoverSelectionAnchor() const;
  bool selectionAnchorProtectsRoot(const std::string &root) const;
  __attribute__((noinline)) bool anchorSelectionVerified(const ActiveMapSelection &selection) const;
  __attribute__((noinline)) InstallStatus
  recoverStreamActivationTransaction(const std::string &transaction) const;
  __attribute__((noinline)) InstallStatus recoverLegacyActivationTransaction(
      const std::string &transaction) const;
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
  InstallStatus validateLabelContracts(const std::string &root,
                                       const MapManifest &manifest,
                                       bool useManifestPaths) const;
};

std::string sha256Hex(const uint8_t *data, size_t len);

} // namespace map_transfer
