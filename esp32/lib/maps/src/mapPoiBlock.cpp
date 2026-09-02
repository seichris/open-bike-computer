#include "mapPoiBlock.hpp"

#include "mapBlockFormat.hpp"

namespace map_poi_block {
namespace {

uint16_t le16(const uint8_t *bytes) {
  return static_cast<uint16_t>(bytes[0]) |
         (static_cast<uint16_t>(bytes[1]) << 8U);
}

int16_t sle16(const uint8_t *bytes) {
  return static_cast<int16_t>(le16(bytes));
}

uint32_t le32(const uint8_t *bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8U) |
         (static_cast<uint32_t>(bytes[2]) << 16U) |
         (static_cast<uint32_t>(bytes[3]) << 24U);
}

bool fail(std::string *error, const char *message) {
  if (error != nullptr)
    *error = message;
  return false;
}

bool take(size_t amount, size_t size, size_t &offset) {
  if (offset > size || amount > size - offset)
    return false;
  offset += amount;
  return true;
}

bool baseEnd(const uint8_t *data, size_t size, size_t &offset) {
  if (size < 6 || data[3] != 5)
    return false;
  offset = 4;
  const uint16_t polygonCount = le16(data + offset);
  offset += 2;
  for (uint16_t index = 0; index < polygonCount; ++index) {
    if (!take(14, size, offset))
      return false;
    const uint16_t pointCount = le16(data + offset - 2);
    if (!take(static_cast<size_t>(pointCount) * 4U, size, offset))
      return false;
  }
  if (!take(2, size, offset))
    return false;
  const uint16_t polylineCount = le16(data + offset - 2);
  for (uint16_t index = 0; index < polylineCount; ++index) {
    if (!take(15, size, offset))
      return false;
    const uint16_t pointCount = le16(data + offset - 2);
    if (!take(static_cast<size_t>(pointCount) * 4U, size, offset))
      return false;
  }
  return true;
}

} // namespace

bool decode(const uint8_t *data, size_t size, Block &output,
            std::string *error) {
  output.clear();
  if (data == nullptr || size < 4 || data[0] != 'F' || data[1] != 'M' ||
      data[2] != 'B')
    return fail(error, "invalid FMB header");
  if (data[3] < 5)
    return map_block_format::validate(data, size)
               ? true
               : fail(error, "invalid legacy FMB block");
  if (data[3] != 5 || !map_block_format::validate(data, size))
    return fail(error, "invalid FMB v5 block");

  size_t directoryOffset = 0;
  if (!baseEnd(data, size, directoryOffset) || directoryOffset > size ||
      size - directoryOffset < 88U)
    return fail(error, "invalid FMB v5 geometry boundary");
  const size_t entry = directoryOffset + 8U + 4U * 16U;
  if (data[entry] != 5)
    return fail(error, "missing FMB v5 POI section");
  size_t cursor = le32(data + entry + 4U);
  const size_t length = le32(data + entry + 8U);
  if (cursor > size || length > size - cursor || length < 8U)
    return fail(error, "invalid FMB v5 POI section range");
  const size_t end = cursor + length;
  const uint16_t count = le16(data + cursor);
  cursor += 8U;
  output.records.reserve(count);
  output.stats.records = count;
  for (uint16_t index = 0; index < count; ++index) {
    if (cursor > end || end - cursor < 8U)
      return fail(error, "truncated FMB v5 POI record");
    Record record;
    record.localX = sle16(data + cursor);
    record.localY = sle16(data + cursor + 2U);
    record.category = static_cast<Category>(data[cursor + 4U]);
    record.maximumZoom = data[cursor + 5U];
    record.rank = data[cursor + 6U];
    const size_t categoryIndex = static_cast<size_t>(data[cursor + 4U] - 1U);
    ++output.stats.categories[categoryIndex];
    output.records.push_back(record);
    cursor += 8U;
  }
  if (cursor != end)
    return fail(error, "FMB v5 POI section has trailing bytes");
  return true;
}

} // namespace map_poi_block
