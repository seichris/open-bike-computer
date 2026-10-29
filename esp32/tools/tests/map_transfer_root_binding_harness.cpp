// The production MapTransferHttpServer root binding and boot-selection health
// methods are inserted by test_sd_only_map_storage.py and run against the real
// operation journal and selection health on argv[1], which stands in for the
// card. setup() binds the root as soon as storage is pinned, so boot recovery
// resolves the journaled operation of the selection it reports to the app.
#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include "../../lib/map_transfer/map_operation_journal.hpp"
#include "../../lib/map_transfer/map_selection_health.hpp"

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,    \
                   #condition);                                                \
      std::exit(42);                                                           \
    }                                                                          \
  } while (0)

namespace map_transfer {
struct ActiveMapSelection {
  std::string mapId, sessionId, root, manifestReceipt, signedManifestReceipt;
};

// Records the root and identity the server bound its installer to.
class MapTransferInstaller {
public:
  explicit MapTransferInstaller(std::string root) : root(std::move(root)) {}
  void setOperationDeviceID(const std::string &device) { deviceID = device; }
  std::string root, deviceID;
};

class MapTransferHttpServer {
public:
  void bindStorageRoot(std::string storageRoot);
  void observeBootSelection(const ActiveMapSelection &selected, bool loaded,
                            bool preserveAffected = false);
  std::string selectionOperationID(const ActiveMapSelection &selected) const;
  struct StateGuard {
    explicit StateGuard(const MapTransferHttpServer &) {}
  };
  struct OperationStoreGuard {
    explicit OperationStoreGuard(const MapTransferHttpServer &) {}
  };
  std::string storageRoot_;
  std::string operationDeviceID_;
  MapSelectionHealth selectionHealth_;
  MapTransferInstaller installer_{std::string()};
};

// PRODUCTION_SERVER
} // namespace map_transfer

using namespace map_transfer;

int main(int argc, char **argv) {
  CHECK(argc == 2);
  const std::string card = argv[1];
  CHECK(::mkdir((card + "/VECTMAP").c_str(), 0755) == 0);

  // An installed map whose activation the renderer acknowledged.
  const std::string device(32, 'a');
  const operation::Identity id{device, std::string(32, '1'),
                               std::string(64, 'b'), std::string(64, 'c'),
                               std::string(64, 'd'), 100, "session", "map"};
  MapOperationStorage journal(card);
  operation::Store store(journal, device);
  CHECK(store.restore() == operation::Result::Ok);
  CHECK(store.initializeAdmission(1) == operation::Result::Ok);
  CHECK(store.admit(id, store.admissionRevision()) == operation::Result::Ok);
  CHECK(store.prepare(id) == operation::Result::Ok);
  CHECK(store.accept(id) == operation::Result::Ok);
  CHECK(store.rendererAcknowledged(id, id.manifest, id.signedManifest) ==
        operation::Result::Ok);
  const ActiveMapSelection selected{"map", "session", "/VECTMAP/.maps/session",
                                    id.manifest, id.signedManifest};

  // setup(): the identity and the pinned card root are bound before boot
  // recovery reports the selection.
  MapTransferHttpServer server;
  server.operationDeviceID_ = device;
  server.bindStorageRoot(card + "/");
  CHECK(server.storageRoot_ == card && server.installer_.root == card);
  CHECK(server.installer_.deviceID == device);
  server.observeBootSelection(selected, true);
  CHECK(server.selectionHealth_.operationID == id.operation);
  CHECK(server.selectionHealth_.state == "ready");

  // A selection that fails its boot probe names the affected operation, which
  // the app needs to keep an unconfirmed map hidden.
  server.observeBootSelection(selected, false);
  CHECK(server.selectionHealth_.affectedOperationID == id.operation);
  CHECK(server.selectionHealth_.state == "rollback_failed");

  // Bound to another root, such as the no-card sentinel, nothing on the card
  // is read.
  MapTransferHttpServer elsewhere;
  elsewhere.operationDeviceID_ = device;
  elsewhere.bindStorageRoot(card + "/missing");
  elsewhere.observeBootSelection(selected, true);
  CHECK(elsewhere.selectionHealth_.operationID.empty());
  std::puts("map transfer root binding harness passed");
  return 0;
}
