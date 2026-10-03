#include "map_selection_health.hpp"
#include "durable_operation.hpp"
#include <cassert>

int main() {
  using map_transfer::MapSelectionHealth;
  namespace op = device_transfer::durable_operation;
  op::Record historical;
  historical.identity.operation = "installed-operation";
  historical.phase = op::Phase::Installed;
  historical.revision = 9;
  MapSelectionHealth health;
  health.select("/maps/new",historical.identity.operation,"new-map","new-session",true);
  assert(health.revision == 1 && health.state == "ready");
  assert(!health.degrade("/maps/stale"));
  assert(health.degrade("/maps/new"));
  assert(health.state == "degraded" && health.affectedOperationID == historical.identity.operation);
  health.beginRollback();
  assert(health.state == "rolling_back");
  health.select("/maps/old","old-operation","old-map","old-session",false,true);
  const auto revision = health.revision;
  assert(!health.acknowledge("/maps/new",true));
  assert(health.revision == revision && health.state == "unknown");
  assert(health.acknowledge("/maps/old",true));
  assert(health.state == "ready" && health.operationID == "old-operation");
  assert(health.affectedOperationID == historical.identity.operation);
  assert(!health.acknowledge("/maps/old",false)); // duplicate cannot regress ready
  assert(historical.phase == op::Phase::Installed && historical.revision == 9);
  assert(health.degrade("/maps/old"));
  health.beginRollback(); health.failRollback();
  assert(health.state == "rollback_failed");
  assert(!health.acknowledge("/maps/old",true)); // late ACK cannot erase failure
  assert(historical.phase == op::Phase::Installed && historical.revision == 9);
  health.select("/maps/replacement","replacement-operation","replacement","session",true);
  assert(health.affectedOperationID.empty());
}
