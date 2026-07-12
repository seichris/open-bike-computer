#include "../../lib/map_transfer/map_stream_format.hpp"
#include "../../lib/map_transfer/map_stream_install.hpp"
#include "../../lib/map_transfer/map_transfer.hpp"

#include <array>
#include <cassert>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

using map_transfer::ActiveMapSelection;
using map_transfer::MapStreamCheckpointPolicy;
using map_transfer::MapStreamFileAction;
using map_transfer::MapStreamFileView;
using map_transfer::MapStreamHeader;
using map_transfer::MapStreamInstallSession;
using map_transfer::MapStreamInstallSnapshot;
using map_transfer::MapStreamInstallState;
using map_transfer::MapStreamRecoveryResult;
using map_transfer::MapStreamStorage;
using map_transfer::MapTransferInstaller;
using map_transfer::ParsedMapStreamManifest;
using map_transfer::VerifiedMapStreamManifest;

namespace {

enum class FaultOperation {
  None,
  Write,
  SyncFile,
  CloseFile,
  Rename,
  Remove,
  SyncDirectory
};

class FaultInjectingStorage final : public MapStreamStorage {
public:
  FaultInjectingStorage(FaultOperation operation, std::string pathNeedle)
      : delegate_(map_transfer::makeDefaultMapStreamStorage()),
        operation_(operation), pathNeedle_(std::move(pathNeedle)) {}

  bool createDirectories(const std::string &path) override {
    return delegate_->createDirectories(path);
  }
  bool removeTree(const std::string &path) override {
    if (fail(FaultOperation::Remove, path))
      return false;
    return delegate_->removeTree(path);
  }
  bool regularFileSize(const std::string &path, uint64_t &bytes) override {
    return delegate_->regularFileSize(path, bytes);
  }
  bool readText(const std::string &path, std::string &value,
                size_t maximumBytes) override {
    return delegate_->readText(path, value, maximumBytes);
  }
  bool forEachDirectoryEntry(
      const std::string &path,
      const std::function<bool(
          const map_transfer::MapStreamDirectoryEntry &)> &callback) override {
    return delegate_->forEachDirectoryEntry(path, callback);
  }
  int openWrite(const std::string &path) override {
    const int descriptor = delegate_->openWrite(path);
    if (descriptor >= 0)
      paths_[descriptor] = path;
    return descriptor;
  }
  bool write(int descriptor, const uint8_t *data, size_t size) override {
    if (fail(FaultOperation::Write, pathFor(descriptor)))
      return false;
    return delegate_->write(descriptor, data, size);
  }
  bool syncFile(int descriptor) override {
    if (fail(FaultOperation::SyncFile, pathFor(descriptor)))
      return false;
    return delegate_->syncFile(descriptor);
  }
  bool closeFile(int descriptor) override {
    const std::string path = pathFor(descriptor);
    const bool closed = delegate_->closeFile(descriptor);
    paths_.erase(descriptor);
    return fail(FaultOperation::CloseFile, path) ? false : closed;
  }
  bool renamePath(const std::string &from, const std::string &to) override {
    if (fail(FaultOperation::Rename, to))
      return false;
    const bool renamed = delegate_->renamePath(from, to);
    if (renamed)
      lastRenamedPath_ = to;
    return renamed;
  }
  bool syncDirectory(const std::string &path) override {
    if (fail(FaultOperation::SyncDirectory,
             lastRenamedPath_.empty() ? path : lastRenamedPath_))
      return false;
    return delegate_->syncDirectory(path);
  }

  bool fired() const { return fired_; }

private:
  std::shared_ptr<MapStreamStorage> delegate_;
  FaultOperation operation_;
  std::string pathNeedle_;
  std::unordered_map<int, std::string> paths_;
  std::string lastRenamedPath_;
  bool fired_ = false;

  std::string pathFor(int descriptor) const {
    const auto found = paths_.find(descriptor);
    return found == paths_.end() ? std::string() : found->second;
  }
  bool fail(FaultOperation operation, const std::string &path) {
    if (fired_ || operation_ != operation || path.size() < pathNeedle_.size() ||
        path.compare(path.size() - pathNeedle_.size(), pathNeedle_.size(),
                     pathNeedle_) != 0) {
      return false;
    }
    fired_ = true;
    return true;
  }
};

class ActiveWriteFailingInstaller final : public MapTransferInstaller {
public:
  using MapTransferInstaller::MapTransferInstaller;

protected:
  bool writeTextFileAtomic(const std::string &path,
                           const std::string &text) const override {
    if (path.size() >= 24 &&
        path.compare(path.size() - 24, 24, "/VECTMAP/active-map.json") == 0) {
      return false;
    }
    return MapTransferInstaller::writeTextFileAtomic(path, text);
  }
};

std::string tempRoot() {
  std::string pattern = "/tmp/open-bike-map-stream-install-XXXXXX";
  char *created = ::mkdtemp(pattern.data());
  assert(created != nullptr);
  return created;
}

bool exists(const std::string &path) {
  struct stat status;
  return ::stat(path.c_str(), &status) == 0;
}

std::string readFile(const std::string &path) {
  std::ifstream input(path, std::ios::binary);
  assert(input.good());
  std::ostringstream value;
  value << input.rdbuf();
  return value.str();
}

void writeFile(const std::string &path, const std::string &value) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  assert(output.good());
  output << value;
  output.close();
  assert(output.good());
}

const std::string kManifest =
    "{\"files\":[{\"bytes\":1,\"path\":\"VECTMAP/multi/+0000+0000/0.fmb\","
    "\"sha256\":"
    "\"ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb\"},"
    "{\"bytes\":2,\"path\":\"VECTMAP/multi/+0000+0000/1.fmb\","
    "\"sha256\":"
    "\"1e0bbd6c686ba050b8eb03ffeedc64fdc9d80947fce821abbe5d6dc8d252c5ac\"},"
    "{\"bytes\":3,\"path\":\"VECTMAP/multi/+0000+0000/2.fmp\","
    "\"sha256\":"
    "\"cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34\"}],"
    "\"mapId\":\"multi\",\"schemaVersion\":1,\"target\":{\"formatVersion\":1,"
    "\"minFirmwareVersion\":\"0.0.0\",\"renderer\":\"esp32-fmb\"}}";

VerifiedMapStreamManifest
verified(const std::string &signedReceipt = std::string(64, '2')) {
  VerifiedMapStreamManifest value;
  MapStreamHeader header;
  header.fileCount = 3;
  header.payloadBytes = 6;
  assert(
      map_transfer::parseMapStreamManifest(kManifest, header, value.manifest));
  value.manifestReceipt = map_transfer::mapStreamManifestReceipt(
      reinterpret_cast<const uint8_t *>(kManifest.data()), kManifest.size());
  value.signedManifestReceipt = signedReceipt;
  value.signatureKeyId = "test-key";
  value.payloadBytes = 6;
  return value;
}

MapStreamFileView fileView(const VerifiedMapStreamManifest &manifest,
                           size_t index) {
  MapStreamFileView file;
  assert(map_transfer::mapStreamFileView(manifest.manifest, kManifest, index,
                                         file));
  return file;
}

void consumeFile(MapStreamInstallSession &session,
                 const VerifiedMapStreamManifest &manifest, size_t index,
                 const std::string &payload,
                 MapStreamFileAction expectedAction) {
  const MapStreamFileView file = fileView(manifest, index);
  assert(session.onFileBegin(file, index) == expectedAction);
  assert(session.onFileData(
      file, reinterpret_cast<const uint8_t *>(payload.data()), payload.size()));
  assert(session.onFileEnd(file, index));
}

bool consumeAll(MapStreamInstallSession &session,
                const VerifiedMapStreamManifest &manifest) {
  const std::array<std::string, 3> payloads = {"a", "bc", "def"};
  for (size_t index = 0; index < payloads.size(); index++) {
    const MapStreamFileView file = fileView(manifest, index);
    const MapStreamFileAction action = session.onFileBegin(file, index);
    if (action == MapStreamFileAction::Reject ||
        !session.onFileData(
            file, reinterpret_cast<const uint8_t *>(payloads[index].data()),
            payloads[index].size()) ||
        !session.onFileEnd(file, index)) {
      return false;
    }
  }
  return true;
}

VerifiedMapStreamManifest prepareReadyRoot(const std::string &root,
                                           const std::string &sessionId) {
  auto manifest = verified();
  MapStreamInstallSession session(root, sessionId, {1, 10000});
  assert(session.onManifest(manifest, kManifest));
  consumeFile(session, manifest, 0, "a", MapStreamFileAction::VerifyAndConsume);
  consumeFile(session, manifest, 1, "bc",
              MapStreamFileAction::VerifyAndConsume);
  consumeFile(session, manifest, 2, "def",
              MapStreamFileAction::VerifyAndConsume);
  assert(session.onComplete(manifest));
  return manifest;
}

void testDirectWriteCheckpointAndReady() {
  const std::string root = tempRoot();
  uint64_t now = 100;
  const auto manifest = verified();
  MapStreamInstallSession session(root, "session-1", {2, 10000},
                                  [&now] { return now; });
  assert(session.onManifest(manifest, kManifest));
  assert(session.snapshot().state == MapStreamInstallState::Receiving);
  assert(!exists(root + "/VECTMAP/active-map.json"));
  consumeFile(session, manifest, 0, "a", MapStreamFileAction::VerifyAndConsume);
  assert(!exists(session.inactiveRoot() + "/.stream-checkpoint"));
  consumeFile(session, manifest, 1, "bc",
              MapStreamFileAction::VerifyAndConsume);
  assert(exists(session.inactiveRoot() + "/.stream-checkpoint"));
  assert(session.snapshot().durableFilePrefix == 2);
  now += 10001;
  consumeFile(session, manifest, 2, "def",
              MapStreamFileAction::VerifyAndConsume);
  assert(session.onComplete(manifest));
  assert(session.snapshot().state == MapStreamInstallState::Ready);
  assert(session.snapshot().step() == 2);
  assert(session.snapshot().totalSteps() == 3);
  assert(session.snapshot().progress() == 100);
  assert(readFile(session.inactiveRoot() + "/+0000+0000/0.fmb") == "a");
  assert(readFile(session.inactiveRoot() + "/+0000+0000/1.fmb") == "bc");
  assert(readFile(session.inactiveRoot() + "/+0000+0000/2.fmp") == "def");
  assert(readFile(session.inactiveRoot() + "/.manifest.json") == kManifest);
  assert(readFile(session.inactiveRoot() + "/.verified.sha256") ==
         manifest.manifestReceipt);
  assert(exists(session.inactiveRoot() + "/.ready"));
  assert(!exists(session.inactiveRoot() + "/.installing"));
  assert(exists(root + "/VECTMAP/.pending-stream-activation.json"));
  assert(!exists(root + "/VECTMAP/active-map.json"));
  assert(session.snapshot().json(true).size() < 512);
  MapStreamInstallSnapshot recoverable;
  assert(map_transfer::readRecoverableMapStreamInstall(root, recoverable) ==
         MapStreamRecoveryResult::Found);
  assert(recoverable.state == MapStreamInstallState::Ready);
  assert(recoverable.sessionId == "session-1");

  MapTransferInstaller installer(root);
  std::vector<map_transfer::ActivationProgress> activationProgress;
  const auto activated = installer.recoverPendingStreamActivation(
      [&](const map_transfer::ActivationProgress &progress) {
        activationProgress.push_back(progress);
      });
  if (!activated.ok)
    std::cerr << activated.code << ": " << activated.message << "\n";
  assert(activated.ok);
  assert(activated.code == "stream_installed");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.mapId == "multi");
  assert(selected.sessionId == "session-1");
  assert(selected.root == "/VECTMAP/.maps/session-1");
  assert(selected.manifestReceipt == manifest.manifestReceipt);
  assert(selected.signedManifestReceipt == manifest.signedManifestReceipt);
  assert(activationProgress.size() == 3);
  assert(activationProgress.front().step == 3);
  assert(activationProgress.front().totalSteps == 3);
  assert(activationProgress.back().completed == 3);
  assert(!exists(root + "/VECTMAP/.pending-stream-activation.json"));
  assert(!exists(session.inactiveRoot() + "/.stream-checkpoint"));
  assert(exists(session.inactiveRoot() + "/.ready"));

  MapStreamInstallSession duplicate(root, "session-1", {1, 10000});
  assert(duplicate.onManifest(manifest, kManifest));
  consumeFile(duplicate, manifest, 0, "a",
              MapStreamFileAction::ConsumeCheckpointed);
  consumeFile(duplicate, manifest, 1, "bc",
              MapStreamFileAction::ConsumeCheckpointed);
  consumeFile(duplicate, manifest, 2, "def",
              MapStreamFileAction::ConsumeCheckpointed);
  assert(duplicate.onComplete(manifest));
  assert(duplicate.snapshot().bytesWritten == 0);
  assert(duplicate.snapshot().bytesSkipped == 6);
  assert(installer.activateReadyStreamMap("session-1").ok);
}

void testResumeSkipsDurablePrefixWithoutRewriting() {
  const std::string root = tempRoot();
  uint64_t now = 100;
  const auto manifest = verified();
  {
    MapStreamInstallSession first(root, "resume", {1, 10000},
                                  [&now] { return now; });
    assert(first.onManifest(manifest, kManifest));
    consumeFile(first, manifest, 0, "a", MapStreamFileAction::VerifyAndConsume);
    assert(first.snapshot().durableFilePrefix == 1);
    first.onAbort(map_transfer::MapStreamParserError::Truncated);
    assert(first.snapshot().state == MapStreamInstallState::Paused);
    MapStreamInstallSnapshot recoverable;
    assert(map_transfer::readRecoverableMapStreamInstall(root, recoverable) ==
           MapStreamRecoveryResult::Found);
    assert(recoverable.state == MapStreamInstallState::Paused);
    assert(recoverable.durableFilePrefix == 1);
  }
  const std::string firstPath = root + "/VECTMAP/.maps/resume/+0000+0000/0.fmb";
  const std::string checkpointPath =
      root + "/VECTMAP/.maps/resume/.stream-checkpoint";
  assert(::rename(checkpointPath.c_str(), (checkpointPath + ".bak").c_str()) ==
         0);
  struct stat before;
  assert(::stat(firstPath.c_str(), &before) == 0);
  now += 20000;
  MapStreamInstallSession retry(root, "resume", {1, 10000},
                                [&now] { return now; });
  assert(retry.onManifest(manifest, kManifest));
  assert(retry.snapshot().durableFilePrefix == 1);
  consumeFile(retry, manifest, 0, "a",
              MapStreamFileAction::ConsumeCheckpointed);
  struct stat after;
  assert(::stat(firstPath.c_str(), &after) == 0);
  assert(before.st_ino == after.st_ino);
  consumeFile(retry, manifest, 1, "bc", MapStreamFileAction::VerifyAndConsume);
  consumeFile(retry, manifest, 2, "def", MapStreamFileAction::VerifyAndConsume);
  assert(retry.onComplete(manifest));
  assert(retry.snapshot().bytesSkipped == 1);
  assert(retry.snapshot().bytesWritten == 5);
  assert(retry.snapshot().completedPayloadBytes == 6);
}

void testMismatchedIdentityCannotReuseCheckpoint() {
  const std::string root = tempRoot();
  uint64_t now = 0;
  const auto firstManifest = verified(std::string(64, '2'));
  {
    MapStreamInstallSession first(root, "same-session", {1, 10000},
                                  [&now] { return now; });
    assert(first.onManifest(firstManifest, kManifest));
    consumeFile(first, firstManifest, 0, "a",
                MapStreamFileAction::VerifyAndConsume);
  }
  const auto secondManifest = verified(std::string(64, '3'));
  MapStreamInstallSession second(root, "same-session", {1, 10000},
                                 [&now] { return now; });
  assert(second.onManifest(secondManifest, kManifest));
  assert(second.snapshot().durableFilePrefix == 0);
  assert(!exists(second.inactiveRoot() + "/+0000+0000/0.fmb"));
  assert(exists(second.inactiveRoot() + "/.installing"));
}

void testCorruptCheckpointAndPartAreDiscarded() {
  const std::string root = tempRoot();
  const auto manifest = verified();
  MapStreamInstallSession first(root, "corrupt", {1, 10000});
  assert(first.onManifest(manifest, kManifest));
  consumeFile(first, manifest, 0, "a", MapStreamFileAction::VerifyAndConsume);
  writeFile(first.inactiveRoot() + "/.stream-checkpoint", "{bad}");
  writeFile(first.inactiveRoot() + "/orphan.part", "partial");
  MapStreamInstallSession retry(root, "corrupt", {1, 10000});
  assert(retry.onManifest(manifest, kManifest));
  assert(retry.snapshot().durableFilePrefix == 0);
  assert(!exists(retry.inactiveRoot() + "/orphan.part"));
  assert(!exists(retry.inactiveRoot() + "/+0000+0000/0.fmb"));
}

void testActiveRootConflictFailsClosed() {
  const std::string root = tempRoot();
  assert(::system(("mkdir -p " + root + "/VECTMAP").c_str()) == 0);
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"mapId\":\"multi\",\"root\":\"/VECTMAP/.maps/active\","
            "\"sessionId\":\"active\"}\n");
  const auto manifest = verified();
  MapStreamInstallSession session(root, "active");
  assert(!session.onManifest(manifest, kManifest));
  assert(session.snapshot().state == MapStreamInstallState::Failed);
  assert(session.snapshot().errorCode == "stream_session_conflict");
}

void testOutOfOrderConsumerCallbacksFailClosed() {
  const std::string root = tempRoot();
  const auto manifest = verified();
  MapStreamInstallSession session(root, "ordered");
  assert(session.onManifest(manifest, kManifest));
  const MapStreamFileView second = fileView(manifest, 1);
  assert(session.onFileBegin(second, 1) == MapStreamFileAction::Reject);
  assert(session.snapshot().state == MapStreamInstallState::Failed);
  assert(session.snapshot().errorCode == "stream_file_order");
}

void testRecoveryCompletesReadyPointerTransaction() {
  const std::string root = tempRoot();
  const auto manifest = prepareReadyRoot(root, "new-session");
  assert(::system(
             ("mkdir -p " + root + "/VECTMAP/.maps/old-session").c_str()) == 0);
  writeFile(root + "/VECTMAP/.maps/old-session/old.fmb", "old");
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"mapId\":\"old-map\",\"root\":\"/VECTMAP/.maps/old-session\","
            "\"sessionId\":\"old-session\"}\n");
  writeFile(root + "/VECTMAP/.activation-transaction.json",
            "{\"manifestReceipt\":\"" + manifest.manifestReceipt +
                "\",\"mapId\":\"multi\",\"phase\":\"ready\","
                "\"previousMapId\":\"old-map\","
                "\"previousRoot\":\"/VECTMAP/.maps/old-session\","
                "\"previousSessionId\":\"old-session\","
                "\"protocolVersion\":2,\"root\":\"/VECTMAP/.maps/new-session\","
                "\"sessionId\":\"new-session\","
                "\"signedManifestReceipt\":\"" +
                manifest.signedManifestReceipt + "\"}\n");
  MapTransferInstaller installer(root);
  const auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_commit");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.sessionId == "new-session");
  assert(selected.previousSessionId == "old-session");
  assert(selected.signedManifestReceipt == manifest.signedManifestReceipt);
  assert(readFile(root + "/VECTMAP/.maps/old-session/old.fmb") == "old");
  assert(!exists(root + "/VECTMAP/.activation-transaction.json"));
}

void testRecoveryRollsBackCorruptReadySelection() {
  const std::string root = tempRoot();
  const auto manifest = prepareReadyRoot(root, "broken-session");
  assert(::system(
             ("mkdir -p " + root + "/VECTMAP/.maps/old-session").c_str()) == 0);
  writeFile(root + "/VECTMAP/.maps/old-session/old.fmb", "old");
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"manifestReceipt\":\"" + manifest.manifestReceipt +
                "\",\"mapId\":\"multi\","
                "\"previousMapId\":\"old-map\","
                "\"previousRoot\":\"/VECTMAP/.maps/old-session\","
                "\"previousSessionId\":\"old-session\","
                "\"root\":\"/VECTMAP/.maps/broken-session\","
                "\"sessionId\":\"broken-session\","
                "\"signedManifestReceipt\":\"" +
                manifest.signedManifestReceipt + "\"}\n");
  writeFile(
      root + "/VECTMAP/.activation-transaction.json",
      "{\"manifestReceipt\":\"" + manifest.manifestReceipt +
          "\",\"mapId\":\"multi\",\"phase\":\"ready\","
          "\"previousMapId\":\"old-map\","
          "\"previousRoot\":\"/VECTMAP/.maps/old-session\","
          "\"previousSessionId\":\"old-session\","
          "\"protocolVersion\":2,\"root\":\"/VECTMAP/.maps/broken-session\","
          "\"sessionId\":\"broken-session\","
          "\"signedManifestReceipt\":\"" +
          manifest.signedManifestReceipt + "\"}\n");
  writeFile(root + "/VECTMAP/.maps/broken-session/.manifest.json", "corrupt");
  MapTransferInstaller installer(root);
  const auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.sessionId == "old-session");
  assert(readFile(root + "/VECTMAP/.maps/old-session/old.fmb") == "old");
  assert(!exists(root + "/VECTMAP/.maps/broken-session"));
}

void testBootReconstructsMissingPendingMarker() {
  const std::string root = tempRoot();
  const auto manifest = prepareReadyRoot(root, "ready-without-pending");
  assert(::unlink(
             (root + "/VECTMAP/.pending-stream-activation.json").c_str()) == 0);
  MapTransferInstaller installer(root);
  assert(installer.pruneObsoleteInstalledMaps());
  assert(exists(root + "/VECTMAP/.maps/ready-without-pending/.ready"));
  const auto recovered = installer.recoverPendingStreamActivation();
  assert(recovered.ok);
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.sessionId == "ready-without-pending");
  assert(selected.signedManifestReceipt == manifest.signedManifestReceipt);
}

void testBootDoesNotGuessBetweenMultipleReadyRoots() {
  const std::string root = tempRoot();
  prepareReadyRoot(root, "ready-one");
  prepareReadyRoot(root, "ready-two");
  assert(::unlink(
             (root + "/VECTMAP/.pending-stream-activation.json").c_str()) == 0);
  MapTransferInstaller installer(root);
  const auto recovered = installer.recoverPendingStreamActivation();
  assert(!recovered.ok);
  assert(recovered.code == "stream_ready_ambiguous");
  MapStreamInstallSnapshot recoverable;
  assert(map_transfer::readRecoverableMapStreamInstall(root, recoverable) ==
         MapStreamRecoveryResult::Ambiguous);
  ActiveMapSelection selected;
  assert(!installer.readActiveMap(selected).ok);
  assert(exists(root + "/VECTMAP/.maps/ready-one/.ready"));
  assert(exists(root + "/VECTMAP/.maps/ready-two/.ready"));
}

void testActivePointerWriteFailureRemainsRecoverable() {
  const std::string root = tempRoot();
  prepareReadyRoot(root, "recover-write");
  assert(::system(
             ("mkdir -p " + root + "/VECTMAP/.maps/old-session").c_str()) == 0);
  writeFile(root + "/VECTMAP/.maps/old-session/old.fmb", "old");
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"mapId\":\"old-map\",\"root\":\"/VECTMAP/.maps/old-session\","
            "\"sessionId\":\"old-session\"}\n");
  ActiveWriteFailingInstaller failing(root);
  const auto failed = failing.activateReadyStreamMap("recover-write");
  assert(!failed.ok);
  ActiveMapSelection oldSelection;
  assert(failing.readActiveMap(oldSelection).ok);
  assert(oldSelection.sessionId == "old-session");
  assert(exists(root + "/VECTMAP/.activation-transaction.json"));

  MapTransferInstaller recoveredInstaller(root);
  const auto recovered = recoveredInstaller.recoverInterruptedActivation();
  assert(recovered.ok);
  ActiveMapSelection selected;
  assert(recoveredInstaller.readActiveMap(selected).ok);
  assert(selected.sessionId == "recover-write");
  assert(selected.previousSessionId == "old-session");
}

void testReadyPayloadDamageCannotBeSkippedOrActivated() {
  const std::string root = tempRoot();
  const auto manifest = prepareReadyRoot(root, "damaged-ready");
  const std::string damaged =
      root + "/VECTMAP/.maps/damaged-ready/+0000+0000/1.fmb";
  assert(::unlink(damaged.c_str()) == 0);
  MapStreamInstallSession retry(root, "damaged-ready", {1, 10000});
  assert(retry.onManifest(manifest, kManifest));
  assert(retry.snapshot().durableFilePrefix == 0);
  assert(consumeAll(retry, manifest));
  assert(retry.onComplete(manifest));
  assert(retry.snapshot().bytesWritten == 6);
  MapTransferInstaller installer(root);
  assert(installer.activateReadyStreamMap("damaged-ready").ok);
}

void testSemanticBackupRecovery() {
  const std::string root = tempRoot();
  const auto manifest = verified();
  {
    MapStreamInstallSession first(root, "backup-checkpoint", {1, 10000});
    assert(first.onManifest(manifest, kManifest));
    consumeFile(first, manifest, 0, "a", MapStreamFileAction::VerifyAndConsume);
  }
  const std::string checkpoint =
      root + "/VECTMAP/.maps/backup-checkpoint/.stream-checkpoint";
  writeFile(checkpoint + ".bak", readFile(checkpoint));
  writeFile(checkpoint, "{bad}");
  MapStreamInstallSnapshot recoverable;
  assert(map_transfer::readRecoverableMapStreamInstall(root, recoverable) ==
         MapStreamRecoveryResult::Found);
  assert(recoverable.durableFilePrefix == 1);
  MapStreamInstallSession resumed(root, "backup-checkpoint", {1, 10000});
  assert(resumed.onManifest(manifest, kManifest));
  assert(resumed.snapshot().durableFilePrefix == 1);

  prepareReadyRoot(root, "backup-ready");
  const std::string ready = root + "/VECTMAP/.maps/backup-ready/.ready";
  writeFile(ready + ".bak", readFile(ready));
  writeFile(ready, "{bad}");
  assert(map_transfer::readRecoverableMapStreamInstall(root, recoverable) ==
         MapStreamRecoveryResult::Ambiguous);
  MapTransferInstaller installer(root);
  assert(installer.activateReadyStreamMap("backup-ready").ok);
}

void testPreviousRootIdentityIsProtected() {
  const std::string root = tempRoot();
  const auto original = prepareReadyRoot(root, "previous-a");
  MapTransferInstaller installer(root);
  assert(installer.activateReadyStreamMap("previous-a").ok);
  prepareReadyRoot(root, "current-b");
  assert(installer.activateReadyStreamMap("current-b").ok);
  const std::string previousFile =
      root + "/VECTMAP/.maps/previous-a/+0000+0000/0.fmb";
  assert(readFile(previousFile) == "a");

  const auto replacement = verified(std::string(64, '9'));
  MapStreamInstallSession conflicting(root, "previous-a", {1, 10000});
  assert(!conflicting.onManifest(replacement, kManifest));
  assert(conflicting.snapshot().errorCode == "stream_session_conflict");
  assert(readFile(previousFile) == "a");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.previousSignedManifestReceipt ==
         original.signedManifestReceipt);
}

void testRollbackRejectsMismatchedPreviousIdentity() {
  const std::string root = tempRoot();
  const auto previous = prepareReadyRoot(root, "rollback-a");
  MapTransferInstaller installer(root);
  assert(installer.activateReadyStreamMap("rollback-a").ok);
  const auto broken = prepareReadyRoot(root, "rollback-b");
  const std::string wrongReceipt(64, 'f');
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"manifestReceipt\":\"" + broken.manifestReceipt +
                "\",\"mapId\":\"multi\",\"previousManifestReceipt\":\"" +
                wrongReceipt +
                "\",\"previousMapId\":\"multi\","
                "\"previousRoot\":\"/VECTMAP/.maps/rollback-a\","
                "\"previousSessionId\":\"rollback-a\","
                "\"previousSignedManifestReceipt\":\"" + wrongReceipt +
                "\",\"root\":\"/VECTMAP/.maps/rollback-b\","
                "\"sessionId\":\"rollback-b\","
                "\"signedManifestReceipt\":\"" +
                broken.signedManifestReceipt + "\"}\n");
  writeFile(root + "/VECTMAP/.activation-transaction.json",
            "{\"manifestReceipt\":\"" + broken.manifestReceipt +
                "\",\"mapId\":\"multi\",\"phase\":\"ready\","
                "\"previousManifestReceipt\":\"" + wrongReceipt +
                "\",\"previousMapId\":\"multi\","
                "\"previousRoot\":\"/VECTMAP/.maps/rollback-a\","
                "\"previousSessionId\":\"rollback-a\","
                "\"previousSignedManifestReceipt\":\"" + wrongReceipt +
                "\",\"protocolVersion\":2,"
                "\"root\":\"/VECTMAP/.maps/rollback-b\","
                "\"sessionId\":\"rollback-b\","
                "\"signedManifestReceipt\":\"" +
                broken.signedManifestReceipt + "\"}\n");
  writeFile(root + "/VECTMAP/.maps/rollback-b/.manifest.json", "corrupt");
  const auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  ActiveMapSelection selected;
  assert(!installer.readActiveMap(selected).ok);
  assert(exists(root + "/VECTMAP/.maps/rollback-a/+0000+0000/0.fmb"));
  assert(previous.signedManifestReceipt != wrongReceipt);
}

void testConsumedReadyRootsAreNotReactivatedAndArePruned() {
  const std::string root = tempRoot();
  MapTransferInstaller installer(root);
  for (const char *session : {"history-a", "history-b", "history-c"}) {
    prepareReadyRoot(root, session);
    assert(installer.activateReadyStreamMap(session).ok);
    assert(
        exists(root + "/VECTMAP/.maps/" + session + "/.activation-consumed"));
  }
  const auto recovered = installer.recoverPendingStreamActivation();
  assert(recovered.ok);
  assert(recovered.code == "stream_pending_none");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.sessionId == "history-c");
  assert(selected.previousSessionId == "history-b");
  assert(installer.pruneObsoleteInstalledMaps());
  assert(!exists(root + "/VECTMAP/.maps/history-a"));
  assert(exists(root + "/VECTMAP/.maps/history-b"));
  assert(exists(root + "/VECTMAP/.maps/history-c"));
}

void testFrozenMapIdEdgesInstallAndActivate() {
  const std::string root = tempRoot();
  const std::string manifestText =
      "{\"files\":[{\"bytes\":1,\"path\":\"VECTMAP/.shanghai/"
      "+0000+0000/0.fmb\",\"sha256\":\""
      "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"
      "\"}],\"mapId\":\".shanghai\",\"schemaVersion\":1,\"target\":{"
      "\"formatVersion\":1,\"minFirmwareVersion\":\"0.0.0\","
      "\"renderer\":\"esp32-fmb\"}}";
  VerifiedMapStreamManifest manifest;
  MapStreamHeader header;
  header.fileCount = 1;
  header.payloadBytes = 1;
  assert(map_transfer::parseMapStreamManifest(manifestText, header,
                                              manifest.manifest));
  manifest.manifestReceipt = map_transfer::mapStreamManifestReceipt(
      reinterpret_cast<const uint8_t *>(manifestText.data()),
      manifestText.size());
  manifest.signedManifestReceipt = std::string(64, '7');
  manifest.payloadBytes = 1;
  MapStreamInstallSession session(root, "edge-map-id", {1, 10000});
  assert(session.onManifest(manifest, manifestText));
  MapStreamFileView file;
  assert(map_transfer::mapStreamFileView(manifest.manifest, manifestText, 0,
                                         file));
  assert(session.onFileBegin(file, 0) == MapStreamFileAction::VerifyAndConsume);
  const uint8_t payload = 'a';
  assert(session.onFileData(file, &payload, 1));
  assert(session.onFileEnd(file, 0));
  assert(session.onComplete(manifest));
  MapTransferInstaller installer(root);
  assert(installer.activateReadyStreamMap("edge-map-id").ok);
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.mapId == ".shanghai");
}

void testCrashBoundariesRemainRetryableWithMonotonicFinalization() {
  const auto manifest = verified();
  struct FinalizationFault {
    FaultOperation operation;
    const char *path;
    uint8_t completed;
  };
  const std::array<FinalizationFault, 11> faults = {{
      {FaultOperation::Rename, ".stream-checkpoint", 0},
      {FaultOperation::SyncDirectory, ".stream-checkpoint", 0},
      {FaultOperation::Rename, ".manifest.json", 1},
      {FaultOperation::SyncDirectory, ".manifest.json", 1},
      {FaultOperation::Rename, ".verified.sha256", 2},
      {FaultOperation::SyncDirectory, ".verified.sha256", 2},
      {FaultOperation::Rename, ".ready", 3},
      {FaultOperation::SyncDirectory, ".ready", 3},
      {FaultOperation::Rename, ".pending-stream-activation.json", 4},
      {FaultOperation::SyncDirectory, ".pending-stream-activation.json", 4},
      {FaultOperation::Remove, ".installing", 5},
  }};
  for (size_t index = 0; index < faults.size(); index++) {
    const std::string root = tempRoot();
    assert(::system(("mkdir -p " + root + "/VECTMAP").c_str()) == 0);
    writeFile(root + "/VECTMAP/active-map.json",
              "{\"mapId\":\"old\",\"root\":\"/VECTMAP\"}\n");
    auto storage = std::make_shared<FaultInjectingStorage>(
        faults[index].operation, faults[index].path);
    MapStreamInstallSession failing(root, "finalize-" + std::to_string(index),
                                    {UINT64_MAX, UINT64_MAX}, {}, storage);
    assert(failing.onManifest(manifest, kManifest));
    assert(consumeAll(failing, manifest));
    assert(!failing.onComplete(manifest));
    assert(storage->fired());
    assert(failing.snapshot().state == MapStreamInstallState::Failed);
    assert(failing.snapshot().step() == 2);
    assert(failing.snapshot().finalizationCompleted == faults[index].completed);
    assert(failing.snapshot().progress() ==
           static_cast<uint8_t>((faults[index].completed * 100U) / 6U));
    assert(readFile(root + "/VECTMAP/active-map.json").find("old") !=
           std::string::npos);

    MapStreamInstallSession retry(root, "finalize-" + std::to_string(index),
                                  {1, 10000});
    assert(retry.onManifest(manifest, kManifest));
    assert(consumeAll(retry, manifest));
    assert(retry.onComplete(manifest));
    assert(retry.snapshot().progress() == 100);
  }

  for (const FaultOperation operation :
       {FaultOperation::Write, FaultOperation::SyncFile,
        FaultOperation::CloseFile, FaultOperation::Rename,
        FaultOperation::SyncDirectory}) {
    const std::string root = tempRoot();
    auto storage = std::make_shared<FaultInjectingStorage>(
        operation,
        operation == FaultOperation::Rename ||
                operation == FaultOperation::SyncDirectory
            ? "0.fmb"
            : ".part");
    MapStreamInstallSession failing(root, "file-boundary", {1, 10000}, {},
                                    storage);
    assert(failing.onManifest(manifest, kManifest));
    const MapStreamFileView file = fileView(manifest, 0);
    assert(failing.onFileBegin(file, 0) ==
           MapStreamFileAction::VerifyAndConsume);
    const uint8_t payload = 'a';
    const bool wrote = failing.onFileData(file, &payload, 1);
    if (operation == FaultOperation::Write) {
      assert(!wrote);
    } else {
      assert(wrote);
      assert(!failing.onFileEnd(file, 0));
    }
    assert(storage->fired());
    assert(failing.snapshot().state == MapStreamInstallState::Failed);
    assert(failing.snapshot().step() == 1);
  }
}

void testLargeDirectoryCleanupStreamsEntries() {
  const std::string root = tempRoot();
  const auto manifest = verified();
  MapStreamInstallSession session(root, "large-directory",
                                  {UINT64_MAX, UINT64_MAX});
  assert(session.onManifest(manifest, kManifest));
  assert(consumeAll(session, manifest));
  const std::string tile = session.inactiveRoot() + "/+0000+0000";
  for (size_t index = 0; index < 1024; index++) {
    const std::string suffix = index % 64 == 0 ? ".part" : ".aux";
    writeFile(tile + "/resource-" + std::to_string(index) + suffix, "x");
  }
  assert(session.onComplete(manifest));
  for (size_t index = 0; index < 1024; index += 64) {
    assert(!exists(tile + "/resource-" + std::to_string(index) + ".part"));
  }
  assert(exists(tile + "/resource-1.aux"));
}

} // namespace

int main() {
  testDirectWriteCheckpointAndReady();
  testResumeSkipsDurablePrefixWithoutRewriting();
  testMismatchedIdentityCannotReuseCheckpoint();
  testCorruptCheckpointAndPartAreDiscarded();
  testActiveRootConflictFailsClosed();
  testOutOfOrderConsumerCallbacksFailClosed();
  testRecoveryCompletesReadyPointerTransaction();
  testRecoveryRollsBackCorruptReadySelection();
  testBootReconstructsMissingPendingMarker();
  testBootDoesNotGuessBetweenMultipleReadyRoots();
  testActivePointerWriteFailureRemainsRecoverable();
  testReadyPayloadDamageCannotBeSkippedOrActivated();
  testSemanticBackupRecovery();
  testPreviousRootIdentityIsProtected();
  testRollbackRejectsMismatchedPreviousIdentity();
  testConsumedReadyRootsAreNotReactivatedAndArePruned();
  testFrozenMapIdEdgesInstallAndActivate();
  testCrashBoundariesRemainRetryableWithMonotonicFinalization();
  testLargeDirectoryCleanupStreamsEntries();
  std::cout << "map_stream_install tests passed\n";
  return 0;
}
