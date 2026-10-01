#include "durable_operation.hpp"
#include <algorithm>
#include <limits>
#include <utility>

namespace device_transfer::durable_operation {
namespace {
constexpr size_t kMaxImage = 4096;
bool hex(const std::string &s, size_t length) {
  return s.size() == length && std::all_of(s.begin(), s.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}
bool safeName(const std::string &s) {
  return !s.empty() && s.size() <= 96 && std::all_of(s.begin(),s.end(),[](char c) {
    return (c>='a' && c<='z') || (c>='A' && c<='Z') ||
           (c>='0' && c<='9') || c=='-' || c=='_' || c=='.';
  });
}
bool valid(const Identity &id) {
  return hex(id.device, 32) && hex(id.operation, 32) &&
         hex(id.manifest, 64) && hex(id.signedManifest, 64) &&
         hex(id.stream, 64) && id.streamBytes > 0 && safeName(id.session) && safeName(id.map);
}
bool terminal(Phase phase) {
  return phase == Phase::Installed || phase == Phase::Failed ||
         phase == Phase::Cancelled;
}
void number(std::vector<uint8_t> &out, uint64_t n) {
  for (unsigned i = 0; i < 8; ++i) out.push_back((n >> (i * 8)) & 255);
}
uint64_t number(const std::vector<uint8_t> &in, size_t &offset) {
  uint64_t n = 0;
  for (unsigned i = 0; i < 8; ++i) n |= uint64_t(in[offset++]) << (i * 8);
  return n;
}
// Integrity check, NOT authentication; card copying is handled by device bind.
uint64_t checksum(const std::vector<uint8_t> &data, size_t count) {
  uint64_t h = 14695981039346656037ULL;
  for (size_t i = 0; i < count; ++i) { h ^= data[i]; h *= 1099511628211ULL; }
  return h;
}
std::vector<uint8_t> encode(const std::array<Record, kCapacity> &records,
                            uint64_t generation) {
  std::vector<uint8_t> out{'O','B','O','P',kSchema};
  number(out, generation);
  for (const auto &r : records) {
    out.push_back(r.identity.operation.empty() ? 0 : 1);
    if (r.identity.operation.empty()) continue;
    for (const auto *s : {&r.identity.device, &r.identity.operation,
                         &r.identity.manifest, &r.identity.signedManifest,
                         &r.identity.stream}) out.insert(out.end(), s->begin(), s->end());
    for (const auto *s : {&r.identity.session, &r.identity.map}) {
      out.push_back(static_cast<uint8_t>(s->size()));
      out.insert(out.end(),s->begin(),s->end());
    }
    number(out, r.identity.streamBytes);
    out.push_back(static_cast<uint8_t>(r.phase));
    number(out, r.revision);
  }
  number(out, checksum(out, out.size()));
  return out;
}
bool decode(const std::vector<uint8_t> &in,
            std::array<Record, kCapacity> &records, uint64_t &generation) {
  if (in.size() < 25 || in.size() > kMaxImage ||
      !std::equal(in.begin(), in.begin()+5, std::vector<uint8_t>{'O','B','O','P',kSchema}.begin())) return false;
  size_t end = in.size() - 8, crcOffset = end;
  if (checksum(in, end) != number(in, crcOffset)) return false;
  size_t offset = 5;
  generation = number(in, offset);
  if (!generation) return false;
  for (auto &r : records) {
    if (offset >= end) return false;
    const auto present = in[offset++];
    if (present == 0) continue;
    if (present != 1 || end - offset < 273) return false;
    for (auto *s : {&r.identity.device, &r.identity.operation,
                    &r.identity.manifest, &r.identity.signedManifest,
                    &r.identity.stream}) {
      const size_t size = s == &r.identity.device || s == &r.identity.operation ? 32 : 64;
      s->assign(in.begin()+offset, in.begin()+offset+size); offset += size;
    }
    for (auto *s : {&r.identity.session, &r.identity.map}) {
      if (offset >= end) return false;
      const size_t n=in[offset++];
      if (n==0 || n>96 || end-offset<n) return false;
      s->assign(in.begin()+offset,in.begin()+offset+n); offset+=n;
    }
    if (end-offset<17) return false;
    r.identity.streamBytes = number(in, offset);
    r.phase = static_cast<Phase>(in[offset++]);
    r.revision = number(in, offset);
    if (!valid(r.identity) || !r.revision || r.revision > generation ||
        r.phase < Phase::Receiving || r.phase > Phase::Forgotten) return false;
  }
  if (offset != end) return false;
  for (size_t i=0;i<kCapacity;++i) for (size_t j=i+1;j<kCapacity;++j)
    if (!records[i].identity.operation.empty() &&
        records[i].identity.operation == records[j].identity.operation) return false;
  return true;
}
}
bool Identity::operator==(const Identity &o) const {
  return device == o.device && operation == o.operation && manifest == o.manifest &&
      signedManifest == o.signedManifest && stream == o.stream && streamBytes == o.streamBytes &&
      session == o.session && map == o.map;
}
Store::Store(Storage &storage, std::string device)
    : storage_(storage), device_(std::move(device)) {}
Result Store::restore() {
  ready_ = false;
  if (!hex(device_, 32)) return Result::Invalid;
  std::array<Record,kCapacity> selected{};
  uint64_t best = 0; unsigned slot = 1; bool any = false;
  std::vector<uint8_t> bestBytes;
  for (unsigned i=0;i<2;++i) {
    std::vector<uint8_t> bytes;
    if (!storage_.read(i, bytes)) return Result::StorageFailure;
    if (bytes.empty()) continue;
    any = true;
    std::array<Record,kCapacity> candidate{}; uint64_t generation=0;
    if (!decode(bytes,candidate,generation)) continue;
    for (const auto &r : candidate)
      if (!r.identity.operation.empty() && r.identity.device != device_) return Result::ForeignDevice;
    if (generation == best && bytes != bestBytes) return Result::Corrupt;
    if (generation > best) { best=generation; selected=candidate; slot=i; bestBytes=bytes; }
  }
  if (any && !best) return Result::Corrupt;
  records_=selected; generation_=best; activeSlot_=slot; ready_=true;
  return Result::Ok;
}
Result Store::locate(const Identity &id, size_t &index) const {
  if (!ready_) return Result::StorageFailure;
  if (!valid(id)) return Result::Invalid;
  if (id.device != device_) return Result::ForeignDevice;
  for (size_t i=0;i<kCapacity;++i) if (records_[i].identity.operation == id.operation) {
    if (!(records_[i].identity == id)) return Result::Conflict;
    index=i; return Result::Ok;
  }
  return Result::Unavailable;
}
Result Store::persist(std::array<Record,kCapacity> next) {
  if (generation_ == std::numeric_limits<uint64_t>::max()) return Result::StorageFailure;
  const auto bytes=encode(next,generation_+1); const unsigned target=1-activeSlot_;
  std::vector<uint8_t> readback;
  if (!storage_.writeDurable(target,bytes) || !storage_.read(target,readback) || readback != bytes) {
    // A lost storage response is ambiguous. No more mutation until restore.
    ready_=false; return Result::StorageFailure;
  }
  records_=std::move(next); ++generation_; activeSlot_=target;
  return Result::Ok;
}
Result Store::admit(const Identity &id) {
  size_t index=0; const auto found=locate(id,index);
  if (found==Result::Ok) return records_[index].phase == Phase::Forgotten ? Result::Unavailable : Result::Replay;
  if (found!=Result::Unavailable) return found;
  auto next=records_;
  for (auto &r : next) if (r.identity.operation.empty() || r.phase==Phase::Forgotten) {
    r={id,Phase::Receiving,generation_+1}; return persist(next);
  }
  return Result::Busy;
}
Result Store::initializeAdmission(uint64_t seed) {
  if (!ready_) return Result::StorageFailure;
  if (generation_!=0) return Result::Replay;
  if (!seed || seed==std::numeric_limits<uint64_t>::max()) return Result::Invalid;
  generation_=seed;
  return persist(records_);
}
Result Store::admit(const Identity &id,uint64_t creationRevision) {
  size_t index=0;
  const auto found=locate(id,index);
  if (found==Result::Unavailable && (generation_==0 || creationRevision!=generation_))
    return Result::Unavailable;
  return admit(id);
}
Result Store::transition(const Identity &id, Phase phase) {
  size_t i=0; auto result=locate(id,i); if (result!=Result::Ok) return result;
  const auto old=records_[i].phase;
  if (old==Phase::Forgotten) return Result::Unavailable;
  if (old==phase) return Result::Replay;
  bool allowed=false;
  switch (phase) {
  case Phase::Prepared: allowed=old==Phase::Receiving; break;
  case Phase::Accepted: allowed=old==Phase::Prepared; break;
  case Phase::Installed: allowed=old==Phase::Accepted; break;
  case Phase::Cancelled:
    if (old==Phase::Accepted || old==Phase::Installed) return Result::TooLate;
    allowed=old==Phase::Receiving || old==Phase::Prepared; break;
  case Phase::Failed: allowed=!terminal(old); break;
  case Phase::Forgotten: allowed=terminal(old); break;
  default: break;
  }
  if (!allowed) return Result::NotAccepted;
  auto next=records_; next[i].phase=phase; next[i].revision=generation_+1;
  return persist(next);
}
Result Store::prepare(const Identity &id) { return transition(id,Phase::Prepared); }
Result Store::accept(const Identity &id) { return transition(id,Phase::Accepted); }
Result Store::cancel(const Identity &id) { return transition(id,Phase::Cancelled); }
Result Store::fail(const Identity &id) { return transition(id,Phase::Failed); }
Result Store::acknowledgeResult(const Identity &id) { return transition(id,Phase::Forgotten); }
Result Store::rendererAcknowledged(const Identity &id, const std::string &manifest,
                                    const std::string &signedManifest) {
  if (manifest!=id.manifest || signedManifest!=id.signedManifest) return Result::SelectionMismatch;
  return transition(id,Phase::Installed);
}
Result Store::query(const Identity &id, Record &record) const {
  size_t i=0; const auto result=locate(id,i); if (result!=Result::Ok) return result;
  if (records_[i].phase==Phase::Forgotten) return Result::Unavailable;
  record=records_[i]; return Result::Ok;
}
Result Store::queryID(const std::string &operation, Record &record) const {
  if (!ready_) return Result::StorageFailure;
  if (!hex(operation,32)) return Result::Invalid;
  for (const auto &r : records_) if (r.identity.operation==operation) {
    if (r.phase==Phase::Forgotten) return Result::Unavailable;
    record=r; return Result::Ok;
  }
  return Result::Unavailable;
}
} // namespace device_transfer::durable_operation
