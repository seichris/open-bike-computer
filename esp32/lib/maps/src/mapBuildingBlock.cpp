#include "mapBuildingBlock.hpp"

#include "mapBlockFormat.hpp"

namespace map_building_block {
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
  if (size < 6 || data[3] != 4)
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

size_t Block::decodedBytes() const {
  size_t bytes = buildings.capacity() * sizeof(Building);
  for (const auto &building : buildings) {
    bytes += building.rings.capacity() * sizeof(Ring);
    for (const auto &ring : building.rings) {
      bytes += ring.points.capacity() * sizeof(Point);
      bytes += ring.walls.capacity() * sizeof(uint8_t);
    }
  }
  return bytes;
}

bool decode(const uint8_t *data, size_t size, Block &output,
            std::string *error) {
  output.clear();
  if (data == nullptr || size < 4 || data[0] != 'F' || data[1] != 'M' ||
      data[2] != 'B')
    return fail(error, "invalid FMB header");
  if (data[3] < 4)
    return map_block_format::validate(data, size)
               ? true
               : fail(error, "invalid legacy FMB block");
  if (data[3] != 4 || !map_block_format::validate(data, size))
    return fail(error, "invalid FMB v4 block");

  size_t directoryOffset = 0;
  if (!baseEnd(data, size, directoryOffset) ||
      directoryOffset > size || size - directoryOffset < 72U)
    return fail(error, "invalid FMB v4 geometry boundary");
  const size_t entry = directoryOffset + 8U + 3U * 16U;
  if (data[entry] != 4)
    return fail(error, "missing FMB v4 building section");
  size_t cursor = le32(data + entry + 4);
  const size_t length = le32(data + entry + 8);
  if (cursor > size || length > size - cursor || length < 8)
    return fail(error, "invalid FMB v4 building section range");
  const size_t end = cursor + length;
  const uint16_t count = le16(data + cursor);
  cursor += 8;
  output.buildings.reserve(count);
  for (uint16_t index = 0; index < count; ++index) {
    if (cursor > end || end - cursor < 18)
      return fail(error, "truncated FMB v4 building");
    Building building;
    building.typeId = data[cursor];
    building.flags = data[cursor + 1];
    building.provenance = data[cursor + 2];
    building.heightDm = le16(data + cursor + 4);
    building.minimumHeightDm = le16(data + cursor + 6);
    building.minX = sle16(data + cursor + 8);
    building.minY = sle16(data + cursor + 10);
    building.maxX = sle16(data + cursor + 12);
    building.maxY = sle16(data + cursor + 14);
    const uint16_t ringCount = le16(data + cursor + 16);
    cursor += 18;
    building.rings.reserve(ringCount);
    for (uint16_t ringIndex = 0; ringIndex < ringCount; ++ringIndex) {
      if (cursor > end || end - cursor < 4)
        return fail(error, "truncated FMB v4 building ring");
      const uint16_t pointCount = le16(data + cursor);
      Ring ring;
      ring.hole = (data[cursor + 2] & 1U) != 0;
      cursor += 4;
      ring.points.reserve(pointCount);
      for (uint16_t pointIndex = 0; pointIndex < pointCount; ++pointIndex) {
        if (cursor > end || end - cursor < 4)
          return fail(error, "truncated FMB v4 building points");
        ring.points.push_back({sle16(data + cursor), sle16(data + cursor + 2)});
        cursor += 4;
      }
      const size_t wallBytes = (pointCount + 7U) / 8U;
      if (cursor > end || wallBytes > end - cursor)
        return fail(error, "truncated FMB v4 wall mask");
      ring.walls.reserve(pointCount);
      for (uint16_t pointIndex = 0; pointIndex < pointCount; ++pointIndex)
        ring.walls.push_back(
            (data[cursor + pointIndex / 8U] >> (pointIndex % 8U)) & 1U);
      cursor += wallBytes;
      building.rings.push_back(std::move(ring));
    }
    output.buildings.push_back(std::move(building));
  }
  if (cursor != end)
    return fail(error, "FMB v4 building section has trailing bytes");
  return true;
}

} // namespace map_building_block
