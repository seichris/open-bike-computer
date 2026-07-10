#include "../../lib/speaker/sound_protocol.hpp"

#include <cassert>
#include <cstdint>

using waveshare_board::speaker::PlaybackRequest;
using waveshare_board::speaker::Sound;
using waveshare_board::speaker::decodePlayPayload;

int main() {
  PlaybackRequest request{};

  const uint8_t legacy[] = {2};
  assert(decodePlayPayload(legacy, sizeof(legacy), request));
  assert(request.sound == Sound::PlasticBicycleHorn);
  assert(request.volumePercent == 70);

  const uint8_t minimum[] = {1, 0};
  assert(decodePlayPayload(minimum, sizeof(minimum), request));
  assert(request.sound == Sound::BellDing);
  assert(request.volumePercent == 0);

  const uint8_t maximum[] = {5, 100};
  assert(decodePlayPayload(maximum, sizeof(maximum), request));
  assert(request.sound == Sound::SqueezeHorn);
  assert(request.volumePercent == 100);

  const uint8_t unsupported[] = {4, 70};
  const uint8_t excessiveVolume[] = {3, 101};
  const uint8_t extraByte[] = {3, 70, 0};
  assert(!decodePlayPayload(nullptr, 0, request));
  assert(!decodePlayPayload(unsupported, sizeof(unsupported), request));
  assert(!decodePlayPayload(excessiveVolume, sizeof(excessiveVolume), request));
  assert(!decodePlayPayload(extraByte, sizeof(extraByte), request));
}
