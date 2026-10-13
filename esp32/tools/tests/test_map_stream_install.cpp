#include "../../lib/map_transfer/map_stream_format.hpp"
#include "../../lib/map_transfer/map_stream_install.hpp"
#include "../../lib/map_transfer/map_stream_receiver.hpp"
#include "../../lib/device_transfer/commit_boundary_policy.hpp"
#include "../../lib/map_transfer/map_transfer.hpp"
#include "../../lib/map_transfer/map_operation_journal.hpp"

#include <array>
#include <cassert>
#include <cstdlib>
#include <fstream>
#include <filesystem>
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
  int openRead(const std::string &path) override {
    return delegate_->openRead(path);
  }
  bool read(int descriptor, uint8_t *data, size_t size) override {
    return delegate_->read(descriptor, data, size);
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

class ActiveWriteCorruptingInstaller final : public MapTransferInstaller {
public:
  using MapTransferInstaller::MapTransferInstaller;

protected:
  bool writeTextFileAtomic(const std::string &path,
                           const std::string &text) const override {
    if (!MapTransferInstaller::writeTextFileAtomic(path, text))
      return false;
    if (!corrupted_ && path.size() >= 24 &&
        path.compare(path.size() - 24, 24, "/VECTMAP/active-map.json") == 0) {
      corrupted_ = true;
      std::ofstream output(path, std::ios::binary | std::ios::trunc);
      output << "{not-json}\n";
      output.close();
      assert(output.good());
    }
    return true;
  }

private:
  mutable bool corrupted_ = false;
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

// SD controllers may acknowledge sync while bytes remain volatile. This model
// deliberately offers immediate readback but restores only the cold baseline
// on power loss. It proves host readback is NOT a power-persistence guarantee;
// it does not pretend to emulate every FAT/controller ordering behavior.
class ReadVisibleNotPowerDurableStorage final : public MapStreamStorage {
public:
  explicit ReadVisibleNotPowerDurableStorage(const std::string &root)
      : root_(root), durable_(tempRoot()),
        delegate_(map_transfer::makeDefaultMapStreamStorage()) {
    std::filesystem::copy(root_, durable_, std::filesystem::copy_options::recursive |
                          std::filesystem::copy_options::overwrite_existing);
  }
  ~ReadVisibleNotPowerDurableStorage() override {
    std::filesystem::remove_all(durable_);
  }
  void powerCut() {
    std::filesystem::remove_all(root_);
    std::filesystem::copy(durable_, root_, std::filesystem::copy_options::recursive);
  }
  bool createDirectories(const std::string &p) override { return delegate_->createDirectories(p); }
  bool removeTree(const std::string &p) override { return delegate_->removeTree(p); }
  bool regularFileSize(const std::string &p, uint64_t &n) override { return delegate_->regularFileSize(p, n); }
  bool readText(const std::string &p, std::string &v, size_t n) override { return delegate_->readText(p, v, n); }
  bool forEachDirectoryEntry(const std::string &p, const std::function<bool(const map_transfer::MapStreamDirectoryEntry &)> &f) override { return delegate_->forEachDirectoryEntry(p, f); }
  int openWrite(const std::string &p) override { return delegate_->openWrite(p); }
  int openRead(const std::string &p) override { return delegate_->openRead(p); }
  bool read(int fd, uint8_t *p, size_t n) override { return delegate_->read(fd, p, n); }
  bool write(int fd, const uint8_t *p, size_t n) override { return delegate_->write(fd, p, n); }
  bool syncFile(int fd) override { return delegate_->syncFile(fd); }
  bool closeFile(int fd) override { return delegate_->closeFile(fd); }
  bool renamePath(const std::string &p, const std::string &q) override { return delegate_->renamePath(p, q); }
  bool syncDirectory(const std::string &p) override { return delegate_->syncDirectory(p); }
private:
  std::string root_, durable_;
  std::shared_ptr<MapStreamStorage> delegate_;
};

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
              MapStreamFileAction::VerifyAndConsume);
  consumeFile(duplicate, manifest, 1, kPayload1,
              MapStreamFileAction::VerifyAndConsume);
  consumeFile(duplicate, manifest, 2, kPayload2,
              MapStreamFileAction::VerifyAndConsume);
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
              MapStreamFileAction::VerifyAndConsume);
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

void testResumeRejectsSameLengthCheckpointCorruption() {
  const std::string root = tempRoot();
  const auto manifest = verified();
  {
    MapStreamInstallSession first(root, "corrupt", {1, 10000});
    assert(first.onManifest(manifest, kManifest));
    consumeFile(first, manifest, 0, kPayload0, MapStreamFileAction::VerifyAndConsume);
    first.onAbort(map_transfer::MapStreamParserError::Truncated);
  }
  auto damaged = kPayload0;
  damaged[0] ^= 1;
  writeFile(root + "/VECTMAP/.maps/corrupt/+0000+0000/0.fmb", damaged);
  MapStreamInstallSession retry(root, "corrupt", {1, 10000});
  assert(retry.onManifest(manifest, kManifest));
  const auto file = fileView(manifest, 0);
  assert(retry.onFileBegin(file, 0) == MapStreamFileAction::VerifyAndConsume);
  assert(!retry.onFileData(file, reinterpret_cast<const uint8_t *>(kPayload0.data()), kPayload0.size()));
  assert(retry.snapshot().state == MapStreamInstallState::Failed);
  assert(retry.snapshot().errorCode == "stream_checkpoint_corrupt");
  assert(!exists(retry.inactiveRoot() + "/.ready"));
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

void testUnreadableActivePointerRestoresPreviousMap() {
  const std::string root = tempRoot();
  prepareReadyRoot(root, "prior-stream");
  MapTransferInstaller original(root);
  assert(original.activateReadyStreamMap("prior-stream").ok);
  prepareReadyRoot(root, "corrupt-pointer");

  ActiveWriteCorruptingInstaller failing(root);
  const auto failed = failing.activateReadyStreamMap("corrupt-pointer");
  assert(!failed.ok);
  assert(failed.code == "stream_active_write");
  ActiveMapSelection restored;
  assert(failing.readActiveMap(restored).ok);
  assert(restored.sessionId == "prior-stream");
  assert(!exists(root + "/VECTMAP/.maps/corrupt-pointer"));
  assert(!exists(root + "/VECTMAP/.activation-transaction.json"));
}

void testInvalidReadyRootAndMissingPointerRestorePreviousMap() {
  const std::string root = tempRoot();
  const auto previous = prepareReadyRoot(root, "prior-stream");
  MapTransferInstaller installer(root);
  assert(installer.activateReadyStreamMap("prior-stream").ok);
  const auto candidate = prepareReadyRoot(root, "broken-stream");
  writeFile(root + "/VECTMAP/.activation-transaction.json",
            "{\"manifestReceipt\":\"" + candidate.manifestReceipt +
                "\",\"mapId\":\"multi\",\"phase\":\"ready\","
                "\"previousManifestReceipt\":\"" +
                previous.manifestReceipt +
                "\",\"previousMapId\":\"multi\","
                "\"previousRoot\":\"/VECTMAP/.maps/prior-stream\","
                "\"previousSessionId\":\"prior-stream\","
                "\"previousSignedManifestReceipt\":\"" +
                previous.signedManifestReceipt +
                "\",\"protocolVersion\":2,"
                "\"root\":\"/VECTMAP/.maps/broken-stream\","
                "\"sessionId\":\"broken-stream\","
                "\"signedManifestReceipt\":\"" +
                candidate.signedManifestReceipt + "\"}\n");
  assert(::unlink((root + "/VECTMAP/active-map.json").c_str()) == 0);
  writeFile(root + "/VECTMAP/.maps/broken-stream/.manifest.json", "corrupt");

  const auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection restored;
  assert(installer.readActiveMap(restored).ok);
  assert(restored.sessionId == "prior-stream");
  assert(!exists(root + "/VECTMAP/.maps/broken-stream"));
  assert(!exists(root + "/VECTMAP/.activation-transaction.json"));
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
  // Both independent anchors retain the complete predecessor selection,
  // including its rollback root. History is bounded at four roots, not two.
  assert(exists(root + "/VECTMAP/.maps/history-a"));
  for (const char *session : {"history-d", "history-e"}) {
    prepareReadyRoot(root, session);
    assert(installer.activateReadyStreamMap(session).ok);
    assert(installer.pruneObsoleteInstalledMaps());
  }
  assert(!exists(root + "/VECTMAP/.maps/history-a"));
  for (const char *session : {"history-b", "history-c", "history-d", "history-e"})
    assert(exists(root + "/VECTMAP/.maps/" + session));
  assert(installer.recoverPendingStreamActivation().code == "stream_pending_none");
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

    // Recovery itself is interruptible. Reapply every named fault on three
    // consecutive recovery passes before allowing a successful completion.
    for (unsigned pass = 0; pass != 3; ++pass) {
      auto interruptedStorage = std::make_shared<FaultInjectingStorage>(
          faults[index].operation, faults[index].path);
      MapStreamInstallSession interrupted(
          root, "finalize-" + std::to_string(index),
          {UINT64_MAX, UINT64_MAX}, {}, interruptedStorage);
      assert(interrupted.onManifest(manifest, kManifest));
      assert(consumeAll(interrupted, manifest));
      assert(!interrupted.onComplete(manifest));
      assert(interruptedStorage->fired());
      assert(readFile(root + "/VECTMAP/active-map.json").find("old") !=
             std::string::npos);
    }
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

struct SimulatedInstallerPowerCut {};
class MutationCrashInstaller final : public MapTransferInstaller {
public:
  MutationCrashInstaller(const std::string &root, size_t cut = SIZE_MAX,
                         bool rejectReplace = false)
      : MapTransferInstaller(root), root_(root), image_(tempRoot()), cut_(cut),
        rejectReplace_(rejectReplace) {}
  ~MutationCrashInstaller() { std::filesystem::remove_all(image_); }
  mutable size_t mutations = 0;
  void restoreCutImage() const {
    std::filesystem::remove_all(root_);
    std::filesystem::copy(image_, root_, std::filesystem::copy_options::recursive);
  }
protected:
  int renameStoragePath(const char *from, const char *to) const override {
    // FAT commonly refuses a replacing rename. Force the real backup/restore
    // branch instead of assuming host POSIX replacement covers that branch.
    if (rejectReplace_ && exists(to)) {
      storageMutationBoundary("rename", to, false);
      storageMutationBoundary("rename", to, true);
      return -1;
    }
    return MapTransferInstaller::renameStoragePath(from, to);
  }
  void storageMutationBoundary(const char *, const std::string &, bool) const override {
    if (mutations++ != cut_) return;
    // Snapshot before stack unwinding flushes streams, then restore this
    // image after catching the cut, so destructors cannot mask missing sync.
    std::filesystem::remove_all(image_);
    std::filesystem::copy(root_, image_, std::filesystem::copy_options::recursive);
    throw SimulatedInstallerPowerCut{};
  }
private:
  std::string root_, image_;
  size_t cut_;
  bool rejectReplace_;
};

void testEveryInstallerMutationAndInterruptedRecovery() {
  size_t totalCuts = 0;
  for (const bool rejectReplace : {false, true}) {
  for (const bool replacement : {false, true}) {
    const std::string baseline = tempRoot();
    if (replacement) {
      prepareReadyRoot(baseline, "previous");
      MapTransferInstaller installer(baseline);
      assert(installer.activateReadyStreamMap("previous").ok);
    }
    prepareReadyRoot(baseline, "candidate");
    auto clone = [&]() {
      const auto root = tempRoot();
      std::filesystem::copy(baseline, root, std::filesystem::copy_options::recursive |
                            std::filesystem::copy_options::overwrite_existing);
      return root;
    };
    const std::string completeRoot = clone();
    MutationCrashInstaller complete(completeRoot, SIZE_MAX, rejectReplace);
    assert(complete.activateReadyStreamMap("candidate").ok);
    const size_t mutationCount = complete.mutations;
    assert(mutationCount > 10);
    for (size_t cut = 0; cut != mutationCount; ++cut) {
      const std::string root = clone();
      MutationCrashInstaller interrupted(root, cut, rejectReplace);
      bool cutReached = false;
      try { (void)interrupted.activateReadyStreamMap("candidate"); }
      catch (const SimulatedInstallerPowerCut &) {
        interrupted.restoreCutImage();
        cutReached = true;
      }
      assert(cutReached);
      ++totalCuts;
      for (size_t pass = 0; pass != 3; ++pass) {
        MutationCrashInstaller recovery(root, pass, rejectReplace);
        try { (void)recovery.recoverInterruptedActivation(); }
        catch (const SimulatedInstallerPowerCut &) { recovery.restoreCutImage(); }
      }
      MapTransferInstaller recovered(root);
      for (unsigned pass = 0; pass != 3; ++pass)
        (void)recovered.recoverInterruptedActivation();
      ActiveMapSelection selected;
      const auto selection = recovered.readActiveMap(selected);
      if (replacement) assert(selection.ok);
      if (selection.ok) {
        assert(selected.sessionId == "previous" || selected.sessionId == "candidate");
        assert(readFile(root + selected.root + "/+0000+0000/0.fmb") == kPayload0);
        assert(readFile(root + selected.root + "/+0000+0000/1.fmb") == kPayload1);
      }
      std::filesystem::remove_all(root);
    }
    std::filesystem::remove_all(completeRoot);
    std::filesystem::remove_all(baseline);
  }
  }
  std::cout << "installer mutation cuts exercised=" << totalCuts << "\n";
}

void testSuccessfulReadbackDoesNotProvePowerDurability() {
  for (const bool replacement : {false, true}) {
    const std::string root = tempRoot();
    std::filesystem::create_directories(root + "/VECTMAP");
    const std::string oldPointer = "{\"mapId\":\"old\",\"root\":\"/VECTMAP\"}\n";
    if (replacement) writeFile(root + "/VECTMAP/active-map.json", oldPointer);
    auto storage = std::make_shared<ReadVisibleNotPowerDurableStorage>(root);
    const auto manifest = verified();
    {
      MapStreamInstallSession session(root, "volatile-ready", {1, 10000}, {}, storage);
      assert(session.onManifest(manifest, kManifest));
      assert(consumeAll(session, manifest));
      assert(session.onComplete(manifest));
      assert(exists(session.inactiveRoot() + "/.ready"));
      assert(readFile(session.inactiveRoot() + "/.manifest.json") == kManifest);
    }
    // Three independent cold recoveries must not turn vanished prepared work
    // into an installed result. First install is allowed to retain no map.
    for (unsigned recovery = 0; recovery != 3; ++recovery) {
      storage->powerCut();
      MapStreamInstallSnapshot snapshot;
      assert(map_transfer::readRecoverableMapStreamInstall(root, snapshot) ==
             MapStreamRecoveryResult::None);
      assert(!exists(root + "/VECTMAP/.maps/volatile-ready/.ready"));
      if (replacement) assert(readFile(root + "/VECTMAP/active-map.json") == oldPointer);
      else assert(!exists(root + "/VECTMAP/active-map.json"));
    }
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

// Deterministic barriers invoke the actual receiver and commit policy. No
// scheduling sleeps: revocation is placed on each side of the grant boundary.
void testReceiverCommitCancellationBarriers() {
  const auto fixture = readGoldenFixture();
  const auto stream = decodeHex(fixture.at("stream_hex"));
  const auto publicKey = decodeHex(fixture.at("public_key_x963_hex"));
  map_transfer::MapStreamTrustStore trust;
  assert(trust.add("map-test-2026-01", publicKey.data(), publicKey.size()));
  {
    const auto root = tempRoot();
    MapStreamReceiver wrongLength(trust, root, "wrong-length", stream.size() + 1,
                                  "9.0.0", 1024 * 1024);
    assert(!wrongLength.feed(stream.data(), stream.size()));
    assert(!wrongLength.readyToFinish());
    assert(!wrongLength.abort().ok);
    assert(!exists(root + "/VECTMAP/.pending-stream-activation.json"));
  }
  {
    const auto root = tempRoot();
    auto corrupt = stream;
    corrupt.back() ^= 1;
    MapStreamReceiver wrongHash(trust, root, "wrong-hash", stream.size(),
                                "9.0.0", 1024 * 1024);
    assert(!wrongHash.feed(corrupt.data(), corrupt.size()));
    assert(!wrongHash.readyToFinish());
    assert(!wrongHash.abort().ok);
    assert(!exists(root + "/VECTMAP/.pending-stream-activation.json"));
  }
  for (int barrier = 0; barrier != 4; ++barrier) {
    const auto root = tempRoot();
    device_transfer::commit_boundary_policy::Boundary boundary;
    bool authorized = true;
    bool revokedDuringFinalization = false;
    MapStreamReceiver receiver(trust, root, "barrier", stream.size(),
                               "9.0.0", 1024 * 1024, {}, {}, {},
        [&](const MapStreamInstallSnapshot &snapshot) {
          if (barrier == 3 && snapshot.state == MapStreamInstallState::Finalizing) {
            authorized = false;
            boundary.closeAdmission(true);
            revokedDuringFinalization = true;
            assert(boundary.active());
          }
        });
    const auto received = barrier == 0 ? stream.size() - 1 : stream.size();
    assert(receiver.feed(stream.data(), received));
    assert(receiver.readyToFinish() == (barrier != 0));
    assert(!exists(root + "/VECTMAP/.maps/barrier/.ready"));
    assert(!exists(root + "/VECTMAP/.pending-stream-activation.json"));
    if (barrier <= 1)
      authorized = false; // before last byte / after last byte before grant
    const auto grant = receiver.readyToFinish()
        ? boundary.begin(authorized, true, true, "barrier",
                         receiver.snapshot().signedManifestReceipt) : 0;
    if (grant == 0) {
      assert(!receiver.abort().ok);
      assert(!receiver.readyToFinish());
      assert(!receiver.finish().ok); // abort is sticky, never onComplete
      assert(!exists(root + "/VECTMAP/.maps/barrier/.ready"));
      assert(!exists(root + "/VECTMAP/.pending-stream-activation.json"));
      MapTransferInstaller recovery(root);
      assert(recovery.recoverInterruptedActivation().ok);
      map_transfer::ActiveMapSelection selected;
      assert(!recovery.readActiveMap(selected).ok);
    } else {
      if (barrier == 2) {
        authorized = false; // grant-first, revocation before finalization
        boundary.closeAdmission(true);
      }
      assert(boundary.owns(grant));
      assert(receiver.finish().ok);
      assert(barrier != 3 || revokedDuringFinalization);
      assert(exists(root + "/VECTMAP/.maps/barrier/.ready"));
      assert(exists(root + "/VECTMAP/.pending-stream-activation.json"));
      MapTransferInstaller recovery(root);
      assert(recovery.recoverPendingStreamActivation().ok);
      map_transfer::ActiveMapSelection selected;
      assert(recovery.readActiveMap(selected).ok);
      assert(selected.sessionId == "barrier");
      assert(boundary.end(grant));
      assert(!boundary.end(grant));
    }
  }
}

void testDeviceBoundOperationActivationAndReceipt() {
  namespace op=map_transfer::operation;
  const auto fixture=readGoldenFixture();
  const auto stream=decodeHex(fixture.at("stream_hex"));
  const auto publicKey=decodeHex(fixture.at("public_key_x963_hex"));
  map_transfer::MapStreamTrustStore trust;
  assert(trust.add("map-test-2026-01",publicKey.data(),publicKey.size()));
  const auto root=tempRoot(); const std::string device(32,'a'), operation(32,'1');
  MapStreamReceiver receiver(trust,root,"operation-session",stream.size(),"9.0.0",
                             1024*1024,{},{},{},{},operation);
  assert(receiver.feed(stream.data(),stream.size()));
  assert(receiver.readyToFinish());
  const auto snapshot=receiver.snapshot();
  map_transfer::Sha256Hasher hash; hash.update(stream.data(),stream.size());
  op::Identity identity{device,operation,snapshot.manifestReceipt,
      snapshot.signedManifestReceipt,hash.finalHex(),stream.size(),snapshot.sessionId,snapshot.mapId};
  map_transfer::MapOperationStorage storage(root); op::Store ledger(storage,device);
  assert(ledger.restore()==op::Result::Ok);
  assert(ledger.initializeAdmission(100)==op::Result::Ok);
  assert(ledger.admit(identity,ledger.admissionRevision())==op::Result::Ok);
  // Upload completion creates only nonactivatable prepared metadata.
  assert(receiver.finish().ok);
  assert(receiver.snapshot().state==MapStreamInstallState::Prepared);
  assert(exists(root+"/VECTMAP/.maps/operation-session/.operation-prepared"));
  assert(!exists(root+"/VECTMAP/.maps/operation-session/.operation-ready"));
  assert(!exists(root+"/VECTMAP/.pending-stream-activation.json"));
  assert(ledger.prepare(identity)==op::Result::Ok);
  assert(!exists(root+"/VECTMAP/.maps/operation-session/.ready"));
  MapTransferInstaller installer(root); installer.setOperationDeviceID(device);
  assert(installer.recoverPendingStreamActivation().ok);
  assert(!installer.promotePreparedOperation(identity.session,identity.operation).ok);
  ActiveMapSelection selected; assert(!installer.readActiveMap(selected).ok);
  assert(ledger.accept(identity)==op::Result::Ok);
  MapTransferInstaller beforeOwnershipInit(root);
  assert(!beforeOwnershipInit.promotePreparedOperation(identity.session,identity.operation).ok);
  MapTransferInstaller otherDevice(root); otherDevice.setOperationDeviceID(std::string(32,'f'));
  assert(!otherDevice.promotePreparedOperation(identity.session,identity.operation).ok);
  assert(installer.promotePreparedOperation(identity.session,identity.operation).ok);
  // Reproduce a real crash after pointer rename but before cleanup/renderer:
  // main's early installer must bind immutable device identity and recover the
  // exact transaction BEFORE it exposes that pointer to the renderer.
  struct BootCut {};
  class InterruptedPointerInstaller final : public MapTransferInstaller {
  public:
    using MapTransferInstaller::MapTransferInstaller;
  protected:
    void storageMutationBoundary(const char *operation,const std::string &path,
                                 bool after) const override {
      if (after && std::string(operation)=="rename" &&
          path.size()>=24 && path.substr(path.size()-24)=="/VECTMAP/active-map.json")
        throw BootCut{};
    }
  };
  InterruptedPointerInstaller interrupted(root);
  interrupted.setOperationDeviceID(device);
  bool powerCut=false;
  try { (void)interrupted.activateReadyStreamMap(identity.session); }
  catch (const BootCut &) { powerCut=true; }
  assert(powerCut);
  assert(exists(root+"/VECTMAP/.activation-transaction.json"));
  assert(!beforeOwnershipInit.recoverInterruptedActivation().ok);
  assert(!otherDevice.recoverInterruptedActivation().ok);
  MapTransferInstaller mainBootInstaller(root);
  mainBootInstaller.setOperationDeviceID(device);
  assert(mainBootInstaller.recoverInterruptedActivation().ok);
  assert(mainBootInstaller.readActiveMap(selected).ok);
  assert(selected.sessionId==identity.session);
  assert(selected.manifestReceipt==identity.manifest);
  assert(exists(root+"/VECTMAP/.activation-transaction.json"));
  assert(!exists(root+"/VECTMAP/.maps/operation-session/.activation-consumed"));
  assert(!mainBootInstaller.finalizeOperation(identity.session,identity.operation).ok);
  op::Record receipt;
  op::Store rebooted(storage,device); assert(rebooted.restore()==op::Result::Ok);
  assert(rebooted.query(identity,receipt)==op::Result::Ok);
  assert(receipt.phase==op::Phase::Accepted); // pointer is NOT installed
  assert(rebooted.rendererAcknowledged(identity,selected.manifestReceipt,
                                      selected.signedManifestReceipt)==op::Result::Ok);
  op::Store finalBoot(storage,device); assert(finalBoot.restore()==op::Result::Ok);
  assert(finalBoot.query(identity,receipt)==op::Result::Ok && receipt.phase==op::Phase::Installed);
  assert(exists(root+"/VECTMAP/.activation-transaction.json"));
  assert(mainBootInstaller.finalizeOperation(identity.session,identity.operation).ok);
  assert(!exists(root+"/VECTMAP/.activation-transaction.json"));
  assert(!exists(root+"/VECTMAP/.pending-stream-activation.json"));
  assert(map_transfer::operationReceiptJson(receipt).find("\"phase\":\"installed\"")!=std::string::npos);
  // The copied card retains usable signed map content, never local operation authority.
  assert(otherDevice.readActiveMap(selected).ok);
  op::Store foreign(storage,std::string(32,'f')); assert(foreign.restore()==op::Result::ForeignDevice);
}

void testExplicitOperationPromotionAndTerminalCrashBoundaries() {
  namespace op=map_transfer::operation;
  const auto fixture=readGoldenFixture();
  const auto stream=decodeHex(fixture.at("stream_hex"));
  const auto publicKey=decodeHex(fixture.at("public_key_x963_hex"));
  map_transfer::MapStreamTrustStore trust;
  assert(trust.add("map-test-2026-01",publicKey.data(),publicKey.size()));
  const std::string device(32,'a'), operation(32,'2'), session="explicit-operation";
  size_t promotionCuts=0, terminalCuts=0;
  for (bool replacement : {false,true}) {
    const auto baseline=tempRoot();
    if (replacement) {
      prepareReadyRoot(baseline,"previous-operation");
      MapTransferInstaller previous(baseline);
      assert(previous.activateReadyStreamMap("previous-operation").ok);
    }
    MapStreamReceiver receiver(trust,baseline,session,stream.size(),"9.0.0",1024*1024,{},{},{},{},operation);
    assert(receiver.feed(stream.data(),stream.size()) && receiver.readyToFinish());
    assert(receiver.finish().ok && receiver.snapshot().state==MapStreamInstallState::Prepared);
    const auto snapshot=receiver.snapshot();
    map_transfer::Sha256Hasher hash; hash.update(stream.data(),stream.size());
    op::Identity identity{device,operation,snapshot.manifestReceipt,snapshot.signedManifestReceipt,
                         hash.finalHex(),stream.size(),session,snapshot.mapId};
    map_transfer::MapOperationStorage disk(baseline); op::Store store(disk,device);
    assert(store.restore()==op::Result::Ok && store.initializeAdmission(100)==op::Result::Ok);
    assert(store.admit(identity,store.admissionRevision())==op::Result::Ok);
    assert(store.prepare(identity)==op::Result::Ok);
    const auto clone=[&](const std::string &source) {
      const auto root=tempRoot();
      std::filesystem::copy(source,root,std::filesystem::copy_options::recursive |
                                        std::filesystem::copy_options::overwrite_existing);
      return root;
    };
    // Reboot and lost preparation response can only reveal Prepared. Neither
    // .ready, pending nor consumed exists, and no recovery pass activates it.
    for (unsigned pass=0;pass<3;++pass) {
      MapTransferInstaller boot(baseline); boot.setOperationDeviceID(device);
      assert(boot.recoverInterruptedActivation().ok);
      assert(boot.recoverPendingStreamActivation().ok);
      ActiveMapSelection active;
      const auto selected=boot.readActiveMap(active);
      assert(replacement ? selected.ok && active.sessionId=="previous-operation" : !selected.ok);
      assert(!exists(baseline+"/VECTMAP/.maps/"+session+"/.operation-ready"));
    }
    // Cancel-first is durable, idempotent, and forbids all later promotion.
    const auto cancelledRoot=clone(baseline);
    map_transfer::MapOperationStorage cancelledDisk(cancelledRoot); op::Store cancelled(cancelledDisk,device);
    assert(cancelled.restore()==op::Result::Ok && cancelled.cancel(identity)==op::Result::Ok);
    assert(cancelled.cancel(identity)==op::Result::Replay);
    assert(cancelled.accept(identity)==op::Result::NotAccepted);
    MapTransferInstaller cancelledInstaller(cancelledRoot); cancelledInstaller.setOperationDeviceID(device);
    assert(!cancelledInstaller.promotePreparedOperation(session,operation).ok);
    assert(!exists(cancelledRoot+"/VECTMAP/.pending-stream-activation.json"));
    assert(store.accept(identity)==op::Result::Ok);
    assert(store.cancel(identity)==op::Result::TooLate);
    // The baseline now models an immediate reset AFTER accepted intent but
    // BEFORE any ready/pending mutation. Every recovery starts from this disk.
    for (bool rejectReplace : {false,true}) {
      const auto probeRoot=clone(baseline);
      MutationCrashInstaller probe(probeRoot,SIZE_MAX,rejectReplace); probe.setOperationDeviceID(device);
      assert(probe.promotePreparedOperation(session,operation).ok);
      const size_t mutations=probe.mutations;
      assert(mutations>0);
      for (size_t cut=0;cut<mutations;++cut) {
        const auto root=clone(baseline);
        MutationCrashInstaller interrupted(root,cut,rejectReplace); interrupted.setOperationDeviceID(device);
        bool reached=false;
        try { (void)interrupted.promotePreparedOperation(session,operation); }
        catch (const SimulatedInstallerPowerCut &) { interrupted.restoreCutImage(); reached=true; }
        assert(reached); ++promotionCuts;
        for (size_t pass=0;pass<3;++pass) {
          MutationCrashInstaller recovery(root,pass,rejectReplace); recovery.setOperationDeviceID(device);
          try { (void)recovery.promotePreparedOperation(session,operation); }
          catch (const SimulatedInstallerPowerCut &) { recovery.restoreCutImage(); }
        }
        MapTransferInstaller recovered(root); recovered.setOperationDeviceID(device);
        assert(recovered.promotePreparedOperation(session,operation).ok);
        assert(recovered.recoverPendingStreamActivation().ok);
        assert(exists(root+"/VECTMAP/.activation-transaction.json"));
        assert(exists(root+"/VECTMAP/.pending-stream-activation.json"));
        assert(!exists(root+"/VECTMAP/.maps/"+session+"/.activation-consumed"));
        assert(!recovered.finalizeOperation(session,operation).ok);
        map_transfer::MapOperationStorage restoredDisk(root); op::Store restored(restoredDisk,device); op::Record receipt;
        assert(restored.restore()==op::Result::Ok && restored.query(identity,receipt)==op::Result::Ok);
        assert(receipt.phase==op::Phase::Accepted);
        assert(restored.rendererAcknowledged(identity,identity.manifest,identity.signedManifest)==op::Result::Ok);
        assert(recovered.finalizeOperation(session,operation).ok);
        assert(!exists(root+"/VECTMAP/.activation-transaction.json"));
        std::filesystem::remove_all(root);
      }
    }
    // Cut each terminal cleanup boundary only AFTER the renderer receipt is
    // durably Installed. Journal evidence survives until then, including reboot.
    const auto terminalBase=clone(baseline);
    MapTransferInstaller selected(terminalBase); selected.setOperationDeviceID(device);
    assert(selected.promotePreparedOperation(session,operation).ok);
    assert(selected.recoverPendingStreamActivation().ok);
    map_transfer::MapOperationStorage terminalDisk(terminalBase); op::Store terminal(terminalDisk,device);
    assert(terminal.restore()==op::Result::Ok);
    assert(terminal.rendererAcknowledged(identity,identity.manifest,identity.signedManifest)==op::Result::Ok);
    const auto cleanupProbeRoot=clone(terminalBase);
    MutationCrashInstaller cleanupProbe(cleanupProbeRoot); cleanupProbe.setOperationDeviceID(device);
    assert(cleanupProbe.finalizeOperation(session,operation).ok);
    for (size_t cut=0;cut<cleanupProbe.mutations;++cut) {
      const auto root=clone(terminalBase);
      MutationCrashInstaller interrupted(root,cut); interrupted.setOperationDeviceID(device);
      bool reached=false;
      try { (void)interrupted.finalizeOperation(session,operation); }
      catch (const SimulatedInstallerPowerCut &) { interrupted.restoreCutImage(); reached=true; }
      assert(reached); ++terminalCuts;
      for (size_t pass=0;pass<3;++pass) {
        MutationCrashInstaller recovery(root,pass); recovery.setOperationDeviceID(device);
        try { (void)recovery.finalizeOperation(session,operation); }
        catch (const SimulatedInstallerPowerCut &) { recovery.restoreCutImage(); }
      }
      MapTransferInstaller recovered(root); recovered.setOperationDeviceID(device);
      assert(recovered.finalizeOperation(session,operation).ok);
      assert(!exists(root+"/VECTMAP/.activation-transaction.json"));
      assert(!exists(root+"/VECTMAP/.pending-stream-activation.json"));
      map_transfer::MapOperationStorage restoredDisk(root); op::Store restored(restoredDisk,device); op::Record receipt;
      assert(restored.restore()==op::Result::Ok && restored.query(identity,receipt)==op::Result::Ok);
      assert(receipt.phase==op::Phase::Installed);
      std::filesystem::remove_all(root);
    }
    // Renderer failure preserves journal until failed receipt is persisted;
    // the next boot can then remove only the rejected, unselected candidate.
    const auto failedRoot=clone(baseline);
    MapTransferInstaller failedInstaller(failedRoot); failedInstaller.setOperationDeviceID(device);
    assert(failedInstaller.promotePreparedOperation(session,operation).ok);
    assert(failedInstaller.recoverPendingStreamActivation().ok);
    assert(failedInstaller.rollbackActiveMap(session).ok);
    assert(exists(failedRoot+"/VECTMAP/.activation-transaction.json"));
    map_transfer::MapOperationStorage failedDisk(failedRoot); op::Store failed(failedDisk,device);
    assert(failed.restore()==op::Result::Ok && failed.fail(identity)==op::Result::Ok);
    MapTransferInstaller failedBoot(failedRoot); failedBoot.setOperationDeviceID(device);
    assert(failedBoot.recoverInterruptedActivation().ok);
    assert(!exists(failedRoot+"/VECTMAP/.activation-transaction.json"));
  }
  std::cout << "operation promotion cuts=" << promotionCuts << " terminal cleanup cuts=" << terminalCuts << "\n";
}

void testPreparedReinstallCannotInheritLegacyAuthorityOrDeletePriorMap() {
  namespace op=map_transfer::operation;
  const auto fixture=readGoldenFixture();
  const auto stream=decodeHex(fixture.at("stream_hex"));
  const auto publicKey=decodeHex(fixture.at("public_key_x963_hex"));
  map_transfer::MapStreamTrustStore trust;
  assert(trust.add("map-test-2026-01",publicKey.data(),publicKey.size()));
  for (bool priorOperation : {false,true}) {
  const auto root=tempRoot(); const std::string session="same-content", device(32,'a'), operation(32,'3');
  const std::string oldOperation(32,'4');
  MapStreamReceiver legacy(trust,root,session,stream.size(),"9.0.0",1024*1024,{},{},{},{},priorOperation ? oldOperation : "");
  assert(legacy.feed(stream.data(),stream.size()) && legacy.finish().ok);
  MapTransferInstaller installer(root); installer.setOperationDeviceID(device);
  op::Identity oldIdentity;
  if (priorOperation) {
    map_transfer::Sha256Hasher oldHash; oldHash.update(stream.data(),stream.size());
    oldIdentity={device,oldOperation,legacy.snapshot().manifestReceipt,legacy.snapshot().signedManifestReceipt,
                 oldHash.finalHex(),stream.size(),session,legacy.snapshot().mapId};
    map_transfer::MapOperationStorage oldDisk(root); op::Store oldStore(oldDisk,device);
    assert(oldStore.restore()==op::Result::Ok && oldStore.initializeAdmission(100)==op::Result::Ok);
    assert(oldStore.admit(oldIdentity,oldStore.admissionRevision())==op::Result::Ok);
    assert(oldStore.prepare(oldIdentity)==op::Result::Ok && oldStore.accept(oldIdentity)==op::Result::Ok);
    assert(installer.promotePreparedOperation(session,oldOperation).ok);
    assert(installer.activateReadyStreamMap(session).ok);
    assert(oldStore.rendererAcknowledged(oldIdentity,oldIdentity.manifest,oldIdentity.signedManifest)==op::Result::Ok);
    assert(installer.finalizeOperation(session,oldOperation).ok);
  } else {
    assert(installer.activateReadyStreamMap(session).ok);
  }
  ActiveMapSelection original;
  assert(installer.readActiveMap(original).ok);
  MapStreamReceiver prepare(trust,root,session,stream.size(),"9.0.0",1024*1024,{},{},{},{},operation);
  assert(prepare.feed(stream.data(),stream.size()) && prepare.finish().ok);
  assert(prepare.snapshot().bytesSkipped>0);
  map_transfer::Sha256Hasher hash; hash.update(stream.data(),stream.size());
  op::Identity identity{device,operation,prepare.snapshot().manifestReceipt,prepare.snapshot().signedManifestReceipt,
                       hash.finalHex(),stream.size(),session,prepare.snapshot().mapId};
  map_transfer::MapOperationStorage disk(root); op::Store store(disk,device);
  assert(store.restore()==op::Result::Ok);
  if (!priorOperation) assert(store.initializeAdmission(100)==op::Result::Ok);
  assert(store.admit(identity,store.admissionRevision())==op::Result::Ok && store.prepare(identity)==op::Result::Ok);
  MapStreamInstallSnapshot recovered;
  assert(readRecoverableMapStreamInstall(root,recovered)==MapStreamRecoveryResult::Found);
  assert(recovered.state==MapStreamInstallState::Prepared);
  assert(!installer.activateReadyStreamMap(session).ok); // old .ready is not this grant
  ActiveMapSelection stillOriginal;
  assert(installer.readActiveMap(stillOriginal).ok && stillOriginal.root==original.root);
  const auto cancelledRoot=tempRoot();
  std::filesystem::copy(root,cancelledRoot,std::filesystem::copy_options::recursive |
                                        std::filesystem::copy_options::overwrite_existing);
  map_transfer::MapOperationStorage cancelledDisk(cancelledRoot); op::Store cancelled(cancelledDisk,device);
  assert(cancelled.restore()==op::Result::Ok && cancelled.cancel(identity)==op::Result::Ok);
  MapTransferInstaller cancelledInstaller(cancelledRoot); cancelledInstaller.setOperationDeviceID(device);
  assert(cancelledInstaller.cancelOperationStaging(session,operation).ok);
  assert(cancelledInstaller.readActiveMap(stillOriginal).ok && stillOriginal.root==original.root);
  assert(exists(cancelledRoot+original.root+(priorOperation ? "/.operation-ready" : "/.ready")));
  assert(!exists(cancelledRoot+original.root+"/.operation-prepared"));
  assert(store.accept(identity)==op::Result::Ok);
  assert(installer.promotePreparedOperation(session,operation).ok);
  assert(!exists(root+original.root+"/.activation-consumed"));
  assert(installer.activateReadyStreamMap(session).ok);
  assert(exists(root+"/VECTMAP/.activation-transaction.json"));
  assert(installer.rollbackActiveMap(session).ok);
  assert(installer.readActiveMap(stillOriginal).ok && stillOriginal.root==original.root);
  assert(store.fail(identity)==op::Result::Ok);
  assert(installer.finalizeOperation(session,operation).ok);
  assert(installer.readActiveMap(stillOriginal).ok && stillOriginal.root==original.root);
  assert(exists(root+original.root+"/.activation-consumed"));
  assert(readRecoverableMapStreamInstall(root,recovered)==MapStreamRecoveryResult::None);
  if (priorOperation) {
    op::Record oldReceipt;
    assert(store.query(oldIdentity,oldReceipt)==op::Result::Ok && oldReceipt.phase==op::Phase::Installed);
  }
  }
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
  testDeviceBoundOperationActivationAndReceipt();
  testExplicitOperationPromotionAndTerminalCrashBoundaries();
  testPreparedReinstallCannotInheritLegacyAuthorityOrDeletePriorMap();
  testReceiverCommitCancellationBarriers();
  testResumeRejectsSameLengthCheckpointCorruption();
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
  testUnreadableActivePointerRestoresPreviousMap();
  testInvalidReadyRootAndMissingPointerRestorePreviousMap();
  testReadyPayloadDamageCannotBeSkippedOrActivated();
  testSemanticBackupRecovery();
  testPreviousRootIdentityIsProtected();
  testRollbackRejectsMismatchedPreviousIdentity();
  testConsumedReadyRootsAreNotReactivatedAndArePruned();
  testFrozenMapIdEdgesInstallAndActivate();
  testCrashBoundariesRemainRetryableWithMonotonicFinalization();
  testEveryInstallerMutationAndInterruptedRecovery();
  testSuccessfulReadbackDoesNotProvePowerDurability();
  testLargeDirectoryCleanupStreamsEntries();
  testTransportIndependentReceiverOwnsExactBodyLifecycle();
  testStartingNewStreamPrunesAbandonedPausedSessions();
  std::cout << "map_stream_install tests passed\n";
  return 0;
}
