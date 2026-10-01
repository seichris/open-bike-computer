#include "../../lib/device_transfer/durable_operation.hpp"
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
  MemoryStorage io;
  Store store(io,std::string(32,'a')); auto id=identity(); Record record;
  assert(store.restore()==Result::Ok);
  assert(store.query(id,record)==Result::Unavailable);
  assert(store.admit(id)==Result::Ok);
  assert(store.accept(id)==Result::NotAccepted);
  assert(store.rendererAcknowledged(id,id.manifest,id.signedManifest)==Result::NotAccepted);
  assert(store.prepare(id)==Result::Ok);
  assert(store.accept(id)==Result::Ok);
  assert(store.cancel(id)==Result::TooLate);
  assert(store.rendererAcknowledged(id,std::string(64,'e'),id.signedManifest)==Result::SelectionMismatch);
  assert(store.rendererAcknowledged(id,id.manifest,id.signedManifest)==Result::Ok);
  assert(store.admit(id)==Result::Replay);
  auto conflict=id; conflict.streamBytes++;
  assert(store.admit(conflict)==Result::Conflict);
  Store restarted(io,std::string(32,'a')); assert(restarted.restore()==Result::Ok);
  assert(restarted.query(id,record)==Result::Ok && record.phase==Phase::Installed);
  Store movedCard(io,std::string(32,'f')); assert(movedCard.restore()==Result::ForeignDevice);
  assert(restarted.acknowledgeResult(id)==Result::Ok);
  assert(restarted.admit(id)==Result::Unavailable);
  for(char c='2'; c<='4';++c) assert(restarted.admit(identity(c))==Result::Ok);
  assert(restarted.admit(identity('5'))==Result::Busy);
  // Exhaust every torn-write byte in an acceptance transition. Three restores
  // must agree, and no incomplete write can manufacture an Installed receipt.
  MemoryStorage baseline; Store setup(baseline,std::string(32,'a'));
  assert(setup.restore()==Result::Ok); assert(setup.admit(id)==Result::Ok);
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
  auto lost=baseline; Store writer(lost,std::string(32,'a')); assert(writer.restore()==Result::Ok);
  lost.loseResponse=true; assert(writer.accept(id)==Result::StorageFailure);
  Store recovered(lost,std::string(32,'a')); assert(recovered.restore()==Result::Ok);
  assert(recovered.query(id,record)==Result::Ok && record.phase==Phase::Accepted);
  assert(recovered.cancel(id)==Result::TooLate);
  std::cout << "durable operation tests passed\n";
}
