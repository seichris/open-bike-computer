#pragma once

#include "map_profile_protocol.hpp"
#include "ride_ble_protocol.generated.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace screen_configuration_protocol {

constexpr std::size_t MAX_INSTANCES =
    ride_ble_protocol_generated::MAXIMUM_SCREEN_CONFIGURATION_INSTANCES;
constexpr std::size_t MAX_NAME_BYTES =
    ride_ble_protocol_generated::MAXIMUM_SCREEN_CONFIGURATION_NAME_BYTES;
constexpr std::size_t MAX_DOCUMENT_BYTES =
    ride_ble_protocol_generated::MAXIMUM_SCREEN_CONFIGURATION_DOCUMENT_BYTES;
constexpr std::size_t RIDE_STATS_SLOT_COUNT =
    ride_ble_protocol_generated::RIDE_STATS_CONFIGURATION_SLOT_COUNT;
constexpr uint8_t SCHEMA_VERSION =
    ride_ble_protocol_generated::SCREEN_CONFIGURATION_SCHEMA_VERSION;
constexpr uint8_t CAPABILITY_TLV_TYPE =
    ride_ble_protocol_generated::SCREEN_CONFIGURATION_CAPABILITY_TLV_TYPE;
constexpr uint8_t MAX_CHUNKS = 160;
constexpr uint32_t REASSEMBLY_TIMEOUT_MS = 5000;
constexpr uint8_t INSTANCE_ENABLED_FLAG = 1U << 0;
constexpr uint32_t APP_INSTANCE_ID_MASK = 1UL << 31;
constexpr uint32_t ALLOWED_VISIBILITY_MASK =
    map_profile_protocol::VISIBILITY_EXTENDED_FEATURE_MASK |
    map_profile_protocol::VISIBILITY_OVERLAY_MASK;

enum class ScreenType : uint8_t {
  Map = 0,
  Navigation = 1,
  RideStats = 2,
  MapNavigation = 3,
  BatteryStatus = 4,
};

constexpr uint32_t screenTypeBit(ScreenType type) {
  return 1UL << static_cast<uint8_t>(type);
}

constexpr uint32_t SUPPORTED_SCREEN_TYPES =
    screenTypeBit(ScreenType::Map) |
    screenTypeBit(ScreenType::Navigation) |
    screenTypeBit(ScreenType::RideStats) |
    screenTypeBit(ScreenType::MapNavigation) |
    screenTypeBit(ScreenType::BatteryStatus);

enum class RideStatsWidget : uint8_t {
  Empty = 0,
  Speed = 1,
  HeartRate = 2,
  HeartRateZone = 3,
  Distance = 4,
  MovingTime = 5,
  ElapsedTime = 6,
  Altitude = 7,
  RouteRemaining = 8,
  Power = 9,
  Cadence = 10,
  AverageSpeed = 11,
  MaximumSpeed = 12,
  Calories = 13,
  AverageHeartRate = 14,
  SmartMetric1 = 15,
  SmartMetric2 = 16,
};

constexpr uint32_t rideStatsWidgetBit(RideStatsWidget widget) {
  return 1UL << static_cast<uint8_t>(widget);
}

constexpr uint32_t SUPPORTED_RIDE_STATS_WIDGETS =
    (1UL << (static_cast<uint8_t>(RideStatsWidget::SmartMetric2) + 1U)) - 1U;

struct MapProfile {
  uint8_t minPolygonSize = 0;
  uint8_t detailLevel = map_profile_protocol::MAP_DEFAULT_DETAIL_LEVEL;
  uint8_t routeLineWidth = map_profile_protocol::MAP_DEFAULT_ROUTE_LINE_WIDTH;
  uint8_t streetLineWidth = map_profile_protocol::DEFAULT_STREET_WIDTH;
  uint8_t positionMarkerScale = 2;
  uint8_t zoomLevel = map_profile_protocol::MAP_DEFAULT_ZOOM_LEVEL;
  uint32_t visibilityMask = ALLOWED_VISIBILITY_MASK;
  uint8_t labelDensity = map_profile_protocol::DEFAULT_LABEL_DENSITY;
  uint8_t labelLanguageMode =
      map_profile_protocol::DEFAULT_LABEL_LANGUAGE_MODE;
  uint8_t labelTextSize = map_profile_protocol::DEFAULT_LABEL_TEXT_SIZE;
  uint8_t labelOrientation =
      map_profile_protocol::DEFAULT_LABEL_ORIENTATION;
  uint8_t rotationMode = 0;
  bool birdsEyeEnabled = true;
  uint8_t birdsEyePerspective =
      map_profile_protocol::MAP_NAVIGATION_DEFAULT_BIRDS_EYE_PERSPECTIVE;
  bool buildings3DEnabled = true;
};

struct RideStatsLayout {
  std::array<RideStatsWidget, RIDE_STATS_SLOT_COUNT> slots = {
      RideStatsWidget::Speed,       RideStatsWidget::HeartRate,
      RideStatsWidget::HeartRateZone, RideStatsWidget::Distance,
      RideStatsWidget::MovingTime,  RideStatsWidget::SmartMetric1,
      RideStatsWidget::SmartMetric2};
};

struct ScreenInstance {
  uint32_t id = 0;
  ScreenType type = ScreenType::Map;
  bool enabled = true;
  uint8_t nameLength = 0;
  std::array<char, MAX_NAME_BYTES + 1> name{};
  MapProfile mapProfile{};
  RideStatsLayout rideStatsLayout{};
};

struct Document {
  uint32_t defaultInstanceID = 0;
  uint8_t instanceCount = 0;
  std::array<ScreenInstance, MAX_INSTANCES> instances{};
};

enum class ValidationError : uint8_t {
  None = 0,
  InvalidEnvelope,
  TooManyInstances,
  InvalidID,
  DuplicateID,
  InvalidName,
  UnsupportedType,
  InvalidPayload,
  AllDisabled,
  InvalidDefault,
  UnsupportedWidget,
  EmptyRideStatsLayout,
};

enum class DecodeResult : uint8_t {
  Complete,
  Malformed,
  Unsupported,
};

enum class ChunkResult : uint8_t {
  Accepted,
  Complete,
  Rejected,
};

constexpr uint8_t DOCUMENT_MAGIC[4] = {'S', 'C', 'V', '1'};
constexpr uint8_t PAYLOAD_VERSION = 1;
constexpr uint8_t RIDE_STATS_LAYOUT_KIND = 1;
constexpr std::size_t DOCUMENT_HEADER_BYTES = 10;
constexpr std::size_t INSTANCE_HEADER_BYTES = 9;
constexpr std::size_t DOCUMENT_CRC_BYTES = 4;
constexpr std::size_t EMPTY_PAYLOAD_BYTES = 1;
constexpr std::size_t MAP_PAYLOAD_BYTES = 16;
constexpr std::size_t MAP_NAVIGATION_PAYLOAD_BYTES = 18;
constexpr std::size_t RIDE_STATS_PAYLOAD_BYTES = 3 + RIDE_STATS_SLOT_COUNT;
constexpr std::size_t REQUEST_BYTES = 8;
constexpr std::size_t CHUNK_HEADER_BYTES = 14;
constexpr std::size_t ACK_BYTES = 17;
constexpr std::size_t CAPABILITIES_TLV_VALUE_BYTES = 14;

inline uint16_t readUInt16LE(const uint8_t *data) {
  return static_cast<uint16_t>(data[0]) |
         (static_cast<uint16_t>(data[1]) << 8U);
}

inline uint32_t readUInt32LE(const uint8_t *data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8U) |
         (static_cast<uint32_t>(data[2]) << 16U) |
         (static_cast<uint32_t>(data[3]) << 24U);
}

inline void writeUInt16LE(uint8_t *data, uint16_t value) {
  data[0] = static_cast<uint8_t>(value);
  data[1] = static_cast<uint8_t>(value >> 8U);
}

inline void writeUInt32LE(uint8_t *data, uint32_t value) {
  for (uint8_t index = 0; index < 4; ++index)
    data[index] = static_cast<uint8_t>(value >> (index * 8U));
}

inline uint32_t crc32(const uint8_t *data, std::size_t length) {
  uint32_t crc = 0xFFFFFFFFUL;
  for (std::size_t index = 0; index < length; ++index) {
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; ++bit)
      crc = (crc >> 1U) ^
            (0xEDB88320UL & static_cast<uint32_t>(-(crc & 1U)));
  }
  return ~crc;
}

inline bool isValidUtf8Name(const char *value, std::size_t length) {
  if (value == nullptr || length == 0 || length > MAX_NAME_BYTES)
    return false;
  std::size_t index = 0;
  while (index < length) {
    const uint8_t first = static_cast<uint8_t>(value[index]);
    if (first <= 0x7F) {
      if (first < 0x20 || first == 0x7F)
        return false;
      ++index;
      continue;
    }
    std::size_t continuationCount = 0;
    uint32_t codePoint = 0;
    if ((first & 0xE0U) == 0xC0U) {
      continuationCount = 1;
      codePoint = first & 0x1FU;
      if (codePoint < 2)
        return false;
    } else if ((first & 0xF0U) == 0xE0U) {
      continuationCount = 2;
      codePoint = first & 0x0FU;
    } else if ((first & 0xF8U) == 0xF0U) {
      continuationCount = 3;
      codePoint = first & 0x07U;
    } else {
      return false;
    }
    if (index + continuationCount >= length)
      return false;
    for (std::size_t offset = 1; offset <= continuationCount; ++offset) {
      const uint8_t next = static_cast<uint8_t>(value[index + offset]);
      if ((next & 0xC0U) != 0x80U)
        return false;
      codePoint = (codePoint << 6U) | (next & 0x3FU);
    }
    if ((continuationCount == 2 && codePoint < 0x800U) ||
        (continuationCount == 3 && codePoint < 0x10000U) ||
        (codePoint >= 0x80U && codePoint <= 0x9FU) ||
        codePoint > 0x10FFFFU ||
        (codePoint >= 0xD800U && codePoint <= 0xDFFFU))
      return false;
    index += continuationCount + 1;
  }
  return true;
}

inline bool isSupportedScreenType(ScreenType type) {
  const uint8_t raw = static_cast<uint8_t>(type);
  return raw <= static_cast<uint8_t>(ScreenType::BatteryStatus) &&
         (SUPPORTED_SCREEN_TYPES & (1UL << raw)) != 0;
}

inline bool isSupportedWidget(RideStatsWidget widget) {
  const uint8_t raw = static_cast<uint8_t>(widget);
  return raw <= static_cast<uint8_t>(RideStatsWidget::SmartMetric2) &&
         (SUPPORTED_RIDE_STATS_WIDGETS & (1UL << raw)) != 0;
}

inline bool isValidMapProfile(const MapProfile &profile, ScreenType type) {
  if (profile.minPolygonSize > 50 || profile.detailLevel > 2 ||
      profile.routeLineWidth < 2 || profile.routeLineWidth > 48 ||
      profile.streetLineWidth < 1 || profile.streetLineWidth > 24 ||
      profile.positionMarkerScale < 1 || profile.positionMarkerScale > 5 ||
      profile.zoomLevel > 5 ||
      (profile.visibilityMask & ~ALLOWED_VISIBILITY_MASK) != 0 ||
      profile.labelDensity > 3 || profile.labelLanguageMode > 2 ||
      profile.labelTextSize > 2 || profile.labelOrientation > 1)
    return false;
  if (type == ScreenType::Map)
    return profile.rotationMode <= 1;
  if (type == ScreenType::MapNavigation)
    return profile.birdsEyePerspective <= 4;
  return false;
}

inline ValidationError validate(const Document &document) {
  if (document.instanceCount == 0 || document.instanceCount > MAX_INSTANCES)
    return ValidationError::TooManyInstances;
  bool anyEnabled = false;
  bool defaultEnabled = false;
  for (uint8_t index = 0; index < document.instanceCount; ++index) {
    const ScreenInstance &instance = document.instances[index];
    if (instance.id == 0)
      return ValidationError::InvalidID;
    for (uint8_t prior = 0; prior < index; ++prior) {
      if (document.instances[prior].id == instance.id)
        return ValidationError::DuplicateID;
    }
    if (!isSupportedScreenType(instance.type))
      return ValidationError::UnsupportedType;
    if (instance.nameLength == 0 || instance.nameLength > MAX_NAME_BYTES ||
        !isValidUtf8Name(instance.name.data(), instance.nameLength) ||
        instance.name[instance.nameLength] != '\0')
      return ValidationError::InvalidName;
    if ((instance.type == ScreenType::Map ||
         instance.type == ScreenType::MapNavigation) &&
        !isValidMapProfile(instance.mapProfile, instance.type))
      return ValidationError::InvalidPayload;
    if (instance.type == ScreenType::RideStats) {
      bool anyWidget = false;
      for (RideStatsWidget widget : instance.rideStatsLayout.slots) {
        if (!isSupportedWidget(widget))
          return ValidationError::UnsupportedWidget;
        anyWidget = anyWidget || widget != RideStatsWidget::Empty;
      }
      if (!anyWidget)
        return ValidationError::EmptyRideStatsLayout;
    }
    anyEnabled = anyEnabled || instance.enabled;
    defaultEnabled = defaultEnabled ||
                     (instance.enabled &&
                      instance.id == document.defaultInstanceID);
  }
  if (!anyEnabled)
    return ValidationError::AllDisabled;
  if (!defaultEnabled)
    return ValidationError::InvalidDefault;
  return ValidationError::None;
}

inline MapProfile defaultMapProfile(ScreenType type) {
  MapProfile profile{};
  if (type == ScreenType::MapNavigation) {
    profile.detailLevel =
        map_profile_protocol::MAP_NAVIGATION_DEFAULT_DETAIL_LEVEL;
    profile.routeLineWidth =
        map_profile_protocol::MAP_NAVIGATION_DEFAULT_ROUTE_LINE_WIDTH;
    profile.zoomLevel = map_profile_protocol::MAP_NAVIGATION_DEFAULT_ZOOM_LEVEL;
    profile.visibilityMask =
        map_profile_protocol::MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK |
        map_profile_protocol::VISIBILITY_OVERLAY_MASK;
    profile.labelDensity =
        map_profile_protocol::MAP_NAVIGATION_DEFAULT_LABEL_DENSITY;
  }
  return profile;
}

inline bool setName(ScreenInstance &instance, const char *name,
                    std::size_t length) {
  if (!isValidUtf8Name(name, length))
    return false;
  std::memset(instance.name.data(), 0, instance.name.size());
  std::memcpy(instance.name.data(), name, length);
  instance.nameLength = static_cast<uint8_t>(length);
  return true;
}

class Writer {
public:
  Writer(uint8_t *output, std::size_t capacity)
      : output_(output), capacity_(capacity) {}

  bool byte(uint8_t value) { return bytes(&value, 1); }
  bool uint16(uint16_t value) {
    uint8_t encoded[2]{};
    writeUInt16LE(encoded, value);
    return bytes(encoded, sizeof(encoded));
  }
  bool uint32(uint32_t value) {
    uint8_t encoded[4]{};
    writeUInt32LE(encoded, value);
    return bytes(encoded, sizeof(encoded));
  }
  bool bytes(const void *value, std::size_t length) {
    if (value == nullptr || output_ == nullptr || length > capacity_ - size_)
      return false;
    std::memcpy(output_ + size_, value, length);
    size_ += length;
    return true;
  }
  std::size_t size() const { return size_; }

private:
  uint8_t *output_ = nullptr;
  std::size_t capacity_ = 0;
  std::size_t size_ = 0;
};

class Reader {
public:
  Reader(const uint8_t *input, std::size_t length)
      : input_(input), length_(length) {}

  bool byte(uint8_t &value) { return bytes(&value, 1); }
  bool uint16(uint16_t &value) {
    uint8_t encoded[2]{};
    if (!bytes(encoded, sizeof(encoded)))
      return false;
    value = readUInt16LE(encoded);
    return true;
  }
  bool uint32(uint32_t &value) {
    uint8_t encoded[4]{};
    if (!bytes(encoded, sizeof(encoded)))
      return false;
    value = readUInt32LE(encoded);
    return true;
  }
  bool bytes(void *output, std::size_t length) {
    if (output == nullptr || input_ == nullptr || length > remaining())
      return false;
    std::memcpy(output, input_ + offset_, length);
    offset_ += length;
    return true;
  }
  bool skip(std::size_t length) {
    if (length > remaining())
      return false;
    offset_ += length;
    return true;
  }
  const uint8_t *current() const { return input_ + offset_; }
  std::size_t offset() const { return offset_; }
  std::size_t remaining() const { return length_ - offset_; }

private:
  const uint8_t *input_ = nullptr;
  std::size_t length_ = 0;
  std::size_t offset_ = 0;
};

inline std::size_t payloadSize(ScreenType type) {
  switch (type) {
  case ScreenType::Map:
    return MAP_PAYLOAD_BYTES;
  case ScreenType::MapNavigation:
    return MAP_NAVIGATION_PAYLOAD_BYTES;
  case ScreenType::RideStats:
    return RIDE_STATS_PAYLOAD_BYTES;
  case ScreenType::Navigation:
  case ScreenType::BatteryStatus:
    return EMPTY_PAYLOAD_BYTES;
  }
  return 0;
}

inline bool encodeMapProfile(Writer &writer, const MapProfile &profile,
                             ScreenType type) {
  if (!writer.byte(PAYLOAD_VERSION) ||
      !writer.byte(profile.minPolygonSize) ||
      !writer.byte(profile.detailLevel) ||
      !writer.byte(profile.routeLineWidth) ||
      !writer.byte(profile.streetLineWidth) ||
      !writer.byte(profile.positionMarkerScale) ||
      !writer.byte(profile.zoomLevel) ||
      !writer.uint32(profile.visibilityMask) ||
      !writer.byte(profile.labelDensity) ||
      !writer.byte(profile.labelLanguageMode) ||
      !writer.byte(profile.labelTextSize) ||
      !writer.byte(profile.labelOrientation))
    return false;
  if (type == ScreenType::Map)
    return writer.byte(profile.rotationMode);
  return writer.byte(profile.birdsEyeEnabled ? 1 : 0) &&
         writer.byte(profile.birdsEyePerspective) &&
         writer.byte(profile.buildings3DEnabled ? 1 : 0);
}

inline bool encodePayload(Writer &writer, const ScreenInstance &instance) {
  switch (instance.type) {
  case ScreenType::Map:
  case ScreenType::MapNavigation:
    return encodeMapProfile(writer, instance.mapProfile, instance.type);
  case ScreenType::RideStats:
    if (!writer.byte(PAYLOAD_VERSION) ||
        !writer.byte(RIDE_STATS_LAYOUT_KIND) ||
        !writer.byte(static_cast<uint8_t>(RIDE_STATS_SLOT_COUNT)))
      return false;
    for (RideStatsWidget widget : instance.rideStatsLayout.slots) {
      if (!writer.byte(static_cast<uint8_t>(widget)))
        return false;
    }
    return true;
  case ScreenType::Navigation:
  case ScreenType::BatteryStatus:
    return writer.byte(PAYLOAD_VERSION);
  }
  return false;
}

inline std::size_t encodeDocument(const Document &document, uint8_t *output,
                                  std::size_t capacity) {
  if (validate(document) != ValidationError::None || output == nullptr ||
      capacity < DOCUMENT_HEADER_BYTES + DOCUMENT_CRC_BYTES)
    return 0;
  Writer writer(output, capacity);
  if (!writer.bytes(DOCUMENT_MAGIC, sizeof(DOCUMENT_MAGIC)) ||
      !writer.byte(SCHEMA_VERSION) || !writer.byte(document.instanceCount) ||
      !writer.uint32(document.defaultInstanceID))
    return 0;
  for (uint8_t index = 0; index < document.instanceCount; ++index) {
    const ScreenInstance &instance = document.instances[index];
    const std::size_t size = payloadSize(instance.type);
    if (size == 0 || size > UINT16_MAX || !writer.uint32(instance.id) ||
        !writer.byte(static_cast<uint8_t>(instance.type)) ||
        !writer.byte(instance.enabled ? INSTANCE_ENABLED_FLAG : 0) ||
        !writer.byte(instance.nameLength) ||
        !writer.uint16(static_cast<uint16_t>(size)) ||
        !writer.bytes(instance.name.data(), instance.nameLength) ||
        !encodePayload(writer, instance))
      return 0;
  }
  if (writer.size() > MAX_DOCUMENT_BYTES - DOCUMENT_CRC_BYTES)
    return 0;
  const uint32_t checksum = crc32(output, writer.size());
  if (!writer.uint32(checksum) || writer.size() > MAX_DOCUMENT_BYTES)
    return 0;
  return writer.size();
}

inline bool decodeMapProfile(Reader &reader, std::size_t payloadLength,
                             ScreenType type, MapProfile &profile) {
  if (payloadLength != payloadSize(type))
    return false;
  uint8_t version = 0;
  uint8_t birdsEye = 0;
  uint8_t buildings3D = 0;
  if (!reader.byte(version) || version != PAYLOAD_VERSION ||
      !reader.byte(profile.minPolygonSize) ||
      !reader.byte(profile.detailLevel) ||
      !reader.byte(profile.routeLineWidth) ||
      !reader.byte(profile.streetLineWidth) ||
      !reader.byte(profile.positionMarkerScale) ||
      !reader.byte(profile.zoomLevel) ||
      !reader.uint32(profile.visibilityMask) ||
      !reader.byte(profile.labelDensity) ||
      !reader.byte(profile.labelLanguageMode) ||
      !reader.byte(profile.labelTextSize) ||
      !reader.byte(profile.labelOrientation))
    return false;
  if (type == ScreenType::Map)
    return reader.byte(profile.rotationMode);
  return reader.byte(birdsEye) && birdsEye <= 1 &&
         reader.byte(profile.birdsEyePerspective) &&
         reader.byte(buildings3D) && buildings3D <= 1 &&
         ((profile.birdsEyeEnabled = birdsEye == 1), true) &&
         ((profile.buildings3DEnabled = buildings3D == 1), true);
}

inline DecodeResult decodeDocument(const uint8_t *input, std::size_t length,
                                   Document &document) {
  if (input == nullptr || length < DOCUMENT_HEADER_BYTES + DOCUMENT_CRC_BYTES ||
      length > MAX_DOCUMENT_BYTES)
    return DecodeResult::Malformed;
  const uint32_t expectedCRC = readUInt32LE(input + length - DOCUMENT_CRC_BYTES);
  if (crc32(input, length - DOCUMENT_CRC_BYTES) != expectedCRC)
    return DecodeResult::Malformed;
  Reader reader(input, length - DOCUMENT_CRC_BYTES);
  uint8_t magic[4]{};
  uint8_t schema = 0;
  uint8_t count = 0;
  if (!reader.bytes(magic, sizeof(magic)) ||
      std::memcmp(magic, DOCUMENT_MAGIC, sizeof(magic)) != 0 ||
      !reader.byte(schema))
    return DecodeResult::Malformed;
  if (schema != SCHEMA_VERSION)
    return DecodeResult::Unsupported;
  if (!reader.byte(count) || count == 0 || count > MAX_INSTANCES ||
      !reader.uint32(document.defaultInstanceID))
    return DecodeResult::Malformed;
  document.instanceCount = count;
  for (uint8_t index = 0; index < count; ++index) {
    ScreenInstance &instance = document.instances[index];
    uint8_t rawType = 0;
    uint8_t flags = 0;
    uint8_t nameLength = 0;
    uint16_t payloadLength = 0;
    if (!reader.uint32(instance.id) || !reader.byte(rawType) ||
        !reader.byte(flags) || (flags & ~INSTANCE_ENABLED_FLAG) != 0 ||
        !reader.byte(nameLength) || nameLength == 0 ||
        nameLength > MAX_NAME_BYTES || !reader.uint16(payloadLength) ||
        reader.remaining() < static_cast<std::size_t>(nameLength) +
                                 payloadLength)
      return DecodeResult::Malformed;
    if (rawType > static_cast<uint8_t>(ScreenType::BatteryStatus))
      return DecodeResult::Unsupported;
    instance.type = static_cast<ScreenType>(rawType);
    instance.enabled = (flags & INSTANCE_ENABLED_FLAG) != 0;
    instance.nameLength = nameLength;
    std::memset(instance.name.data(), 0, instance.name.size());
    if (!reader.bytes(instance.name.data(), nameLength))
      return DecodeResult::Malformed;
    const std::size_t payloadStart = reader.offset();
    switch (instance.type) {
    case ScreenType::Map:
    case ScreenType::MapNavigation:
      instance.mapProfile = defaultMapProfile(instance.type);
      if (!decodeMapProfile(reader, payloadLength, instance.type,
                            instance.mapProfile))
        return DecodeResult::Malformed;
      break;
    case ScreenType::RideStats: {
      if (payloadLength != RIDE_STATS_PAYLOAD_BYTES)
        return DecodeResult::Malformed;
      uint8_t version = 0;
      uint8_t layoutKind = 0;
      uint8_t slotCount = 0;
      if (!reader.byte(version) || version != PAYLOAD_VERSION ||
          !reader.byte(layoutKind) || layoutKind != RIDE_STATS_LAYOUT_KIND ||
          !reader.byte(slotCount) || slotCount != RIDE_STATS_SLOT_COUNT)
        return DecodeResult::Unsupported;
      for (std::size_t slot = 0; slot < RIDE_STATS_SLOT_COUNT; ++slot) {
        uint8_t rawWidget = 0;
        if (!reader.byte(rawWidget) ||
            rawWidget > static_cast<uint8_t>(RideStatsWidget::SmartMetric2))
          return DecodeResult::Unsupported;
        instance.rideStatsLayout.slots[slot] =
            static_cast<RideStatsWidget>(rawWidget);
      }
      break;
    }
    case ScreenType::Navigation:
    case ScreenType::BatteryStatus: {
      uint8_t version = 0;
      if (payloadLength != EMPTY_PAYLOAD_BYTES || !reader.byte(version) ||
          version != PAYLOAD_VERSION)
        return DecodeResult::Unsupported;
      break;
    }
    }
    if (reader.offset() != payloadStart + payloadLength)
      return DecodeResult::Malformed;
  }
  if (reader.remaining() != 0)
    return DecodeResult::Malformed;
  const ValidationError error = validate(document);
  if (error == ValidationError::UnsupportedType ||
      error == ValidationError::UnsupportedWidget)
    return DecodeResult::Unsupported;
  return error == ValidationError::None ? DecodeResult::Complete
                                        : DecodeResult::Malformed;
}

inline uint32_t documentCRC(const uint8_t *document, std::size_t length) {
  return document != nullptr && length >= DOCUMENT_CRC_BYTES
             ? readUInt32LE(document + length - DOCUMENT_CRC_BYTES)
             : 0;
}

inline std::size_t encodeCapabilitiesTLV(uint8_t *output,
                                        std::size_t capacity) {
  if (output == nullptr || capacity < 2 + CAPABILITIES_TLV_VALUE_BYTES)
    return 0;
  output[0] = CAPABILITY_TLV_TYPE;
  output[1] = CAPABILITIES_TLV_VALUE_BYTES;
  output[2] = SCHEMA_VERSION;
  output[3] = static_cast<uint8_t>(MAX_INSTANCES);
  output[4] = static_cast<uint8_t>(MAX_NAME_BYTES);
  output[5] = static_cast<uint8_t>(RIDE_STATS_SLOT_COUNT);
  writeUInt32LE(output + 6, SUPPORTED_SCREEN_TYPES);
  writeUInt32LE(output + 10, SUPPORTED_RIDE_STATS_WIDGETS);
  writeUInt16LE(output + 14, static_cast<uint16_t>(MAX_DOCUMENT_BYTES));
  return 2 + CAPABILITIES_TLV_VALUE_BYTES;
}

inline bool decodeCapabilitiesTLV(const uint8_t *value, std::size_t length,
                                  uint8_t &schemaVersion,
                                  uint8_t &maximumInstances,
                                  uint8_t &maximumNameBytes,
                                  uint8_t &slotCount,
                                  uint32_t &screenTypes,
                                  uint32_t &widgets,
                                  uint16_t &maximumDocumentBytes) {
  if (value == nullptr || length != CAPABILITIES_TLV_VALUE_BYTES)
    return false;
  schemaVersion = value[0];
  maximumInstances = value[1];
  maximumNameBytes = value[2];
  slotCount = value[3];
  screenTypes = readUInt32LE(value + 4);
  widgets = readUInt32LE(value + 8);
  maximumDocumentBytes = readUInt16LE(value + 12);
  return schemaVersion == SCHEMA_VERSION && maximumInstances > 0 &&
         maximumInstances <= MAX_INSTANCES && maximumNameBytes > 0 &&
         maximumNameBytes <= MAX_NAME_BYTES &&
         slotCount == RIDE_STATS_SLOT_COUNT &&
         maximumDocumentBytes > 0 &&
         maximumDocumentBytes <= MAX_DOCUMENT_BYTES;
}

inline bool hasMagic(const uint8_t *data, std::size_t length,
                     const char *magic) {
  return data != nullptr && magic != nullptr && length >= 4 &&
         std::memcmp(data, magic, 4) == 0;
}

inline std::size_t encodeRequest(uint32_t requestID, uint8_t *output,
                                 std::size_t capacity) {
  if (requestID == 0 || output == nullptr || capacity < REQUEST_BYTES)
    return 0;
  std::memcpy(output,
              ride_ble_protocol_generated::SCREEN_CONFIGURATION_REQUEST_MAGIC,
              4);
  writeUInt32LE(output + 4, requestID);
  return REQUEST_BYTES;
}

inline bool decodeRequest(const uint8_t *data, std::size_t length,
                          uint32_t &requestID) {
  if (length != REQUEST_BYTES ||
      !hasMagic(
          data, length,
          ride_ble_protocol_generated::SCREEN_CONFIGURATION_REQUEST_MAGIC))
    return false;
  requestID = readUInt32LE(data + 4);
  return requestID != 0;
}

inline std::size_t encodeChunk(const char *magic, uint32_t requestID,
                               uint32_t revision, uint8_t chunkIndex,
                               uint8_t chunkCount, const uint8_t *payload,
                               std::size_t payloadLength, uint8_t *output,
                               std::size_t capacity) {
  if (magic == nullptr || requestID == 0 || chunkCount == 0 ||
      chunkIndex >= chunkCount || payload == nullptr || payloadLength == 0 ||
      output == nullptr || capacity < CHUNK_HEADER_BYTES + payloadLength)
    return 0;
  std::memcpy(output, magic, 4);
  writeUInt32LE(output + 4, requestID);
  writeUInt32LE(output + 8, revision);
  output[12] = chunkIndex;
  output[13] = chunkCount;
  std::memcpy(output + CHUNK_HEADER_BYTES, payload, payloadLength);
  return CHUNK_HEADER_BYTES + payloadLength;
}

inline std::size_t encodeAcknowledgement(
    uint32_t requestID,
    ride_ble_protocol_generated::ScreenConfigurationResult result,
    uint32_t revision, uint32_t checksum, uint8_t *output,
    std::size_t capacity) {
  if (requestID == 0 || output == nullptr || capacity < ACK_BYTES)
    return 0;
  std::memcpy(output,
              ride_ble_protocol_generated::SCREEN_CONFIGURATION_ACK_MAGIC, 4);
  writeUInt32LE(output + 4, requestID);
  output[8] = static_cast<uint8_t>(result);
  writeUInt32LE(output + 9, revision);
  writeUInt32LE(output + 13, checksum);
  return ACK_BYTES;
}

inline bool decodeAcknowledgement(
    const uint8_t *data, std::size_t length, uint32_t &requestID,
    ride_ble_protocol_generated::ScreenConfigurationResult &result,
    uint32_t &revision, uint32_t &checksum) {
  if (length != ACK_BYTES ||
      !hasMagic(
          data, length,
          ride_ble_protocol_generated::SCREEN_CONFIGURATION_ACK_MAGIC))
    return false;
  requestID = readUInt32LE(data + 4);
  const uint8_t rawResult = data[8];
  if (requestID == 0 ||
      rawResult > static_cast<uint8_t>(
                      ride_ble_protocol_generated::ScreenConfigurationResult::
                          Unauthorized))
    return false;
  result = static_cast<
      ride_ble_protocol_generated::ScreenConfigurationResult>(rawResult);
  revision = readUInt32LE(data + 9);
  checksum = readUInt32LE(data + 13);
  return true;
}

class UploadReassembler {
public:
  ChunkResult consume(const uint8_t *frame, std::size_t length,
                      uint32_t nowMs) {
    if (!hasMagic(
            frame, length,
            ride_ble_protocol_generated::SCREEN_CONFIGURATION_UPLOAD_MAGIC) ||
        length <= CHUNK_HEADER_BYTES) {
      reset();
      return ChunkResult::Rejected;
    }
    const uint32_t requestID = readUInt32LE(frame + 4);
    const uint32_t baseRevision = readUInt32LE(frame + 8);
    const uint8_t chunkIndex = frame[12];
    const uint8_t chunkCount = frame[13];
    const std::size_t payloadLength = length - CHUNK_HEADER_BYTES;
    if (requestID == 0 || chunkCount == 0 || chunkCount > MAX_CHUNKS ||
        chunkIndex >= chunkCount || payloadLength > MAX_DOCUMENT_BYTES ||
        (active_ && nowMs - lastChunkAtMs_ > REASSEMBLY_TIMEOUT_MS)) {
      reset();
      return ChunkResult::Rejected;
    }
    if (!active_) {
      if (chunkIndex != 0)
        return ChunkResult::Rejected;
      active_ = true;
      requestID_ = requestID;
      baseRevision_ = baseRevision;
      chunkCount_ = chunkCount;
      nextChunkIndex_ = 0;
      payloadLength_ = 0;
    }
    if (requestID != requestID_ || baseRevision != baseRevision_ ||
        chunkCount != chunkCount_ || chunkIndex != nextChunkIndex_ ||
        payloadLength > MAX_DOCUMENT_BYTES - payloadLength_) {
      reset();
      return ChunkResult::Rejected;
    }
    std::memcpy(payload_.data() + payloadLength_,
                frame + CHUNK_HEADER_BYTES, payloadLength);
    payloadLength_ += payloadLength;
    ++nextChunkIndex_;
    lastChunkAtMs_ = nowMs;
    if (nextChunkIndex_ == chunkCount_) {
      complete_ = true;
      active_ = false;
      return ChunkResult::Complete;
    }
    return ChunkResult::Accepted;
  }

  void reset() {
    active_ = false;
    complete_ = false;
    requestID_ = 0;
    baseRevision_ = 0;
    chunkCount_ = 0;
    nextChunkIndex_ = 0;
    payloadLength_ = 0;
    lastChunkAtMs_ = 0;
  }

  bool complete() const { return complete_; }
  uint32_t requestID() const { return requestID_; }
  uint32_t baseRevision() const { return baseRevision_; }
  const uint8_t *payload() const { return payload_.data(); }
  std::size_t payloadLength() const { return payloadLength_; }

private:
  bool active_ = false;
  bool complete_ = false;
  uint32_t requestID_ = 0;
  uint32_t baseRevision_ = 0;
  uint8_t chunkCount_ = 0;
  uint8_t nextChunkIndex_ = 0;
  std::size_t payloadLength_ = 0;
  uint32_t lastChunkAtMs_ = 0;
  std::array<uint8_t, MAX_DOCUMENT_BYTES> payload_{};
};

} // namespace screen_configuration_protocol
