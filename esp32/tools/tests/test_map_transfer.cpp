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
using map_transfer::ActiveMapSelection;
using map_transfer::Sha256Hasher;
using map_transfer::sha256Hex;

class MetadataWriteFailingInstaller : public MapTransferInstaller {
public:
  using MapTransferInstaller::MapTransferInstaller;

protected:
  bool writeTextFileAtomic(const std::string &path,
                           const std::string &text) const override {
    constexpr const char *activeSuffix = "/VECTMAP/active-map.json";
    constexpr size_t activeSuffixLength = 24;
    if (path.size() >= activeSuffixLength &&
        path.rfind(activeSuffix) == path.size() - activeSuffixLength) {
      return false;
    }
    return MapTransferInstaller::writeTextFileAtomic(path, text);
  }
};

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

static void prepareInterruptedSelectedVersion(const std::string &root,
                                              const std::string &blockData) {
  MapTransferInstaller installer(root);
  const std::string vectmap = root + "/VECTMAP";
  const std::string oldRoot = vectmap + "/.maps/session-old";
  const std::string stagedDir =
      vectmap + "/.staging/session-commit/VECTMAP/map-new/+0032+0008";
  assert(::system((std::string("mkdir -p ") + oldRoot).c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  writeFile(oldRoot + "/old.fmb", "old");
  writeFile(vectmap + "/active-map.json",
            "{\"mapId\":\"map-old\",\"sessionId\":\"session-old\","
            "\"root\":\"/VECTMAP/.maps/session-old\"}\n");
  writeFile(stagedDir + "/new.fmb", blockData);
  writeFile(vectmap + "/.staging/session-commit/manifest.json",
            "{\"schemaVersion\":1,\"mapId\":\"map-new\",\"files\":[{"
            "\"path\":\"VECTMAP/map-new/+0032+0008/new.fmb\",\"bytes\":" +
                std::to_string(blockData.size()) + ",\"sha256\":\"" +
                sha(blockData) + "\"}]}\n");
  MapManifest manifest;
  assert(installer.validateStagedMap("session-commit", manifest).ok);
  assert(installer.activateStagedMap("session-commit", manifest).ok);
  writeFile(vectmap + "/.activation-transaction.json",
            "{\"sessionId\":\"session-commit\",\"mapId\":\"map-new\","
            "\"root\":\"/VECTMAP/.maps/session-commit\","
            "\"previousMapId\":\"map-old\","
            "\"previousSessionId\":\"session-old\","
            "\"previousRoot\":\"/VECTMAP/.maps/session-old\","
            "\"phase\":\"ready\"}\n");
}

static void testSha256KnownVector() {
  assert(sha("abc") ==
         "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  Sha256Hasher streaming;
  streaming.update(reinterpret_cast<const uint8_t *>("a"), 1);
  streaming.update(reinterpret_cast<const uint8_t *>("bc"), 2);
  assert(streaming.finalHex() ==
         "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

static void testActivationStateTracksAttemptsAndCompactStatus() {
  MapActivationState state;
  auto initial = state.snapshot();
  assert(!initial.running);
  assert(initial.sequence == 0);
  assert(initial.status == "idle");
  assert(state.acceptsUploads());

  assert(state.begin("session-1") == ActivationBeginResult::Started);
  assert(!state.acceptsUploads());
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
  assert(state.acceptsUploads());
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
  struct stat stagedStat;
  assert(::stat((stagedDir + "/123_456.fmb").c_str(), &stagedStat) == 0);

  auto activated = installer.activateStagedMap(session, manifest);
  assert(activated.ok);
  const std::string installed = root + "/VECTMAP/.maps/" + session +
                                "/+0032+0008/123_456.fmb";
  assert(exists(installed));
  assert(readFile(installed) == blockData);
  struct stat installedStat;
  assert(::stat(installed.c_str(), &installedStat) == 0);
  assert(stagedStat.st_ino == installedStat.st_ino);
  ActiveMapSelection selection;
  auto active = installer.readActiveMap(selection);
  assert(active.ok);
  assert(selection.mapId == "map-1");
  assert(selection.sessionId == session);
  assert(selection.root == "/VECTMAP/.maps/session-1");
  assert(selection.previousRoot.empty());
  assert(!exists(root + "/VECTMAP/.staging/" + session));
  assert(!exists(root + "/VECTMAP/.activation-transaction.json"));

  // Repeating a request whose staging directory was already cleaned is
  // idempotent because the content-derived version is active.
  auto repeated = installer.activateStagedMap(session, manifest);
  assert(repeated.ok);
}

static void testActivationSwitchesPointerAndRetainsPreviousVersion() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string session = "session-replace";
  const std::string oldDir =
      root + "/VECTMAP/.maps/session-old/+9999+9999";
  const std::string stagedDir =
      root + "/VECTMAP/.staging/" + session + "/VECTMAP/map-new/+0032+0008";
  assert(::system((std::string("mkdir -p ") + oldDir).c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  writeFile(oldDir + "/old.fmb", "old-map-block");
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"mapId\":\"map-old\",\"sessionId\":\"session-old\","
            "\"root\":\"/VECTMAP/.maps/session-old\"}\n");

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
  assert(readFile(oldDir + "/old.fmb") == "old-map-block");
  const std::string installed = root + "/VECTMAP/.maps/" + session +
                                "/+0032+0008/123_456.fmb";
  assert(readFile(installed) == blockData);
  ActiveMapSelection selection;
  auto active = installer.readActiveMap(selection);
  assert(active.ok);
  assert(selection.mapId == "map-new");
  assert(selection.root == "/VECTMAP/.maps/session-replace");
  assert(selection.previousMapId == "map-old");
  assert(selection.previousRoot == "/VECTMAP/.maps/session-old");
}

static void testSameSessionRetryRepairsDamagedInstalledVersion() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string session = "session-repair";
  const std::string stagedDir =
      root + "/VECTMAP/.staging/" + session + "/VECTMAP/map-1/+0032+0008";
  const std::string blockData = "map-block";
  const std::string manifestText =
      "{\"schemaVersion\":1,\"mapId\":\"map-1\",\"files\":[{"
      "\"path\":\"VECTMAP/map-1/+0032+0008/123_456.fmb\",\"bytes\":9,"
      "\"sha256\":\"" +
      sha(blockData) + "\"}]}";

  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  writeFile(stagedDir + "/123_456.fmb", blockData);
  writeFile(root + "/VECTMAP/.staging/" + session + "/manifest.json",
            manifestText);
  MapManifest manifest;
  assert(installer.validateStagedMap(session, manifest).ok);
  assert(installer.activateStagedMap(session, manifest).ok);

  const std::string originalRoot = root + "/VECTMAP/.maps/" + session;
  writeFile(originalRoot + "/+0032+0008/123_456.fmb", "bad-block");
  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  writeFile(stagedDir + "/123_456.fmb", blockData);
  writeFile(root + "/VECTMAP/.staging/" + session + "/manifest.json",
            manifestText);
  assert(installer.validateStagedMap(session, manifest).ok);

  auto repaired = installer.activateStagedMap(session, manifest);
  assert(repaired.ok);
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.sessionId == session);
  assert(selected.root != "/VECTMAP/.maps/" + session);
  assert(readFile(root + selected.root + "/+0032+0008/123_456.fmb") ==
         blockData);
}

static void testActivationRestoresOldMapWhenMetadataWriteFails() {
  std::string root = tempRoot();
  MetadataWriteFailingInstaller installer(root);
  const std::string session = "session-rollback";
  const std::string oldDir =
      root + "/VECTMAP/.maps/session-old/+9999+9999";
  const std::string stagedDir =
      root + "/VECTMAP/.staging/" + session + "/VECTMAP/map-new/+0032+0008";
  assert(::system((std::string("mkdir -p ") + oldDir).c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  writeFile(oldDir + "/old.fmb", "old-map-block");
  const std::string activePath = root + "/VECTMAP/active-map.json";
  writeFile(activePath,
            "{\"mapId\":\"map-old\",\"sessionId\":\"session-old\","
            "\"root\":\"/VECTMAP/.maps/session-old\"}\n");

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
  assert(!exists(root + "/VECTMAP/.maps/" + session));
  std::string activeMapId;
  auto active = installer.readActiveMapId(activeMapId);
  assert(active.ok);
  assert(activeMapId == "map-old");
  assert(!exists(root + "/VECTMAP/.staging/" + session));
  assert(!exists(root + "/VECTMAP/.activation-transaction.json"));
}

static void testPrunesAbandonedStagingSessions() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string staging = root + "/VECTMAP/.staging";
  assert(::system((std::string("mkdir -p ") + staging + "/keep").c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + staging + "/abandoned").c_str()) == 0);
  writeFile(staging + "/keep/manifest.json", "keep");
  writeFile(staging + "/abandoned/block.fmb", "old");

  assert(installer.pruneStagingSessions("keep"));
  assert(exists(staging + "/keep/manifest.json"));
  assert(!exists(staging + "/abandoned"));
}

static void testPrunesPreviousAndObsoleteVersionsBeforeNextUpload() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string maps = root + "/VECTMAP/.maps";
  assert(::system((std::string("mkdir -p ") + maps + "/current").c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + maps + "/previous").c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + maps + "/obsolete").c_str()) == 0);
  writeFile(maps + "/current/map.fmb", "current");
  writeFile(maps + "/previous/map.fmb", "previous");
  writeFile(maps + "/obsolete/map.fmb", "obsolete");
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"mapId\":\"map-current\",\"sessionId\":\"current\","
            "\"root\":\"/VECTMAP/.maps/current\","
            "\"previousMapId\":\"map-previous\","
            "\"previousSessionId\":\"previous\","
            "\"previousRoot\":\"/VECTMAP/.maps/previous\"}\n");

  assert(installer.pruneObsoleteInstalledMaps());
  assert(exists(maps + "/current/map.fmb"));
  assert(!exists(maps + "/previous"));
  assert(!exists(maps + "/obsolete"));
}

static void testPrunesLegacyRollbackAfterVersionedMapIsActive() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string vectmap = root + "/VECTMAP";
  assert(::system((std::string("mkdir -p ") +
                   vectmap + "/.maps/current/+0032+0008")
                      .c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + vectmap + "/+9999+9999")
                      .c_str()) == 0);
  writeFile(vectmap + "/.maps/current/+0032+0008/new.fmb", "new");
  writeFile(vectmap + "/+9999+9999/old.fmb", "old");
  writeFile(vectmap + "/active-map.json",
            "{\"mapId\":\"map-current\",\"sessionId\":\"current\","
            "\"root\":\"/VECTMAP/.maps/current\","
            "\"previousMapId\":\"map-legacy\","
            "\"previousRoot\":\"/VECTMAP\"}\n");

  assert(installer.pruneObsoleteInstalledMaps());
  assert(exists(vectmap + "/.maps/current/+0032+0008/new.fmb"));
  assert(!exists(vectmap + "/+9999+9999"));
  assert(exists(vectmap + "/active-map.json"));
}

static void testRollsBackInterruptedVersionPublish() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string vectmap = root + "/VECTMAP";
  const std::string oldRoot = vectmap + "/.maps/session-old";
  const std::string newRoot = vectmap + "/.maps/session-new";
  const std::string staging = vectmap + "/.staging/session-new";
  assert(::system((std::string("mkdir -p ") + oldRoot).c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + newRoot).c_str()) == 0);
  assert(::system((std::string("mkdir -p ") + staging).c_str()) == 0);
  writeFile(oldRoot + "/old.fmb", "old");
  writeFile(newRoot + "/partial.fmb", "partial");
  writeFile(staging + "/manifest.json", "partial");
  writeFile(vectmap + "/active-map.json",
            "{\"mapId\":\"map-old\",\"sessionId\":\"session-old\","
            "\"root\":\"/VECTMAP/.maps/session-old\"}\n");
  writeFile(vectmap + "/.activation-transaction.json",
            "{\"sessionId\":\"session-new\",\"mapId\":\"map-new\","
            "\"root\":\"/VECTMAP/.maps/session-new\","
            "\"previousMapId\":\"map-old\","
            "\"previousSessionId\":\"session-old\","
            "\"previousRoot\":\"/VECTMAP/.maps/session-old\","
            "\"phase\":\"publishing\"}\n");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  assert(readFile(oldRoot + "/old.fmb") == "old");
  assert(!exists(newRoot));
  assert(!exists(staging));
  std::string activeMapId;
  assert(installer.readActiveMapId(activeMapId).ok);
  assert(activeMapId == "map-old");
  assert(!exists(vectmap + "/.activation-transaction.json"));
}

static void testCompletesPointerSwitchInterruptedBeforeJournalCommit() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string vectmap = root + "/VECTMAP";
  const std::string newRoot = vectmap + "/.maps/session-commit";
  const std::string oldRoot = vectmap + "/.maps/session-old";
  prepareInterruptedSelectedVersion(root, "new");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_commit");
  assert(readFile(newRoot + "/+0032+0008/new.fmb") == "new");
  assert(readFile(oldRoot + "/old.fmb") == "old");
  std::string activeMapId;
  assert(installer.readActiveMapId(activeMapId).ok);
  assert(activeMapId == "map-new");
}

static void testJournalRecoveryRollsBackPartialSelectedVersion() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  prepareInterruptedSelectedVersion(root, "new-map-data");
  const std::string installed =
      root + "/VECTMAP/.maps/session-commit/+0032+0008/new.fmb";
  assert(::unlink(installed.c_str()) == 0);

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.mapId == "map-old");
  assert(!exists(root + "/VECTMAP/.maps/session-commit"));
}

static void testJournalRecoveryRollsBackSameSizeCorruptSelectedVersion() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  prepareInterruptedSelectedVersion(root, "good");
  writeFile(root + "/VECTMAP/.maps/session-commit/+0032+0008/new.fmb",
            "evil");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.mapId == "map-old");
  assert(!exists(root + "/VECTMAP/.maps/session-commit"));
}

static void testJournalRecoveryRollsBackMissingSelectedVersion() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string vectmap = root + "/VECTMAP";
  const std::string oldRoot = vectmap + "/.maps/session-old";
  assert(::system((std::string("mkdir -p ") + oldRoot).c_str()) == 0);
  writeFile(oldRoot + "/old.fmb", "old");
  writeFile(vectmap + "/active-map.json",
            "{\"mapId\":\"map-new\",\"sessionId\":\"session-new\","
            "\"root\":\"/VECTMAP/.maps/session-new\","
            "\"previousMapId\":\"map-old\","
            "\"previousSessionId\":\"session-old\","
            "\"previousRoot\":\"/VECTMAP/.maps/session-old\"}\n");
  writeFile(vectmap + "/.activation-transaction.json",
            "{\"sessionId\":\"session-new\",\"mapId\":\"map-new\","
            "\"root\":\"/VECTMAP/.maps/session-new\","
            "\"previousMapId\":\"map-old\","
            "\"previousSessionId\":\"session-old\","
            "\"previousRoot\":\"/VECTMAP/.maps/session-old\","
            "\"phase\":\"ready\"}\n");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.mapId == "map-old");
  assert(selected.root == "/VECTMAP/.maps/session-old");
  assert(readFile(oldRoot + "/old.fmb") == "old");
  assert(!exists(vectmap + "/.activation-transaction.json"));
}

static void testMissingSelectedVersionRestoresPreviousPointer() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string previousRoot = root + "/VECTMAP/.maps/session-old";
  assert(::system((std::string("mkdir -p ") + previousRoot).c_str()) == 0);
  writeFile(previousRoot + "/old.fmb", "old");
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"mapId\":\"map-new\",\"sessionId\":\"session-new\","
            "\"root\":\"/VECTMAP/.maps/session-new\","
            "\"previousMapId\":\"map-old\","
            "\"previousSessionId\":\"session-old\","
            "\"previousRoot\":\"/VECTMAP/.maps/session-old\"}\n");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.mapId == "map-old");
  assert(selected.root == "/VECTMAP/.maps/session-old");
}

static void testMissingFirstInstallVersionClearsSelection() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  assert(::system((std::string("mkdir -p ") + root + "/VECTMAP").c_str()) == 0);
  writeFile(root + "/VECTMAP/active-map.json",
            "{\"mapId\":\"map-new\",\"sessionId\":\"session-new\","
            "\"root\":\"/VECTMAP/.maps/session-new\"}\n");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  auto active = installer.readActiveMap(selected);
  assert(!active.ok);
  assert(active.code == "active_missing");
  assert(installer.recoverInterruptedActivation().ok);
}

static void testJournalRecoveryRestoresPreviousFromCorruptActiveMetadata() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string vectmap = root + "/VECTMAP";
  const std::string previousRoot = vectmap + "/.maps/session-old";
  assert(::system((std::string("mkdir -p ") + previousRoot).c_str()) == 0);
  writeFile(previousRoot + "/old.fmb", "old");
  writeFile(vectmap + "/active-map.json", "{not-json}\n");
  writeFile(vectmap + "/.activation-transaction.json",
            "{\"sessionId\":\"session-new\",\"mapId\":\"map-new\","
            "\"root\":\"/VECTMAP/.maps/session-new\","
            "\"previousMapId\":\"map-old\","
            "\"previousSessionId\":\"session-old\","
            "\"previousRoot\":\"/VECTMAP/.maps/session-old\","
            "\"phase\":\"publishing\"}\n");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.mapId == "map-old");
  assert(selected.root == "/VECTMAP/.maps/session-old");
}

static void testJournalRecoveryClearsCorruptFirstInstallMetadata() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string vectmap = root + "/VECTMAP";
  assert(::system((std::string("mkdir -p ") +
                   vectmap + "/.maps/session-new").c_str()) == 0);
  writeFile(vectmap + "/.maps/session-new/partial.fmb", "partial");
  writeFile(vectmap + "/active-map.json", "{not-json}\n");
  writeFile(vectmap + "/.activation-transaction.json",
            "{\"sessionId\":\"session-new\",\"mapId\":\"map-new\","
            "\"root\":\"/VECTMAP/.maps/session-new\",\"phase\":"
            "\"publishing\"}\n");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  auto active = installer.readActiveMap(selected);
  assert(!active.ok);
  assert(active.code == "active_missing");
  assert(!exists(vectmap + "/.maps/session-new"));
  assert(!exists(vectmap + "/.activation-transaction.json"));
  assert(installer.recoverInterruptedActivation().ok);
}

static void testRecoveryClearsCorruptMetadataWithoutJournal() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  assert(::system((std::string("mkdir -p ") + root + "/VECTMAP").c_str()) == 0);
  writeFile(root + "/VECTMAP/active-map.json", "{not-json}\n");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  auto active = installer.readActiveMap(selected);
  assert(!active.ok);
  assert(active.code == "active_missing");
}

static void testRecoveryClearsCorruptJournalWithoutBlockingActiveMap() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  prepareInterruptedSelectedVersion(root, "new");
  writeFile(root + "/VECTMAP/.activation-transaction.json", "{not-json}\n");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_commit");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.mapId == "map-new");
  assert(readFile(root + selected.root + "/+0032+0008/new.fmb") == "new");
  assert(!exists(root + "/VECTMAP/.activation-transaction.json"));
}

static void testCorruptJournalRollsBackUnverifiableSelectedMap() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  prepareInterruptedSelectedVersion(root, "good");
  writeFile(root + "/VECTMAP/.maps/session-commit/+0032+0008/new.fmb",
            "evil");
  writeFile(root + "/VECTMAP/.activation-transaction.json", "{not-json}\n");

  auto recovered = installer.recoverInterruptedActivation();
  assert(recovered.ok);
  assert(recovered.code == "recovered_rollback");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.mapId == "map-old");
  assert(!exists(root + "/VECTMAP/.maps/session-commit"));
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

static void testVerificationReceiptControlsResumeEligibility() {
  std::string root = tempRoot();
  MapTransferInstaller installer(root);
  const std::string session = "session-receipt";
  const std::string stagedDir =
      root + "/VECTMAP/.staging/" + session + "/VECTMAP/map-1/+0032+0008";
  assert(::system((std::string("mkdir -p ") + stagedDir).c_str()) == 0);
  const std::string path = "VECTMAP/map-1/+0032+0008/123_456.fmb";
  const std::string blockData = "verified-map-block";
  writeFile(stagedDir + "/123_456.fmb", blockData);
  writeFile(root + "/VECTMAP/.staging/" + session + "/manifest.json",
            "{\"schemaVersion\":1,\"mapId\":\"map-1\",\"files\":[{"
            "\"path\":\"" + path + "\",\"bytes\":" +
                std::to_string(blockData.size()) + ",\"sha256\":\"" +
                sha(blockData) + "\"}]}\n");

  map_transfer::ManifestFile expected;
  assert(installer.expectedStagedFile(session, path, expected).ok);
  assert(!installer.stagedFileVerified(session, expected));
  assert(installer.markStagedFileVerified(session, expected));
  assert(installer.stagedFileVerified(session, expected));
  installer.clearStagedFileVerification(session, expected);
  assert(!installer.stagedFileVerified(session, expected));

  MapManifest manifest;
  assert(installer.validateStagedMap(session, manifest).ok);
  assert(installer.stagedFileVerified(session, manifest.files[0]));
}

int main() {
  testSha256KnownVector();
  testActivationStateTracksAttemptsAndCompactStatus();
  testRejectsUnsafeManifestPath();
  testRejectsPathOutsideMapNamespace();
  testValidatesStagedMapAndActivates();
  testActivationSwitchesPointerAndRetainsPreviousVersion();
  testSameSessionRetryRepairsDamagedInstalledVersion();
  testActivationRestoresOldMapWhenMetadataWriteFails();
  testPrunesAbandonedStagingSessions();
  testPrunesPreviousAndObsoleteVersionsBeforeNextUpload();
  testPrunesLegacyRollbackAfterVersionedMapIsActive();
  testRollsBackInterruptedVersionPublish();
  testCompletesPointerSwitchInterruptedBeforeJournalCommit();
  testJournalRecoveryRollsBackPartialSelectedVersion();
  testJournalRecoveryRollsBackSameSizeCorruptSelectedVersion();
  testJournalRecoveryRollsBackMissingSelectedVersion();
  testMissingSelectedVersionRestoresPreviousPointer();
  testMissingFirstInstallVersionClearsSelection();
  testJournalRecoveryRestoresPreviousFromCorruptActiveMetadata();
  testJournalRecoveryClearsCorruptFirstInstallMetadata();
  testRecoveryClearsCorruptMetadataWithoutJournal();
  testRecoveryClearsCorruptJournalWithoutBlockingActiveMap();
  testCorruptJournalRollsBackUnverifiableSelectedMap();
  testRejectsChecksumMismatch();
  testVerificationReceiptControlsResumeEligibility();
  std::cout << "map_transfer tests passed\n";
  return 0;
}
