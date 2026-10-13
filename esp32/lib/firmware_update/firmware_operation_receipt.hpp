#pragma once
#include <cstdint>
#include <cstring>

#ifndef FIRMWARE_OPERATIONS_V1_ENABLED
#define FIRMWARE_OPERATIONS_V1_ENABLED 0
#endif

// SD-independent, bounded OTA receipt. Contains identity, never authority.
// One retained operation: no eviction until explicit authenticated acknowledgement.
namespace firmware_update::receipt {
enum class Phase : uint32_t { Empty = 0, Accepted = 1, Installed = 2, Failed = 3, Acknowledged = 4 };
struct Record {
  uint32_t schema = 1;
  uint32_t revision = 0;
  Phase phase = Phase::Empty;
  uint32_t partitionAddress = 0;
  uint32_t imageBytes = 0;
  char device[33]{};
  char operation[33]{};
  char image[65]{};
  uint32_t checksum = 0;
};
inline uint32_t checksum(const Record &r) {
  uint32_t h = 2166136261U;
  auto byte = [&](uint8_t b) { h = (h ^ b) * 16777619U; };
  auto integer = [&](uint32_t n) { for (unsigned i=0;i<4;++i) byte(n >> (8*i)); };
  integer(r.schema); integer(r.revision); integer(static_cast<uint32_t>(r.phase));
  integer(r.partitionAddress); integer(r.imageBytes);
  for (char c:r.device) byte(c);
  for (char c:r.operation) byte(c);
  for (char c:r.image) byte(c);
  return h;
}
inline bool hex(const char *s, unsigned n) {
  for (unsigned i=0;i<n;++i) if (!((s[i]>='0' && s[i]<='9') || (s[i]>='a' && s[i]<='f'))) return false;
  return s[n]==0;
}
inline bool valid(const Record &r) {
  return r.schema==1 && r.revision>0 && r.phase>=Phase::Accepted &&
      r.phase<=Phase::Acknowledged && r.partitionAddress && r.imageBytes &&
      hex(r.device,32) && hex(r.operation,32) && hex(r.image,64) && r.checksum==checksum(r);
}
inline bool same(const Record &a, const Record &b) {
  return std::memcmp(a.device,b.device,33)==0 && std::memcmp(a.operation,b.operation,33)==0 &&
      std::memcmp(a.image,b.image,65)==0 && a.partitionAddress==b.partitionAddress && a.imageBytes==b.imageBytes;
}
class Storage {
public:
  virtual ~Storage() = default;
  // 0 absent, 1 full record, -1 read/corruption error. Missing is not I/O failure.
  virtual int read(unsigned slot, Record &record) = 0;
  virtual bool write(unsigned slot, const Record &record) = 0;
};
class Store {
public:
  explicit Store(Storage &storage):storage_(storage) {}
  bool restore() {
    Record a{},b{}; int ar=storage_.read(0,a),br=storage_.read(1,b);
    ready_=false;
    // Never hide torn/unknown-format records by reverting to an older receipt.
    if(ar<0 || br<0 || (ar && !valid(a)) || (br && !valid(b))) return false;
    if(ar && br && a.revision==b.revision && (a.checksum!=b.checksum || !same(a,b))) return false;
    slot_=(br && (!ar || b.revision>a.revision))?1:0;
    current_=slot_?b:a; if(!ar && !br) current_={};
    ready_=true; return true;
  }
  const Record &current() const { return current_; }
  bool accept(Record next) {
    if(!ready_) return false;
    if(current_.phase!=Phase::Empty && same(current_,next)) return current_.phase==Phase::Accepted;
    if(current_.phase!=Phase::Empty && current_.phase!=Phase::Acknowledged) return false;
    // Preserve acknowledged operation as a tombstone: it cannot be readmitted.
    if(current_.phase==Phase::Acknowledged && std::strcmp(current_.operation,next.operation)==0) return false;
    next.phase=Phase::Accepted; return persist(next);
  }
  bool finish(bool installed) {
    if(!ready_) return false;
    if(current_.phase==Phase::Installed || current_.phase==Phase::Failed) return current_.phase==(installed?Phase::Installed:Phase::Failed);
    if(current_.phase!=Phase::Accepted) return false;
    Record next=current_; next.phase=installed?Phase::Installed:Phase::Failed; return persist(next);
  }
  bool acknowledge(const char *device, const char *operation, const char *image) {
    if(!ready_ || std::strcmp(current_.device,device) || std::strcmp(current_.operation,operation) || std::strcmp(current_.image,image)) return false;
    if(current_.phase==Phase::Acknowledged) return true;
    if(current_.phase!=Phase::Installed && current_.phase!=Phase::Failed) return false;
    Record next=current_; next.phase=Phase::Acknowledged; return persist(next);
  }
private:
  bool persist(Record next) {
    if(current_.revision==UINT32_MAX) return false;
    next.revision=current_.revision+1; next.checksum=checksum(next);
    if(!valid(next)) return false;
    unsigned slot=1-slot_;
    // False may mean committed-but-unacknowledged; poison until cold reload.
    if(!storage_.write(slot,next)) { ready_=false; return false; }
    Record check{};
    if(storage_.read(slot,check)!=1 || !valid(check) || check.checksum!=next.checksum || !same(check,next)) { ready_=false; return false; }
    current_=next; slot_=slot; return true;
  }
  Storage &storage_; Record current_{}; unsigned slot_=1; bool ready_=false;
};
const char *phaseName(Phase phase);
bool load(Record &record);
bool accept(const Record &record);
bool finish(bool installed);
bool acknowledge(const char *device, const char *operation, const char *image);
} // namespace firmware_update::receipt
