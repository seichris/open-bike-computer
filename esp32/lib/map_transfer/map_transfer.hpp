#pragma once

#include <cstddef>
#include <cstdint>
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
  std::vector<ManifestFile> files;
};

struct InstallStatus {
  bool ok = false;
  std::string code;
  std::string message;
};

enum class ActivationBeginResult {
  Started,
  AlreadyRunning,
  Busy,
};

struct MapActivationSnapshot {
  bool running = false;
  uint32_t sequence = 0;
  std::string status = "idle";
  std::string sessionId;
  std::string mapId;
  std::string errorCode;
  std::string errorMessage;
};

class MapActivationState {
public:
  ActivationBeginResult begin(const std::string &sessionId);
  void finish(const std::string &status, const std::string &mapId,
              const std::string &errorCode,
              const std::string &errorMessage);
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
  InstallStatus validateStagedMap(const std::string &sessionId,
                                  MapManifest &manifest) const;
  InstallStatus activateStagedMap(const std::string &sessionId,
                                  const MapManifest &manifest) const;
  InstallStatus recoverInterruptedActivation() const;
  InstallStatus readActiveMapId(std::string &mapId) const;
  bool pruneStagingSessions(const std::string &keepSessionId) const;

  std::string stagingRoot(const std::string &sessionId) const;

protected:
  virtual bool writeTextFileAtomic(const std::string &path,
                                   const std::string &text) const;

private:
  std::string storageRoot_;

  InstallStatus fail(const std::string &code, const std::string &message) const;
  bool safeId(const std::string &value) const;
  bool safeRelativePath(const std::string &path) const;
  bool mkdirs(const std::string &path) const;
  bool copyFile(const std::string &from, const std::string &to) const;
  bool copyTree(const std::string &from, const std::string &to) const;
  bool movePath(const std::string &from, const std::string &to) const;
  bool removeTree(const std::string &path) const;
  bool backupPublishedMap(const std::string &backupRoot) const;
  bool restorePublishedMap(const std::string &backupRoot) const;
  bool clearPublishedMap() const;
  bool publishActivation(const std::string &activationRoot) const;
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
