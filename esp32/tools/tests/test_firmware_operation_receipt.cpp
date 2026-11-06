#include "../../lib/firmware_update/firmware_operation_receipt.hpp"
#include <cassert>
#include <array>
using namespace firmware_update::receipt;
struct Memory final:Storage {
  std::array<Record,2> values{};
  std::array<bool,2> present{};
  int writes=0;
  bool fail=false, ambiguous=false, unreadable=false;
  int read(unsigned slot,Record &r) override { if(unreadable) return -1; r=values[slot]; return present[slot]?1:0; }
  bool write(unsigned slot,const Record &r) override {
    ++writes;
    if(!fail || ambiguous) { values[slot]=r; present[slot]=true; }
    return !fail;
  }
};
Record input(char id='a') {
  Record r;
  std::memset(r.device,'1',32); std::memset(r.operation,id,32); std::memset(r.image,'b',64);
  r.partitionAddress=0x310000; r.imageBytes=1800000; return r;
}
int main() {
  Memory io; Store s(io); assert(s.restore());
  auto a=input(); assert(s.accept(a)); assert(io.writes==1);
  assert(s.accept(a)); assert(io.writes==1); // lost finalize response replay is read-only
  Store reboot(io); assert(reboot.restore()); assert(reboot.current().phase==Phase::Accepted);
  assert(!reboot.accept(input('c'))); // accepted cannot be evicted
  assert(!reboot.acknowledge(a.device,a.operation,a.image));
  assert(reboot.finish(true)); assert(io.writes==2);
  assert(reboot.finish(true)); assert(io.writes==2); // no writes on status/boot rechecks
  assert(!reboot.accept(input('c'))); // terminal receipt retained
  auto wrong=a; wrong.image[0]='f';
  assert(!reboot.acknowledge(a.device,a.operation,wrong.image));
  assert(reboot.acknowledge(a.device,a.operation,a.image)); assert(io.writes==3);
  assert(reboot.acknowledge(a.device,a.operation,a.image)); assert(io.writes==3);
  assert(!reboot.accept(a)); // most recent tombstone
  assert(reboot.accept(input('c'))); assert(reboot.current().revision==4);
  assert(reboot.finish(false)); assert(reboot.current().phase==Phase::Failed);
  // Every transition write can fail before or after durable commit. No false success.
  for(bool ambiguous:{false,true}) for(int step=0;step<3;++step) {
    Memory fault; Store live(fault); assert(live.restore());
    if(step>0) assert(live.accept(a));
    if(step>1) assert(live.finish(true));
    fault.fail=true; fault.ambiguous=ambiguous;
    bool result=step==0?live.accept(a):step==1?live.finish(true):live.acknowledge(a.device,a.operation,a.image);
    assert(!result);
    assert(!live.accept(input('e'))); // poisoned owner cannot continue
    fault.fail=false;
    for(int retry=0;retry<3;++retry) {
      Store recovered(fault); assert(recovered.restore());
      auto expected=step==0?Phase::Empty:step==1?Phase::Accepted:Phase::Installed;
      if(ambiguous) expected=step==0?Phase::Accepted:step==1?Phase::Installed:Phase::Acknowledged;
      assert(recovered.current().phase==expected);
    }
  }
  Memory corrupt; Store c(corrupt); assert(c.restore()); assert(c.accept(a)); assert(c.finish(true));
  corrupt.values[0].checksum^=1; Store torn(corrupt); assert(!torn.restore()); assert(!torn.accept(a));
  Memory failure; failure.unreadable=true; Store f(failure); assert(!f.restore());
  auto invalid=input(); invalid.operation[0]='G'; Memory fresh; Store bad(fresh); assert(bad.restore()); assert(!bad.accept(invalid));
  // An Accepted receipt survives USB recovery and the layout migration in NVS.
  // Legacy app1 (0x310000) is not a dual-4-MiB slot start, and app0 holds the
  // USB-written image afterwards: both resolve to Failed once that image runs.
  static_assert(reconcileAction(false,false,true)==ReconcileAction::Fail);
  static_assert(reconcileAction(false,false,false)==ReconcileAction::Keep);
  static_assert(reconcileAction(true,false,true)==ReconcileAction::Fail);
  // A pending-verify OTA boot must still prove its exact bytes (rollback kept).
  static_assert(reconcileAction(true,false,false)==ReconcileAction::Unresolved);
  static_assert(reconcileAction(true,true,false)==ReconcileAction::Keep);
  static_assert(reconcileAction(true,true,true)==ReconcileAction::Install);
  Memory migrated; Store m(migrated); assert(m.restore()); assert(m.accept(input('d')));
  assert(m.finish(reconcileAction(true,false,true)==ReconcileAction::Install));
  assert(m.current().phase==Phase::Failed);
  assert(m.acknowledge(m.current().device,m.current().operation,m.current().image));
  assert(m.accept(input('e'))); // a later OTA is admitted again
}
