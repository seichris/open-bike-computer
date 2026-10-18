#pragma once
#include <cstdint>
#include <string>
namespace device_transfer::durable_operation {
// The owner supplies a fresh unpredictable 128-bit epoch each boot. It is not
// a bearer credential: owner authentication is always checked independently.
// Retried known IDs use their immutable durable binding; only absent IDs use
// this fence. It prevents old descriptors resurrecting evicted IDs after SD
// replacement, old-slot recovery, process restart, or card snapshot rollback.
class AdmissionFence {
public:
  explicit AdmissionFence(std::string epoch = {}) : epoch_(std::move(epoch)) {}
  bool observe(uint64_t revision) {
    if (revision < floor_) return false;
    floor_ = revision; return true;
  }
  bool permits(const std::string &epoch, uint64_t revision) const {
    return epoch_.size()==32 && epoch==epoch_ && revision!=0 && revision==floor_;
  }
  const std::string &epoch() const { return epoch_; }
private:
  std::string epoch_;
  uint64_t floor_ = 0;
};
}
