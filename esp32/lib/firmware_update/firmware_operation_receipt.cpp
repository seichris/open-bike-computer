#include "firmware_operation_receipt.hpp"
#include <nvs.h>
#include <esp_memory_utils.h>

namespace firmware_update::receipt {
namespace {
class NVSStorage final : public Storage {
public:
  int read(unsigned slot, Record &record) override {
    uint32_t stackMarker = 0;
    if (!esp_ptr_internal(&stackMarker)) return -1;
    nvs_handle_t handle;
    esp_err_t err=nvs_open("ota_receipt",NVS_READONLY,&handle);
    if(err==ESP_ERR_NVS_NOT_FOUND) return 0;
    if(err!=ESP_OK) return -1;
    size_t size=sizeof(record);
    err=nvs_get_blob(handle,slot?"receipt1":"receipt0",&record,&size);
    nvs_close(handle);
    if(err==ESP_ERR_NVS_NOT_FOUND) return 0;
    return err==ESP_OK && size==sizeof(record)?1:-1;
  }
  bool write(unsigned slot,const Record &record) override {
    uint32_t stackMarker = 0;
    if (!esp_ptr_internal(&stackMarker)) return false;
    nvs_handle_t handle;
    if(nvs_open("ota_receipt",NVS_READWRITE,&handle)!=ESP_OK) return false;
    esp_err_t err=nvs_set_blob(handle,slot?"receipt1":"receipt0",&record,sizeof(record));
    if(err==ESP_OK) err=nvs_commit(handle);
    nvs_close(handle); return err==ESP_OK;
  }
};
}
const char *phaseName(Phase p) {
  switch(p) {
    case Phase::Accepted:return "accepted";
    case Phase::Installed:return "installed";
    case Phase::Failed:return "failed";
    case Phase::Acknowledged:return "acknowledged";
    default:return "unavailable";
  }
}
bool load(Record &record) { NVSStorage io; Store store(io); if(!store.restore()) return false; record=store.current(); return true; }
bool accept(const Record &record) { NVSStorage io; Store store(io); return store.restore() && store.accept(record); }
bool finish(bool installed) { NVSStorage io; Store store(io); return store.restore() && store.finish(installed); }
bool acknowledge(const char *device,const char *operation,const char *image) { NVSStorage io; Store store(io); return store.restore() && store.acknowledge(device,operation,image); }
} // namespace firmware_update::receipt
