#include "map_operation_journal.hpp"
#include "../utils/src/descriptor_file.hpp"
#include <cerrno>
#include <cstdio>
#include <memory>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace map_transfer {
std::string MapOperationStorage::path(unsigned slot) const {
  return root_ + "/VECTMAP/.operations-v1-" + std::to_string(slot);
}
bool MapOperationStorage::read(unsigned slot,std::vector<uint8_t> &bytes) {
  bytes.clear();
  if (slot>1) return false;
  descriptor_file::File owner(path(slot).c_str(), O_RDONLY);
  if (!owner) return errno==ENOENT;
  // A vector allocation can throw; the descriptor closes during unwinding.
  // This read nests beneath the manifest parser on the HTTP task. Keep the
  // bounded image off its stack, without reserving 4 KiB for a small journal.
  struct stat status{};
  bool ok=::fstat(owner.get(),&status)==0 && S_ISREG(status.st_mode) &&
          status.st_size>=0 && status.st_size<=4096;
  if (ok) {
    const size_t expected=static_cast<size_t>(status.st_size);
    bytes.resize(expected);
    const bool complete=descriptor_file::readExact(owner.get(),bytes.data(),expected);
    uint8_t trailing=0;
    const ssize_t extra=descriptor_file::readSome(owner.get(),&trailing,1);
    // Size discovery is not authority: reject a short read or later growth.
    ok=complete && extra==0;
  }
  const bool closed=owner.close()==0;
  if (!ok || !closed) { bytes.clear(); return false; }
  return true;
}
bool MapOperationStorage::writeDurable(unsigned slot,const std::vector<uint8_t> &bytes) {
  if (slot>1 || bytes.empty() || bytes.size()>4096) return false;
  const auto directory=root_+"/VECTMAP";
  if (::mkdir(directory.c_str(),0755)!=0 && errno!=EEXIST) return false;
  descriptor_file::File file(path(slot).c_str(), O_WRONLY|O_CREAT|O_TRUNC);
  if (!file) return false;
  bool ok=descriptor_file::writeAll(file.get(),bytes.data(),bytes.size());
  ok=::fsync(file.get())==0 && ok;
  ok=file.close()==0 && ok;
  // ESP32 FAT/SD fsync + close does NOT prove card-controller persistence.
  // This adapter is experimental and the capability remains release-gated.
  return ok;
}
const char *operationPhaseName(operation::Phase phase) {
  switch(phase) {
  case operation::Phase::Receiving:return "receiving";
  case operation::Phase::Prepared:return "prepared";
  case operation::Phase::Accepted:return "accepted";
  case operation::Phase::Installed:return "installed";
  case operation::Phase::Failed:return "failed";
  case operation::Phase::Cancelled:return "cancelled";
  case operation::Phase::Forgotten:return "result_unavailable";
  }
  return "result_unavailable";
}
std::string operationReceiptJson(const operation::Record &r) {
  const auto &id=r.identity;
  // Store validates bounded ASCII identities before allowing publication.
  return "{\"schemaVersion\":1,\"deviceID\":\""+id.device+
      "\",\"operationID\":\""+id.operation+"\",\"sessionID\":\""+id.session+
      "\",\"mapID\":\""+id.map+"\",\"manifestReceipt\":\""+id.manifest+
      "\",\"signedManifestReceipt\":\""+id.signedManifest+"\",\"streamSHA256\":\""+
      id.stream+"\",\"streamBytes\":"+std::to_string(id.streamBytes)+
      ",\"phase\":\""+operationPhaseName(r.phase)+"\",\"revision\":"+
      std::to_string(r.revision)+"}";
}
bool acceptedMapOperation(const std::string &root,const std::string &device,
                          const std::string &id,const std::string &session,
                          const std::string &manifest,const std::string &signedManifest) {
  if (device.empty()) return false;
  MapOperationStorage storage(root); operation::Store store(storage,device);
  if (store.restore()!=operation::Result::Ok) return false;
  // An acknowledged Installed tombstone still proves the prior grant while
  // retained, so cleanup/recovery may finish. Failed/cancelled tombstones never
  // grant activation. Reusing the slot safely removes that historical authority.
  for (const auto &record : store.records()) {
    if (record.identity.operation==id &&
        (record.phase==operation::Phase::Accepted || record.phase==operation::Phase::Installed) &&
        record.identity.session==session && record.identity.manifest==manifest &&
        record.identity.signedManifest==signedManifest) return true;
  }
  return false;
}
} // namespace map_transfer
