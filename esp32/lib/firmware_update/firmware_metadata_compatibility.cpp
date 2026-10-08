#include "firmware_metadata_compatibility.hpp"
#include <atomic>
#include <nvs.h>
#include <esp_memory_utils.h>

namespace firmware_update::metadata_compatibility {
namespace {
std::atomic<bool> uncertain{false};
std::atomic<uint32_t> observedFloor{0};
class NVSStorage final : public Storage {
public:
  bool read(uint32_t &floor) override {
    floor = 0;
    uint32_t stackMarker = 0;
    if (!esp_ptr_internal(&stackMarker)) return false;
    nvs_handle_t handle;
    const esp_err_t opened = nvs_open("map_meta_floor", NVS_READONLY, &handle);
    if (opened == ESP_ERR_NVS_NOT_FOUND) return observedFloor.load() == 0;
    if (opened != ESP_OK) return false;
    const esp_err_t result = nvs_get_u32(handle, "reader", &floor);
    nvs_close(handle);
    if (result != ESP_OK && result != ESP_ERR_NVS_NOT_FOUND) return false;
    uint32_t high = observedFloor.load();
    do { if (floor < high) return false; }
    while (!observedFloor.compare_exchange_weak(high, floor));
    return true;
  }
  bool write(uint32_t floor) override {
    uint32_t stackMarker = 0;
    if (!esp_ptr_internal(&stackMarker)) return false;
    nvs_handle_t handle;
    if (nvs_open("map_meta_floor", NVS_READWRITE, &handle) != ESP_OK) return false;
    esp_err_t result = nvs_set_u32(handle, "reader", floor);
    if (result == ESP_OK) result = nvs_commit(handle);
    nvs_close(handle);
    return result == ESP_OK;
  }
};
}
void noteUncertain() { uncertain.store(true); }
bool requireReader(uint32_t reader) {
  NVSStorage storage;
  Store store(storage);
  const bool ready = store.require(reader);
  uncertain.store(!ready);
  return ready;
}
bool floorAlreadyProtected(uint32_t reader) {
  if (uncertain.load()) return false;
  NVSStorage storage;
  uint32_t floor = 0;
  return storage.read(floor) && floor >= reader;
}
bool allowsReader(uint32_t reader) {
  if (uncertain.load()) return false;
  NVSStorage storage;
  Store store(storage);
  return store.allows(reader);
}
}
