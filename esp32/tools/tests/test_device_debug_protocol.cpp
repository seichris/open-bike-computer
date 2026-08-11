#include "../../lib/device_debug/device_debug_protocol.hpp"

#include <array>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>

using namespace device_debug;

int main() {
  static_assert(kFrameHeaderBytes == 32);
  static_assert(kWaveshareAmoled175Geometry.width == 466);
  static_assert(kWaveshareAmoled206Geometry.height == 502);

  const auto topLeft = panelToLvgl(kWaveshareAmoled175Geometry, {0, 0});
  assert(topLeft.x == 0 && topLeft.y == 465);
  const auto topRight = panelToLvgl(kWaveshareAmoled175Geometry, {465, 0});
  assert(topRight.x == 0 && topRight.y == 0);
  const auto bottomLeft = panelToLvgl(kWaveshareAmoled175Geometry, {0, 465});
  assert(bottomLeft.x == 465 && bottomLeft.y == 465);
  const auto bottomRight =
      panelToLvgl(kWaveshareAmoled175Geometry, {465, 465});
  assert(bottomRight.x == 465 && bottomRight.y == 0);
  const auto center = panelToLvgl(kWaveshareAmoled175Geometry, {233, 233});
  assert(center.x == 233 && center.y == 232);
  const auto nativeTopLeft =
      panelToLvgl(kWaveshareAmoled206Geometry, {0, 0});
  assert(nativeTopLeft.x == 0 && nativeTopLeft.y == 0);
  const auto nativeTopRight =
      panelToLvgl(kWaveshareAmoled206Geometry, {409, 0});
  assert(nativeTopRight.x == 409 && nativeTopRight.y == 0);
  const auto nativeBottomLeft =
      panelToLvgl(kWaveshareAmoled206Geometry, {0, 501});
  assert(nativeBottomLeft.x == 0 && nativeBottomLeft.y == 501);
  const auto nativeBottomRight =
      panelToLvgl(kWaveshareAmoled206Geometry, {409, 501});
  assert(nativeBottomRight.x == 409 && nativeBottomRight.y == 501);
  const auto nativeCenter =
      panelToLvgl(kWaveshareAmoled206Geometry, {205, 251});
  assert(nativeCenter.x == 205 && nativeCenter.y == 251);
  assert(!contains(kWaveshareAmoled175Geometry, 466, 0));
  assert(!contains(kWaveshareAmoled206Geometry, 0, 502));

  FrameHeader input;
  input.sequence = 0x12345678;
  input.capturedAtMs = 0x90abcdef;
  input.width = 466;
  input.height = 466;
  input.strideBytes = 932;
  input.payloadBytes = 434312;
  input.payloadCrc32 = 0xa1b2c3d4;
  std::array<uint8_t, kFrameHeaderBytes> bytes{};
  assert(encodeFrameHeader(input, bytes.data(), bytes.size()));
  const uint8_t prefix[] = {'B', 'C', 'F', '1', 0x20, 0x00, 0x00, 0x00,
                            0x78, 0x56, 0x34, 0x12};
  assert(std::memcmp(bytes.data(), prefix, sizeof(prefix)) == 0);
  FrameHeader decoded;
  assert(decodeFrameHeader(bytes.data(), bytes.size(), decoded));
  assert(decoded.sequence == input.sequence);
  assert(decoded.capturedAtMs == input.capturedAtMs);
  assert(decoded.payloadBytes == input.payloadBytes);
  assert(decoded.payloadCrc32 == input.payloadCrc32);

  bytes[0] = 'X';
  assert(!decodeFrameHeader(bytes.data(), bytes.size(), decoded));
  bytes[0] = 'B';
  bytes[22] = 9;
  assert(!decodeFrameHeader(bytes.data(), bytes.size(), decoded));
  encodeFrameHeader(input, bytes.data(), bytes.size());
  bytes[6] = 1;
  assert(!decodeFrameHeader(bytes.data(), bytes.size(), decoded));
  encodeFrameHeader(input, bytes.data(), bytes.size());
  bytes[24] ^= 1;
  assert(!decodeFrameHeader(bytes.data(), bytes.size(), decoded));
  assert(!encodeFrameHeader(input, nullptr, bytes.size()));

  const uint8_t check[] = "123456789";
  assert(crc32(check, 9) == 0xcbf43926U);
  assert(sequenceIsNewer(0, UINT32_MAX));
  assert(!sequenceIsNewer(7, 7));
  assert(!sequenceIsNewer(UINT32_MAX, 0));
  assert(intervalElapsed(3, UINT32_MAX - 5, 8));
  assert(!captureRequestDue(false, true, 0, 100));
  assert(!captureRequestDue(true, false, 0, 100));
  assert(captureRequestDue(true, true, 0, 100));
  assert(!captureRequestDue(true, true, 100, 299));
  assert(captureRequestDue(true, true, 100, 300));

  uint32_t after = 99;
  assert(parseFrameAfterPath("/device-debug/v1/frame?after=0", after));
  assert(after == 0);
  assert(parseFrameAfterPath(
      "/device-debug/v1/frame?after=4294967295", after));
  assert(after == UINT32_MAX);
  assert(!parseFrameAfterPath("/device-debug/v1/frame?after=", after));
  assert(!parseFrameAfterPath("/device-debug/v1/frame?after=-1", after));
  assert(!parseFrameAfterPath(
      "/device-debug/v1/frame?after=4294967296", after));
  assert(!parseFrameAfterPath("/device-debug/v1/frame?after=1&extra=1", after));

  assert(validatePointerEnvelope(true, 64, "application/json") ==
         PointerEnvelopeResult::Accepted);
  assert(validatePointerEnvelope(false, 64, "application/json") ==
         PointerEnvelopeResult::MissingContentLength);
  assert(validatePointerEnvelope(true, 64, "application/json; charset=utf-8") ==
         PointerEnvelopeResult::WrongContentType);
  assert(validatePointerEnvelope(true, 0, "application/json") ==
         PointerEnvelopeResult::InvalidBodyLength);
  assert(validatePointerEnvelope(true, kPointerBodyMaximumBytes + 1,
                                 "application/json") ==
         PointerEnvelopeResult::InvalidBodyLength);

  std::cout << "device debug protocol tests passed\n";
  return 0;
}
