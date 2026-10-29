#include "internal_storage_identity.hpp"

#include <algorithm>
#include <esp_memory_utils.h>
#include <esp_partition.h>
#include <nvs.h>

namespace internal_storage {
namespace {

constexpr const char *kNamespace = "ffat_layout";
constexpr const char *kGeometryKey = "geometry";

uint64_t geometry(uint32_t address, uint32_t size) {
  return (static_cast<uint64_t>(address) << 32) | size;
}

bool onInternalStack() {
  uint32_t marker = 0;
  return esp_ptr_internal(&marker);
}

// Scan from the end: wear-levelling keeps its state and configuration there,
// so any initialised volume, including an old one shifted under a moved table,
// is recognised after the first chunk. Only a fully erased partition (a new
// device, or the signed migration's erase) is read completely, once.
bool fullyErased(const esp_partition_t *partition) {
  uint8_t buffer[1024];
  for (uint32_t end = partition->size; end > 0;) {
    const uint32_t count =
        std::min<uint32_t>(static_cast<uint32_t>(sizeof(buffer)), end);
    end -= count;
    if (esp_partition_read(partition, end, buffer, count) != ESP_OK ||
        std::any_of(buffer, buffer + count,
                    [](uint8_t value) { return value != 0xFF; }))
      return false;
  }
  return true;
}

} // namespace

Assessment assess(const char *label) {
  Assessment result;
  if (!onInternalStack())
    return result;
  const esp_partition_t *partition = esp_partition_find_first(
      ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_FAT, label);
  if (partition == nullptr)
    return result;
  result.partitionFound = true;
  result.address = partition->address;
  result.size = partition->size;
  result.erased = fullyErased(partition);
  // A missing or unreadable record is Absent: it permits a mount attempt but
  // never a format of non-erased bytes.
  nvs_handle_t handle;
  if (nvs_open(kNamespace, NVS_READONLY, &handle) == ESP_OK) {
    uint64_t stored = 0;
    if (nvs_get_u64(handle, kGeometryKey, &stored) == ESP_OK)
      result.record = stored == geometry(result.address, result.size)
                          ? storage_mount_policy::InternalGeometryRecord::Matches
                          : storage_mount_policy::InternalGeometryRecord::Differs;
    nvs_close(handle);
  }
  return result;
}

bool recordGeometry(const Assessment &assessment) {
  if (!assessment.partitionFound ||
      assessment.record == storage_mount_policy::InternalGeometryRecord::Matches)
    return true;
  if (!onInternalStack())
    return false;
  nvs_handle_t handle;
  if (nvs_open(kNamespace, NVS_READWRITE, &handle) != ESP_OK)
    return false;
  esp_err_t error = nvs_set_u64(handle, kGeometryKey,
                                geometry(assessment.address, assessment.size));
  if (error == ESP_OK)
    error = nvs_commit(handle);
  nvs_close(handle);
  return error == ESP_OK;
}

} // namespace internal_storage
