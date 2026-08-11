#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>

namespace device_debug {

constexpr uint16_t kFrameHeaderBytes = 32;
constexpr uint8_t kRgb565LittleEndianPixelFormat = 1;
constexpr uint8_t kPanelOriented = 0;
constexpr uint32_t kCaptureIntervalMs = 200;
constexpr uint32_t kPointerMinimumIntervalMs = 8;
constexpr uint32_t kPointerFailSafeMs = 1500;
constexpr uint64_t kPointerBodyMaximumBytes = 256;
inline constexpr char kFrameRoutePrefix[] = "/device-debug/v1/frame?after=";

enum class PointerEnvelopeResult : uint8_t {
  Accepted,
  MissingContentLength,
  WrongContentType,
  InvalidBodyLength,
};

inline PointerEnvelopeResult validatePointerEnvelope(
    bool hasContentLength, uint64_t contentLength,
    const std::string &contentType) {
  if (!hasContentLength)
    return PointerEnvelopeResult::MissingContentLength;
  if (contentType != "application/json")
    return PointerEnvelopeResult::WrongContentType;
  if (contentLength == 0 || contentLength > kPointerBodyMaximumBytes)
    return PointerEnvelopeResult::InvalidBodyLength;
  return PointerEnvelopeResult::Accepted;
}

inline bool parseFrameAfterPath(const std::string &path,
                                uint32_t &afterSequence) {
  constexpr size_t kPrefixLength = sizeof(kFrameRoutePrefix) - 1;
  if (path.compare(0, kPrefixLength, kFrameRoutePrefix) != 0)
    return false;
  const std::string value = path.substr(kPrefixLength);
  if (value.empty() || value.size() > 10)
    return false;
  uint64_t parsed = 0;
  for (char character : value) {
    if (character < '0' || character > '9')
      return false;
    parsed = parsed * 10U + static_cast<uint64_t>(character - '0');
    if (parsed > std::numeric_limits<uint32_t>::max())
      return false;
  }
  afterSequence = static_cast<uint32_t>(parsed);
  return true;
}

struct TargetGeometry {
  uint16_t width = 0;
  uint16_t height = 0;
  uint8_t panelToLvglRotation = 0;
};

constexpr TargetGeometry kWaveshareAmoled175Geometry{466, 466, 1};
constexpr TargetGeometry kWaveshareAmoled206Geometry{410, 502, 0};

struct Point {
  uint16_t x = 0;
  uint16_t y = 0;
};

constexpr bool contains(const TargetGeometry &geometry, uint16_t x,
                        uint16_t y) {
  return geometry.width != 0 && geometry.height != 0 && x < geometry.width &&
         y < geometry.height;
}

// Browser coordinates describe the already panel-oriented framebuffer. This
// is the same inverse rotation applied to physical touch before LVGL sees it.
constexpr Point panelToLvgl(const TargetGeometry &geometry, Point panel) {
  if (!contains(geometry, panel.x, panel.y))
    return {};
  const uint16_t maxX = static_cast<uint16_t>(geometry.width - 1);
  const uint16_t maxY = static_cast<uint16_t>(geometry.height - 1);
  switch (geometry.panelToLvglRotation & 0x03U) {
  case 1:
    return {panel.y, static_cast<uint16_t>(maxY - panel.x)};
  case 2:
    return {static_cast<uint16_t>(maxX - panel.x),
            static_cast<uint16_t>(maxY - panel.y)};
  case 3:
    return {static_cast<uint16_t>(maxX - panel.y), panel.x};
  default:
    return panel;
  }
}

constexpr bool sequenceIsNewer(uint32_t candidate, uint32_t previous) {
  return candidate != previous &&
         static_cast<int32_t>(candidate - previous) > 0;
}

constexpr bool intervalElapsed(uint32_t nowMs, uint32_t previousMs,
                               uint32_t intervalMs) {
  return nowMs - previousMs >= intervalMs;
}

constexpr bool captureRequestDue(bool active, bool requested,
                                 uint32_t lastCaptureMs, uint32_t nowMs) {
  return active && requested &&
         (lastCaptureMs == 0 ||
          intervalElapsed(nowMs, lastCaptureMs, kCaptureIntervalMs));
}

struct FrameHeader {
  uint16_t headerBytes = kFrameHeaderBytes;
  uint16_t flags = 0;
  uint32_t sequence = 0;
  uint32_t capturedAtMs = 0;
  uint16_t width = 0;
  uint16_t height = 0;
  uint16_t strideBytes = 0;
  uint8_t pixelFormat = kRgb565LittleEndianPixelFormat;
  uint8_t orientation = kPanelOriented;
  uint32_t payloadBytes = 0;
  uint32_t payloadCrc32 = 0;
};

inline void writeUInt16Le(uint8_t *output, uint16_t value) {
  output[0] = static_cast<uint8_t>(value);
  output[1] = static_cast<uint8_t>(value >> 8U);
}

inline void writeUInt32Le(uint8_t *output, uint32_t value) {
  for (uint8_t index = 0; index < 4; ++index)
    output[index] = static_cast<uint8_t>(value >> (index * 8U));
}

inline uint16_t readUInt16Le(const uint8_t *input) {
  return static_cast<uint16_t>(input[0]) |
         static_cast<uint16_t>(input[1] << 8U);
}

inline uint32_t readUInt32Le(const uint8_t *input) {
  uint32_t value = 0;
  for (uint8_t index = 0; index < 4; ++index)
    value |= static_cast<uint32_t>(input[index]) << (index * 8U);
  return value;
}

inline bool encodeFrameHeader(const FrameHeader &header, uint8_t *output,
                              size_t capacity) {
  if (output == nullptr || capacity < kFrameHeaderBytes)
    return false;
  output[0] = 'B';
  output[1] = 'C';
  output[2] = 'F';
  output[3] = '1';
  writeUInt16Le(output + 4, header.headerBytes);
  writeUInt16Le(output + 6, header.flags);
  writeUInt32Le(output + 8, header.sequence);
  writeUInt32Le(output + 12, header.capturedAtMs);
  writeUInt16Le(output + 16, header.width);
  writeUInt16Le(output + 18, header.height);
  writeUInt16Le(output + 20, header.strideBytes);
  output[22] = header.pixelFormat;
  output[23] = header.orientation;
  writeUInt32Le(output + 24, header.payloadBytes);
  writeUInt32Le(output + 28, header.payloadCrc32);
  return true;
}

inline bool decodeFrameHeader(const uint8_t *input, size_t length,
                              FrameHeader &header) {
  if (input == nullptr || length < kFrameHeaderBytes || input[0] != 'B' ||
      input[1] != 'C' || input[2] != 'F' || input[3] != '1')
    return false;
  header.headerBytes = readUInt16Le(input + 4);
  header.flags = readUInt16Le(input + 6);
  header.sequence = readUInt32Le(input + 8);
  header.capturedAtMs = readUInt32Le(input + 12);
  header.width = readUInt16Le(input + 16);
  header.height = readUInt16Le(input + 18);
  header.strideBytes = readUInt16Le(input + 20);
  header.pixelFormat = input[22];
  header.orientation = input[23];
  header.payloadBytes = readUInt32Le(input + 24);
  header.payloadCrc32 = readUInt32Le(input + 28);
  if (header.headerBytes < kFrameHeaderBytes || header.flags != 0 ||
      header.pixelFormat != kRgb565LittleEndianPixelFormat ||
      header.orientation != kPanelOriented || header.width == 0 ||
      header.height == 0 ||
      header.strideBytes < static_cast<uint32_t>(header.width) * 2U)
    return false;
  const uint64_t expectedPayload =
      static_cast<uint64_t>(header.strideBytes) * header.height;
  return expectedPayload == header.payloadBytes;
}

inline uint32_t crc32(const uint8_t *data, size_t length) {
  uint32_t crc = 0xffffffffU;
  for (size_t index = 0; index < length; ++index) {
    crc ^= data[index];
    for (uint8_t bit = 0; bit < 8; ++bit)
      crc = (crc >> 1U) ^ (0xedb88320U & (0U - (crc & 1U)));
  }
  return ~crc;
}

} // namespace device_debug
