#pragma once
#include <cstdint>

namespace firmware_update::metadata_compatibility {
// Monotonic internal floor, independent of SD availability and build numbers.
// Version 1 reads operation-prepared/ready, accepted journals and receipts.
constexpr uint32_t kMapReaderVersion = 1;
class Storage {
public:
  virtual ~Storage() = default;
  virtual bool read(uint32_t &floor) = 0; // missing namespace/key means floor zero
  virtual bool write(uint32_t floor) = 0;
};
class Store {
public:
  explicit Store(Storage &storage) : storage_(storage) {}
  bool allows(uint32_t reader) {
    uint32_t floor = 0;
    return storage_.read(floor) && reader >= floor;
  }
  bool require(uint32_t reader) {
    uint32_t floor = 0;
    if (!storage_.read(floor)) return false;
    if (floor >= reader) return true;
    if (!storage_.write(reader)) return false;
    uint32_t check = 0;
    return storage_.read(check) && check >= reader;
  }
private:
  Storage &storage_;
};
// All NVS-backed reads require an internal stack too. PSRAM-backed HTTP callers
// use DeviceOperationOwner's reader/receipt methods rather than these helpers.
// requireReader runs only on the internal operation owner. A failed write is
// ambiguous: deny OTA in this boot until an explicit successful retry verifies it.
bool requireReader(uint32_t reader);
bool allowsReader(uint32_t reader);
bool floorAlreadyProtected(uint32_t reader);
void noteUncertain();
}
