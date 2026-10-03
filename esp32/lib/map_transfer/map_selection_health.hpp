#pragma once
#include <cstdint>
#include <string>

namespace map_transfer {
// Boot-scoped live renderer evidence, deliberately independent of durable receipts.
// The owner serializes access. One current identity and one affected operation are
// retained: runtime failures cannot grow a history or mutate Installed receipts.
struct MapSelectionHealth {
  uint64_t revision = 0;
  std::string state = "unknown";
  std::string root, operationID, mapID, sessionID, affectedOperationID;

  void select(const std::string &newRoot, const std::string &operation,
              const std::string &map, const std::string &session, bool ready,
              bool preserveAffected = false) {
    root = newRoot; operationID = operation; mapID = map; sessionID = session;
    state = ready ? "ready" : "unknown";
    if (!preserveAffected) affectedOperationID.clear();
    ++revision;
  }
  bool degrade(const std::string &expectedRoot) {
    if (root.empty() || root != expectedRoot || state != "ready") return false;
    affectedOperationID = operationID; state = "degraded"; ++revision; return true;
  }
  void beginRollback() {
    if (state == "degraded") { state = "rolling_back"; ++revision; }
  }
  bool acknowledge(const std::string &expectedRoot, bool loaded) {
    if (root != expectedRoot || state != "unknown") return false;
    state = loaded ? "ready" : "rollback_failed"; ++revision; return true;
  }
  void failRollback() { state = "rollback_failed"; ++revision; }
};
} // namespace map_transfer
