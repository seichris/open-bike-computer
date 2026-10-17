#include "../../lib/device_transfer/durable_operation.hpp"
#include "../../lib/device_transfer/operation_admission_policy.hpp"
#include <cassert>
#include <iostream>
using namespace device_transfer::durable_operation;
struct MemoryStorage : Storage {
  std::array<std::vector<uint8_t>,2> slots;
  bool failWrite=false, loseResponse=false;
  size_t prefix=0;
  bool read(unsigned slot,std::vector<uint8_t> &bytes) override { bytes=slots[slot]; return true; }
  bool writeDurable(unsigned slot,const std::vector<uint8_t> &bytes) override {
    if(failWrite) { slots[slot].assign(bytes.begin(),bytes.begin()+std::min(prefix,bytes.size())); return false; }
    slots[slot]=bytes; return !loseResponse;
  }
};
Identity identity(char operation='1') {
  return {std::string(32,'a'),std::string(32,operation),std::string(64,'b'),
          std::string(64,'c'),std::string(64,'d'),500,"session-1","map-1"};
}
int main() {
  AdmissionFence epoch(std::string(32,'a'));
  assert(epoch.observe(10));
  assert(epoch.permits(std::string(32,'a'),10));
  assert(!epoch.permits(std::string(32,'b'),10));
  assert(!epoch.permits(std::string(32,'a'),9));
  assert(!epoch.observe(9)); // old SD snapshot cannot lower a live-boot floor
  AdmissionFence reboot(std::string(32,'b'));
  assert(reboot.observe(10));
  assert(!reboot.permits(std::string(32,'a'),10)); // old request cannot revive missing ID

  MemoryStorage io;
  Store store(io,std::string(32,'a')); auto id=identity(); Record record;
  assert(store.restore()==Result::Ok);
  assert(store.initializeAdmission(100)==Result::Ok);
  assert(store.query(id,record)==Result::Unavailable);
  assert(store.admit(id,store.admissionRevision())==Result::Ok);
  assert(store.accept(id)==Result::NotAccepted);
  assert(store.rendererAcknowledged(id,id.manifest,id.signedManifest)==Result::NotAccepted);
  assert(store.prepare(id)==Result::Ok);
  assert(store.accept(id)==Result::Ok);
  assert(store.cancel(id)==Result::TooLate);
  assert(store.rendererAcknowledged(id,std::string(64,'e'),id.signedManifest)==Result::SelectionMismatch);
  assert(store.rendererAcknowledged(id,id.manifest,id.signedManifest)==Result::Ok);
  assert(store.admit(id,store.admissionRevision())==Result::Replay);
  auto conflict=id; conflict.streamBytes++;
  assert(store.admit(conflict,store.admissionRevision())==Result::Conflict);
  Store restarted(io,std::string(32,'a')); assert(restarted.restore()==Result::Ok);
  assert(restarted.query(id,record)==Result::Ok && record.phase==Phase::Installed);
  Store movedCard(io,std::string(32,'f')); assert(movedCard.restore()==Result::ForeignDevice);
  assert(restarted.acknowledgeResult(id)==Result::Ok);
  assert(restarted.admit(id,restarted.admissionRevision())==Result::Unavailable);
  for(char c='2'; c<='4';++c) assert(restarted.admit(identity(c),restarted.admissionRevision())==Result::Ok);
  assert(restarted.admit(identity('5'),restarted.admissionRevision())==Result::Ok); // acknowledged slot reusable
  assert(restarted.admit(identity('6'),restarted.admissionRevision())==Result::Busy);
  assert(restarted.admit(id,0)==Result::Unavailable); // evicted original creation token
  assert(restarted.query(id,record)==Result::Unavailable);
  MemoryStorage admissionStorage; Store bounded(admissionStorage,std::string(32,'a'));
  assert(bounded.restore()==Result::Ok);
  assert(bounded.initializeAdmission(100)==Result::Ok);
  const auto creation=bounded.admissionRevision();
  assert(bounded.admit(id,creation)==Result::Ok);
  assert(bounded.prepare(id)==Result::Ok); assert(bounded.accept(id)==Result::Ok);
  assert(bounded.rendererAcknowledged(id,id.manifest,id.signedManifest)==Result::Ok);
  assert(bounded.acknowledgeResult(id)==Result::Ok);
  assert(bounded.admit(identity('2'),bounded.admissionRevision())==Result::Ok);
  assert(bounded.query(id,record)==Result::Unavailable);
  assert(bounded.admit(id,creation)==Result::Unavailable);
  // Exhaust every torn-write byte in an acceptance transition. Three restores
  // must agree, and no incomplete write can manufacture an Installed receipt.
  MemoryStorage baseline; Store setup(baseline,std::string(32,'a'));
  assert(setup.restore()==Result::Ok); assert(setup.initializeAdmission(100)==Result::Ok); assert(setup.admit(id,setup.admissionRevision())==Result::Ok);
  assert(setup.prepare(id)==Result::Ok);
  for(size_t cut=0;cut<400;++cut) {
    auto fault=baseline; Store writer(fault,std::string(32,'a')); assert(writer.restore()==Result::Ok);
    fault.failWrite=true; fault.prefix=cut;
    assert(writer.accept(id)==Result::StorageFailure);
    assert(writer.cancel(id)==Result::StorageFailure);
    for(int recovery=0;recovery<3;++recovery) {
      Store reader(fault,std::string(32,'a')); assert(reader.restore()==Result::Ok);
      assert(reader.query(id,record)==Result::Ok);
      assert(record.phase==Phase::Prepared || record.phase==Phase::Accepted);
    }
  }
  auto future=baseline;
  future.slots[0][4]=2; // unknown new format cannot silently fall back
  Store incompatible(future,std::string(32,'a'));
  assert(incompatible.restore()==Result::Corrupt);
  auto lost=baseline; Store writer(lost,std::string(32,'a')); assert(writer.restore()==Result::Ok);
  lost.loseResponse=true; assert(writer.accept(id)==Result::StorageFailure);
  Store recovered(lost,std::string(32,'a')); assert(recovered.restore()==Result::Ok);
  assert(recovered.query(id,record)==Result::Ok && record.phase==Phase::Accepted);
  assert(recovered.cancel(id)==Result::TooLate);
  std::cout << "durable operation tests passed\n";
}
