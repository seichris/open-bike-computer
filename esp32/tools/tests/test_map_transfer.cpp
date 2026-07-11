#include "../../lib/map_transfer/map_transfer.hpp"

#include <cassert>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

using map_transfer::MapManifest;
using map_transfer::MapActivationState;
using map_transfer::MapTransferInstaller;
using map_transfer::ActivationBeginResult;
using map_transfer::sha256Hex;

static bool exists(const std::string &path) {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0;
}

static void writeFile(const std::string &path, const std::string &text) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  assert(out.good());
  out << text;
}

static std::string readFile(const std::string &path) {
  std::ifstream in(path, std::ios::binary);
  assert(in.good());
  std::stringstream buffer;
  buffer << in.rdbuf();
  return buffer.str();
}

static std::string tempRoot() {
  std::string tmpl = "/tmp/open-bike-map-transfer-XXXXXX";
  char *buffer = tmpl.data();
  char *created = ::mkdtemp(buffer);
  assert(created != nullptr);
  return std::string(created);
}

static std::string sha(const std::string &text) {
  return sha256Hex(reinterpret_cast<const uint8_t *>(text.data()), text.size());
}

static void testSha256KnownVector() {
  assert(sha("abc") ==
         "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

static void testActivationStateTracksAttemptsAndCompactStatus() {
  MapActivationState state;
  auto initial = state.snapshot();
  assert(!initial.running);
  assert(initial.sequence == 0);
  assert(initial.status == "idle");

  assert(state.begin("session-1") == ActivationBeginResult::Started);
  auto first = state.snapshot();
  assert(first.running);
  assert(first.sequence == 1);
  assert(first.status == "activating");
  assert(first.sessionId == "session-1");
  assert(state.begin("session-1") == ActivationBeginResult::AlreadyRunning);
  assert(state.begin("session-2") == ActivationBeginResult::Busy);
  assert(state.snapshot().sequence == 1);

  state.finish("failed", "map-1", "file_sha256",
               "staged map file sha256 mismatch: VECTMAP/map-1/123.fmb");
  auto failed = state.snapshot();
  assert(!failed.running);
  assert(failed.status == "failed");
  assert(failed.mapId == "map-1");
  assert(failed.errorCode == "file_sha256");
  std::string full = state.json(false);
  assert(full.find("\"mapId\":\"map-1\"") != std::string::npos);
  assert(full.find("staged map file sha256 mismatch") != std::string::npos);
  std::string compact = state.json(true);
  assert(compact.find("\"sequence\":1") != std::string::npos);
  assert(compact.find("\"code\":\"file_sha256\"") != std::string::npos);
  assert(compact.find("mapId") == std::string::npos);
  assert(compact.find("mismatch") == std::string::npos);
  assert(compact.size() <= 192);

  assert(state.begin("session-1") == ActivationBeginResult::Started);
  auto second = state.snapshot();
  assert(second.sequence == 2);
  assert(second.status == "activating");
  assert(second.errorCode.empty());
}

static void testRejectsUnsafeManifestPath() {
  MapTransferInstaller installer("/tmp/root");
  MapManifest manifest;
  std::string manifestText =
      "{\"schemaVersion\":1,\"mapId\":\"map-1\",\"files\":[{\"path\":\"VECTMAP/"
      "map-1/../evil.fmb\",\"bytes\":1,\"sha256\":\"" +
      std::string(64, '0') + "\"}]}";

  auto status = installer.validateManifestText(manifestText, manifest);
  assert(!status.ok);
  assert(status.code == "manifest_path");
}

static void testRejectsPathOutsideMapNamespace() {
  MapTransferInstaller installer("/tmp/root");
  MapManifest manifest;
  std::string manifestText =
      "{\"schemaVersion\":1,\"mapId\":\"map-1\",\"files\":[{\"path\":\"VECTMAP/"
      ".rollback/hidden.fmb\",\"bytes\":1,\"sha256\":\"" +
      std::string(64, '0') + "\"}]}";

  auto status = installer.validateManifestText(manifestText, manifest);
  assert(!status.ok);
  assert(status.code == "manifest_path");
}

static void testValidatesStagedMapAndActivates() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string session = "session-1";
  const std::string stagedDir =
      root + "/VECTMAP/.staging/" + session + "/VECTMAP/map-1/+0032+0008";
  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  const std::string blockData = "map-block";
  const std::string previewData = "map-preview";
  writeFile(stagedDir + "/123_456.fmb", blockData);
  writeFile(stagedDir + "/123_456.fmp", previewData);
  const std::string manifestText =
      "{\"schemaVersion\":1,\"mapId\":\"map-1\",\"files\":["
      "{\"path\":\"VECTMAP/map-1/+0032+0008/123_456.fmb\",\"bytes\":9,"
      "\"sha256\":\"" +
      sha(blockData) +
      "\"},"
      "{\"path\":\"VECTMAP/map-1/+0032+0008/123_456.fmp\",\"bytes\":11,"
      "\"sha256\":\"" +
      sha(previewData) + "\"}]}";
  writeFile(root + "/VECTMAP/.staging/" + session + "/manifest.json",
            manifestText);

  MapManifest manifest;
  auto validated = installer.validateStagedMap(session, manifest);
  assert(validated.ok);
  assert(manifest.mapId == "map-1");
  assert(manifest.files[0].publishPath == "VECTMAP/+0032+0008/123_456.fmb");

  auto activated = installer.activateStagedMap(session, manifest);
  assert(activated.ok);
  assert(exists(root + "/VECTMAP/+0032+0008/123_456.fmb"));
  assert(readFile(root + "/VECTMAP/+0032+0008/123_456.fmb") == blockData);
  std::string activeMapId;
  auto active = installer.readActiveMapId(activeMapId);
  assert(active.ok);
  assert(activeMapId == "map-1");
  assert(!exists(root + "/VECTMAP/.staging/" + session));
  assert(!exists(root + "/VECTMAP/.activation/" + session));
  assert(!exists(root + "/VECTMAP/.installed/map-1"));
}

static void testActivationReplacesOldPublishedBlocks() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string session = "session-replace";
  const std::string oldDir = root + "/VECTMAP/+9999+9999";
  const std::string stagedDir =
      root + "/VECTMAP/.staging/" + session + "/VECTMAP/map-new/+0032+0008";
  assert(::system((std::string("mkdir -p ") + oldDir).c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  writeFile(oldDir + "/old.fmb", "old-map-block");
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"mapId\":\"map-old\",\"root\":\"/VECTMAP\"}\n");

  const std::string blockData = "new-map-block";
  writeFile(stagedDir + "/123_456.fmb", blockData);
  const std::string manifestText =
      "{\"schemaVersion\":1,\"mapId\":\"map-new\",\"files\":[{\"path\":"
      "\"VECTMAP/map-new/+0032+0008/123_456.fmb\",\"bytes\":13,"
      "\"sha256\":\"" +
      sha(blockData) + "\"}]}";
  writeFile(root + "/VECTMAP/.staging/" + session + "/manifest.json",
            manifestText);

  MapManifest manifest;
  auto validated = installer.validateStagedMap(session, manifest);
  assert(validated.ok);
  auto activated = installer.activateStagedMap(session, manifest);
  assert(activated.ok);
  assert(!exists(oldDir + "/old.fmb"));
  assert(exists(root + "/VECTMAP/+0032+0008/123_456.fmb"));
  assert(readFile(root + "/VECTMAP/+0032+0008/123_456.fmb") == blockData);
  std::string activeMapId;
  auto active = installer.readActiveMapId(activeMapId);
  assert(active.ok);
  assert(activeMapId == "map-new");
}

static void testActivationRestoresOldMapWhenMetadataWriteFails() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string session = "session-rollback";
  const std::string oldDir = root + "/VECTMAP/+9999+9999";
  const std::string stagedDir =
      root + "/VECTMAP/.staging/" + session + "/VECTMAP/map-new/+0032+0008";
  assert(::system((std::string("mkdir -p ") + oldDir).c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  writeFile(oldDir + "/old.fmb", "old-map-block");
  const std::string activePath = root + "/VECTMAP/active-map.json";
  writeFile(activePath, "{\"mapId\":\"map-old\",\"root\":\"/VECTMAP\"}\n");
  assert(::chmod(activePath.c_str(), 0444) == 0);

  const std::string blockData = "new-map-block";
  writeFile(stagedDir + "/123_456.fmb", blockData);
  const std::string manifestText =
      "{\"schemaVersion\":1,\"mapId\":\"map-new\",\"files\":[{\"path\":"
      "\"VECTMAP/map-new/+0032+0008/123_456.fmb\",\"bytes\":13,"
      "\"sha256\":\"" +
      sha(blockData) + "\"}]}";
  writeFile(root + "/VECTMAP/.staging/" + session + "/manifest.json",
            manifestText);

  MapManifest manifest;
  auto validated = installer.validateStagedMap(session, manifest);
  assert(validated.ok);
  auto activated = installer.activateStagedMap(session, manifest);
  assert(!activated.ok);
  assert(activated.code == "active_write");
  assert(exists(oldDir + "/old.fmb"));
  assert(readFile(oldDir + "/old.fmb") == "old-map-block");
  assert(!exists(root + "/VECTMAP/+0032+0008/123_456.fmb"));
  std::string activeMapId;
  auto active = installer.readActiveMapId(activeMapId);
  assert(active.ok);
  assert(activeMapId == "map-old");
  assert(exists(root + "/VECTMAP/.staging/" + session));
}

static void testRejectsChecksumMismatch() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string session = "session-2";
  const std::string stagedDir =
      root + "/VECTMAP/.staging/" + session + "/VECTMAP/map-2/+0032+0008";
  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  writeFile(stagedDir + "/123_456.fmb", "actual-data");
  const std::string manifestText =
      "{\"schemaVersion\":1,\"mapId\":\"map-2\",\"files\":[{\"path\":\"VECTMAP/"
      "map-2/+0032+0008/123_456.fmb\",\"bytes\":11,\"sha256\":\"" +
      sha("different") + "\"}]}";
  writeFile(root + "/VECTMAP/.staging/" + session + "/manifest.json",
            manifestText);

  MapManifest manifest;
  auto validated = installer.validateStagedMap(session, manifest);
  assert(!validated.ok);
  assert(validated.code == "file_sha256");
}

int main() {
  testSha256KnownVector();
  testActivationStateTracksAttemptsAndCompactStatus();
  testRejectsUnsafeManifestPath();
  testRejectsPathOutsideMapNamespace();
  testValidatesStagedMapAndActivates();
  testActivationReplacesOldPublishedBlocks();
  testActivationRestoresOldMapWhenMetadataWriteFails();
  testRejectsChecksumMismatch();
  std::cout << "map_transfer tests passed\n";
  return 0;
}
