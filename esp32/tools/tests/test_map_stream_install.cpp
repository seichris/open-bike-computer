#include "../../lib/map_transfer/map_stream_format.hpp"
#include "../../lib/map_transfer/map_stream_install.hpp"
#include "../../lib/map_transfer/map_stream_receiver.hpp"
#include "../../lib/map_transfer/map_transfer.hpp"

#include <array>
#include <cassert>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
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
using map_transfer::MapStreamReceiver;
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

std::map<std::string, std::string> readGoldenFixture() {
  std::ifstream input("../map-platform/backend/tests/fixtures/map_stream_v1_golden.txt");
  assert(input.good());
  std::map<std::string, std::string> values;
  std::string line;
  while (std::getline(input, line)) {
    const size_t separator = line.find('=');
    assert(separator != std::string::npos);
    values[line.substr(0, separator)] = line.substr(separator + 1);
  }
  return values;
}

std::vector<uint8_t> decodeHex(const std::string &hex) {
  assert(hex.size() % 2 == 0);
  std::vector<uint8_t> bytes;
  bytes.reserve(hex.size() / 2);
  for (size_t index = 0; index < hex.size(); index += 2) {
    bytes.push_back(
        static_cast<uint8_t>(std::stoul(hex.substr(index, 2), nullptr, 16)));
  }
  return bytes;
}

void writeFile(const std::string &path, const std::string &value) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  assert(output.good());
  output << value;
  output.close();
  assert(output.good());
}

const std::string kPayload0("FMB\x01\0\0\0\0", 8);
const std::string kPayload1("FMB\x02\0\0\0\0", 8);
const std::string kPayload2 = "Polygons:0\nPolylines:0\n";
const std::array<std::string, 3> kPayloads = {kPayload0, kPayload1,
                                             kPayload2};
constexpr uint64_t kPayloadBytes = 39;

const std::string kManifest =
    "{\"files\":[{\"bytes\":8,\"path\":\"VECTMAP/multi/+0000+0000/0.fmb\","
    "\"sha256\":"
    "\"8b359fbdc6bda4e7f061783a8ed844e7733d6573881cf302b7d2833981848f7b\"},"
    "{\"bytes\":8,\"path\":\"VECTMAP/multi/+0000+0000/1.fmb\","
    "\"sha256\":"
    "\"08f7a315f83149b4d977fcdada8b882ae60d0b5b9ef1fafa05e0f5431154f387\"},"
    "{\"bytes\":23,\"path\":\"VECTMAP/multi/+0000+0000/2.fmp\","
    "\"sha256\":"
    "\"a993c29312adc226b606450ebe82b5108a2302e80c8753648208c2f09231c364\"}],"
    "\"mapId\":\"multi\",\"schemaVersion\":1,\"target\":{\"formatVersion\":1,"
    "\"minFirmwareVersion\":\"0.0.0\",\"renderer\":\"esp32-fmb\"}}";

VerifiedMapStreamManifest
verified(const std::string &signedReceipt = std::string(64, '2')) {
  VerifiedMapStreamManifest value;
  MapStreamHeader header;
  header.fileCount = 3;
  header.payloadBytes = kPayloadBytes;
  assert(
      map_transfer::parseMapStreamManifest(kManifest, header, value.manifest));
  value.manifestReceipt = map_transfer::mapStreamManifestReceipt(
      reinterpret_cast<const uint8_t *>(kManifest.data()), kManifest.size());
  value.signedManifestReceipt = signedReceipt;
  value.signatureKeyId = "test-key";
  value.payloadBytes = kPayloadBytes;
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
  for (size_t index = 0; index < kPayloads.size(); index++) {
    const MapStreamFileView file = fileView(manifest, index);
    const MapStreamFileAction action = session.onFileBegin(file, index);
    if (action == MapStreamFileAction::Reject ||
        !session.onFileData(
            file, reinterpret_cast<const uint8_t *>(kPayloads[index].data()),
            kPayloads[index].size()) ||
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
  consumeFile(session, manifest, 0, kPayload0,
              MapStreamFileAction::VerifyAndConsume);
  consumeFile(session, manifest, 1, kPayload1,
              MapStreamFileAction::VerifyAndConsume);
  consumeFile(session, manifest, 2, kPayload2,
              MapStreamFileAction::VerifyAndConsume);
  assert(session.onComplete(manifest));
  return manifest;
}

void testDirectWriteCheckpointAndReady() {
  const std::string root = tempRoot();
  uint64_t now = 100;
  const auto manifest = verified();
  MapStreamInstallSession session(root, "session-1", {9, 10000},
                                  [&now] { return now; });
  assert(session.onManifest(manifest, kManifest));
  assert(session.snapshot().state == MapStreamInstallState::Receiving);
  assert(!exists(root + "/VECTMAP/active-map.json"));
  consumeFile(session, manifest, 0, kPayload0,
              MapStreamFileAction::VerifyAndConsume);
  assert(!exists(session.inactiveRoot() + "/.stream-checkpoint"));
  consumeFile(session, manifest, 1, kPayload1,
              MapStreamFileAction::VerifyAndConsume);
  assert(exists(session.inactiveRoot() + "/.stream-checkpoint"));
  assert(session.snapshot().durableFilePrefix == 2);
  now += 10001;
  consumeFile(session, manifest, 2, kPayload2,
              MapStreamFileAction::VerifyAndConsume);
  assert(session.onComplete(manifest));
  assert(session.snapshot().state == MapStreamInstallState::Ready);
  assert(session.snapshot().step() == 2);
  assert(session.snapshot().totalSteps() == 3);
  assert(session.snapshot().progress() == 100);
  assert(readFile(session.inactiveRoot() + "/+0000+0000/0.fmb") ==
         kPayload0);
  assert(readFile(session.inactiveRoot() + "/+0000+0000/1.fmb") ==
         kPayload1);
  assert(readFile(session.inactiveRoot() + "/+0000+0000/2.fmp") ==
         kPayload2);
  assert(readFile(session.inactiveRoot() + "/.manifest.json") == kManifest);
  assert(readFile(session.inactiveRoot() + "/.verified.sha256") ==
         manifest.manifestReceipt);
  assert(exists(session.inactiveRoot() + "/.ready"));
  assert(!exists(session.inactiveRoot() + "/.installing"));
  assert(exists(root + "/VECTMAP/.pending-stream-activation.json"));
  assert(!exists(root + "/VECTMAP/active-map.json"));
  assert(session.snapshot().json(true).size() < 512);
  assert(session.snapshot().json(true).find("\"status\":\"ready\"") !=
         std::string::npos);
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
  assert(selected.target.renderer == "esp32-fmb");
  assert(selected.target.formatVersion == 1);
  assert(selected.manifestReceipt == manifest.manifestReceipt);
  assert(selected.signedManifestReceipt == manifest.signedManifestReceipt);
  ActiveMapSelection identified;
  std::string contentReceipt;
  assert(installer.readActiveMapContentReceipt(identified, contentReceipt).ok);
  assert(identified.mapId == selected.mapId);
  assert(contentReceipt == selected.manifestReceipt);
  assert(activationProgress.size() == 3);
  assert(activationProgress.front().step == 3);
  assert(activationProgress.front().totalSteps == 3);
  assert(activationProgress.back().completed == 3);
  assert(!exists(root + "/VECTMAP/.pending-stream-activation.json"));
  assert(!exists(session.inactiveRoot() + "/.stream-checkpoint"));
  assert(exists(session.inactiveRoot() + "/.ready"));

  MapStreamInstallSession duplicate(root, "session-1", {1, 10000});
  assert(duplicate.onManifest(manifest, kManifest));
  consumeFile(duplicate, manifest, 0, kPayload0,
              MapStreamFileAction::ConsumeCheckpointed);
  consumeFile(duplicate, manifest, 1, kPayload1,
              MapStreamFileAction::ConsumeCheckpointed);
  consumeFile(duplicate, manifest, 2, kPayload2,
              MapStreamFileAction::ConsumeCheckpointed);
  assert(duplicate.onComplete(manifest));
  assert(duplicate.snapshot().bytesWritten == 0);
  assert(duplicate.snapshot().bytesSkipped == kPayloadBytes);
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
    consumeFile(first, manifest, 0, kPayload0,
                MapStreamFileAction::VerifyAndConsume);
    assert(first.snapshot().durableFilePrefix == 1);
    first.onAbort(map_transfer::MapStreamParserError::Truncated);
    assert(first.snapshot().state == MapStreamInstallState::Paused);
    MapStreamInstallSnapshot recoverable;
    assert(map_transfer::readRecoverableMapStreamInstall(root, recoverable) ==
           MapStreamRecoveryResult::Found);
    assert(recoverable.state == MapStreamInstallState::Paused);
    assert(recoverable.durableFilePrefix == 1);
    assert(recoverable.receivedPayloadBytes == 0);
    assert(recoverable.completedPayloadBytes == kPayload0.size());
    assert(recoverable.progress() == 20);
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
  consumeFile(retry, manifest, 0, kPayload0,
              MapStreamFileAction::ConsumeCheckpointed);
  struct stat after;
  assert(::stat(firstPath.c_str(), &after) == 0);
  assert(before.st_ino == after.st_ino);
  consumeFile(retry, manifest, 1, kPayload1,
              MapStreamFileAction::VerifyAndConsume);
  consumeFile(retry, manifest, 2, kPayload2,
              MapStreamFileAction::VerifyAndConsume);
  assert(retry.onComplete(manifest));
  assert(retry.snapshot().bytesSkipped == kPayload0.size());
  assert(retry.snapshot().bytesWritten == kPayloadBytes - kPayload0.size());
  assert(retry.snapshot().completedPayloadBytes == kPayloadBytes);
}

void testIncompleteStreamCanBeDiscardedForProtocolArbitration() {
  const std::string root = tempRoot();
  const auto manifest = verified();
  MapStreamInstallSession session(root, "cross-protocol", {1, 10000});
  assert(session.onManifest(manifest, kManifest));
  consumeFile(session, manifest, 0, kPayload0,
              MapStreamFileAction::VerifyAndConsume);
  session.onAbort(map_transfer::MapStreamParserError::Truncated);
  assert(session.snapshot().state == MapStreamInstallState::Paused);

  MapTransferInstaller installer(root);
  const auto discarded =
      installer.discardIncompleteStreamMap("cross-protocol");
  assert(discarded.ok);
  assert(!exists(root + "/VECTMAP/.maps/cross-protocol"));
}

void testUnselectedReadyStreamCanBeSupersededByArchive() {
  const std::string root = tempRoot();
  prepareReadyRoot(root, "stream-fallback");
  assert(exists(root +
                "/VECTMAP/.maps/stream-fallback/.ready"));
  assert(exists(root + "/VECTMAP/.pending-stream-activation.json"));

  MapTransferInstaller installer(root);
  const auto discarded =
      installer.discardUnselectedStreamMap("stream-fallback");
  assert(discarded.ok);
  assert(discarded.code == "stream_superseded");
  assert(!exists(root + "/VECTMAP/.maps/stream-fallback"));
  assert(!exists(root + "/VECTMAP/.pending-stream-activation.json"));
}

void testInvalidUnselectedStreamCanBeSupersededWithoutRemovingActiveMap() {
  const std::string root = tempRoot();
  prepareReadyRoot(root, "active-stream");
  MapTransferInstaller installer(root);
  assert(installer.activateReadyStreamMap("active-stream").ok);

  prepareReadyRoot(root, "invalid-stream");
  const std::string ready =
      root + "/VECTMAP/.maps/invalid-stream/.ready";
  std::string marker = readFile(ready);
  const std::string validation = ",\"validationVersion\":1";
  const size_t validationOffset = marker.find(validation);
  assert(validationOffset != std::string::npos);
  marker.erase(validationOffset, validation.size());
  writeFile(ready, marker);
  MapStreamInstallSnapshot recoverable;
  assert(map_transfer::readRecoverableMapStreamInstall(root, recoverable) ==
         MapStreamRecoveryResult::Invalid);

  const auto discarded = installer.discardAllUnselectedStreamMaps();
  assert(discarded.ok);
  assert(!exists(root + "/VECTMAP/.maps/invalid-stream"));
  assert(!exists(root + "/VECTMAP/.pending-stream-activation.json"));
  assert(exists(root + "/VECTMAP/.maps/active-stream"));
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.sessionId == "active-stream");
}

void testMismatchedIdentityCannotReuseCheckpoint() {
  const std::string root = tempRoot();
  uint64_t now = 0;
  const auto firstManifest = verified(std::string(64, '2'));
  {
    MapStreamInstallSession first(root, "same-session", {1, 10000},
                                  [&now] { return now; });
    assert(first.onManifest(firstManifest, kManifest));
    consumeFile(first, firstManifest, 0, kPayload0,
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
  consumeFile(first, manifest, 0, kPayload0,
              MapStreamFileAction::VerifyAndConsume);
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
  assert(selected.target.renderer == "esp32-fmb");
  assert(selected.target.formatVersion == 1);
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

void testReadyMarkerRequiresStructuralValidationVersion() {
  const std::string root = tempRoot();
  prepareReadyRoot(root, "old-ready-schema");
  const std::string ready =
      root + "/VECTMAP/.maps/old-ready-schema/.ready";
  std::string marker = readFile(ready);
  const std::string field = ",\"validationVersion\":1";
  const size_t fieldOffset = marker.find(field);
  assert(fieldOffset != std::string::npos);
  marker.erase(fieldOffset, field.size());
  writeFile(ready, marker);

  MapStreamInstallSnapshot recoverable;
  assert(map_transfer::readRecoverableMapStreamInstall(root, recoverable) ==
         MapStreamRecoveryResult::Invalid);
  MapTransferInstaller installer(root);
  const auto activation = installer.recoverPendingStreamActivation();
  assert(!activation.ok);
  assert(activation.code == "stream_ready_invalid");
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
  assert(retry.snapshot().bytesWritten == kPayloadBytes);
  MapTransferInstaller installer(root);
  assert(installer.activateReadyStreamMap("damaged-ready").ok);
}

void testSemanticBackupRecovery() {
  const std::string root = tempRoot();
  const auto manifest = verified();
  {
    MapStreamInstallSession first(root, "backup-checkpoint", {1, 10000});
    assert(first.onManifest(manifest, kManifest));
    consumeFile(first, manifest, 0, kPayload0,
                MapStreamFileAction::VerifyAndConsume);
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
  assert(readFile(previousFile) == kPayload0);

  const auto replacement = verified(std::string(64, '9'));
  MapStreamInstallSession conflicting(root, "previous-a", {1, 10000});
  assert(!conflicting.onManifest(replacement, kManifest));
  assert(conflicting.snapshot().errorCode == "stream_session_conflict");
  assert(readFile(previousFile) == kPayload0);
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
      "{\"files\":[{\"bytes\":8,\"path\":\"VECTMAP/.shanghai/"
      "+0000+0000/0.fmb\",\"sha256\":\""
      "8b359fbdc6bda4e7f061783a8ed844e7733d6573881cf302b7d2833981848f7b"
      "\"}],\"mapId\":\".shanghai\",\"schemaVersion\":1,\"target\":{"
      "\"formatVersion\":1,\"minFirmwareVersion\":\"0.0.0\","
      "\"renderer\":\"esp32-fmb\"}}";
  VerifiedMapStreamManifest manifest;
  MapStreamHeader header;
  header.fileCount = 1;
  header.payloadBytes = kPayload0.size();
  assert(map_transfer::parseMapStreamManifest(manifestText, header,
                                              manifest.manifest));
  manifest.manifestReceipt = map_transfer::mapStreamManifestReceipt(
      reinterpret_cast<const uint8_t *>(manifestText.data()),
      manifestText.size());
  manifest.signedManifestReceipt = std::string(64, '7');
  manifest.payloadBytes = kPayload0.size();
  MapStreamInstallSession session(root, "edge-map-id", {1, 10000});
  assert(session.onManifest(manifest, manifestText));
  MapStreamFileView file;
  assert(map_transfer::mapStreamFileView(manifest.manifest, manifestText, 0,
                                         file));
  assert(session.onFileBegin(file, 0) == MapStreamFileAction::VerifyAndConsume);
  assert(session.onFileData(
      file, reinterpret_cast<const uint8_t *>(kPayload0.data()),
      kPayload0.size()));
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
    const bool wrote = failing.onFileData(
        file, reinterpret_cast<const uint8_t *>(kPayload0.data()),
        kPayload0.size());
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

void testTransportIndependentReceiverOwnsExactBodyLifecycle() {
  const auto fixture = readGoldenFixture();
  const std::vector<uint8_t> stream = decodeHex(fixture.at("stream_hex"));
  const std::vector<uint8_t> publicKey =
      decodeHex(fixture.at("public_key_x963_hex"));
  map_transfer::MapStreamTrustStore trust;
  assert(trust.add("map-test-2026-01", publicKey.data(), publicKey.size()));

  const std::string root = tempRoot();
  std::vector<MapStreamInstallSnapshot> progressSnapshots;
  MapStreamReceiver receiver(trust, root, "http-golden", stream.size(),
                             "9.0.0", 1024 * 1024, {}, {}, {},
                             [&](const MapStreamInstallSnapshot &snapshot) {
                               progressSnapshots.push_back(snapshot);
                             });
  for (size_t index = 0; index < stream.size(); index++)
    assert(receiver.feed(&stream[index], 1));
  const auto result = receiver.finish();
  assert(result.ok);
  assert(result.code == "stream_ready");
  assert(receiver.snapshot().state == MapStreamInstallState::Ready);
  assert(readFile(root +
                  "/VECTMAP/.maps/http-golden/+0000+0000/0_0.fmb") ==
         std::string("FMB\x01\0\0\0\0", 8));
  assert(exists(root + "/VECTMAP/.pending-stream-activation.json"));
  uint8_t previousFinalization = 0;
  bool sawFinalizing = false;
  for (const MapStreamInstallSnapshot &snapshot : progressSnapshots) {
    if (snapshot.step() != 2)
      continue;
    sawFinalizing = true;
    assert(snapshot.finalizationCompleted >= previousFinalization);
    previousFinalization = snapshot.finalizationCompleted;
  }
  assert(sawFinalizing);
  assert(previousFinalization == 6);

  MapStreamReceiver truncated(trust, root, "http-truncated", stream.size(),
                              "9.0.0", 1024 * 1024);
  assert(truncated.feed(stream.data(), stream.size() - 1));
  const auto paused = truncated.finish();
  assert(!paused.ok);
  assert(paused.httpStatus == 408);
  assert(truncated.snapshot().state == MapStreamInstallState::Paused);

  map_transfer::MapStreamTrustStore emptyTrust;
  MapStreamReceiver untrusted(emptyTrust, root, "http-untrusted",
                              stream.size(), "9.0.0", 1024 * 1024);
  assert(!untrusted.feed(stream.data(), stream.size()));
  const auto rejected = untrusted.finish();
  assert(!rejected.ok);
  assert(rejected.httpStatus == 400);
  assert(rejected.code == "stream_signing_key_unknown");
}

void testStartingNewStreamPrunesAbandonedPausedSessions() {
  const std::string root = tempRoot();
  const auto manifest = verified();
  {
    MapStreamInstallSession abandoned(root, "abandoned-stream", {1, 10000});
    assert(abandoned.onManifest(manifest, kManifest));
    consumeFile(abandoned, manifest, 0, kPayload0,
                MapStreamFileAction::VerifyAndConsume);
    abandoned.onAbort(map_transfer::MapStreamParserError::Truncated);
  }
  assert(exists(root + "/VECTMAP/.maps/abandoned-stream/.installing"));
  MapTransferInstaller installer(root);
  assert(installer.pruneObsoleteInstalledMaps("new-stream"));
  assert(!exists(root + "/VECTMAP/.maps/abandoned-stream"));
}

} // namespace

int main() {
  testDirectWriteCheckpointAndReady();
  testResumeSkipsDurablePrefixWithoutRewriting();
  testIncompleteStreamCanBeDiscardedForProtocolArbitration();
  testUnselectedReadyStreamCanBeSupersededByArchive();
  testInvalidUnselectedStreamCanBeSupersededWithoutRemovingActiveMap();
  testMismatchedIdentityCannotReuseCheckpoint();
  testCorruptCheckpointAndPartAreDiscarded();
  testActiveRootConflictFailsClosed();
  testOutOfOrderConsumerCallbacksFailClosed();
  testRecoveryCompletesReadyPointerTransaction();
  testRecoveryRollsBackCorruptReadySelection();
  testBootReconstructsMissingPendingMarker();
  testBootDoesNotGuessBetweenMultipleReadyRoots();
  testReadyMarkerRequiresStructuralValidationVersion();
  testActivePointerWriteFailureRemainsRecoverable();
  testReadyPayloadDamageCannotBeSkippedOrActivated();
  testSemanticBackupRecovery();
  testPreviousRootIdentityIsProtected();
  testRollbackRejectsMismatchedPreviousIdentity();
  testConsumedReadyRootsAreNotReactivatedAndArePruned();
  testFrozenMapIdEdgesInstallAndActivate();
  testCrashBoundariesRemainRetryableWithMonotonicFinalization();
  testLargeDirectoryCleanupStreamsEntries();
  testTransportIndependentReceiverOwnsExactBodyLifecycle();
  testStartingNewStreamPrunesAbandonedPausedSessions();
  std::cout << "map_stream_install tests passed\n";
  return 0;
}
