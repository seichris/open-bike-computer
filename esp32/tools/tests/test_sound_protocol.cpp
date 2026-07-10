#include "../../lib/speaker/sound_protocol.hpp"

#include <cassert>
#include <cstdint>

using waveshare_board::speaker::PlaybackRequest;
using waveshare_board::speaker::PlayCommandResult;
using waveshare_board::speaker::Sound;
using waveshare_board::speaker::CAPABILITY_DEVICE_SOUNDS;
using waveshare_board::speaker::capabilityFlags;
using waveshare_board::speaker::classifyPlayCommand;
using waveshare_board::speaker::decodePlayPayload;

int main() {
  PlaybackRequest request{};

  assert(capabilityFlags(false) == 0);
  assert(capabilityFlags(true) == CAPABILITY_DEVICE_SOUNDS);

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

  const uint8_t otherCommand[] = {'C', 'A', 'P', 'S'};
  const uint8_t validCommand[] = {'S', 'N', 'D', 'P', 3, 64};
  const uint8_t malformedCommand[] = {'S', 'N', 'D', 'P', 4, 70};
  assert(classifyPlayCommand(otherCommand, sizeof(otherCommand), true, request) ==
         PlayCommandResult::NotMatched);
  assert(classifyPlayCommand(validCommand, sizeof(validCommand), false, request) ==
         PlayCommandResult::RejectedUnauthenticated);
  assert(classifyPlayCommand(malformedCommand, sizeof(malformedCommand), true,
                             request) == PlayCommandResult::RejectedMalformed);
  assert(classifyPlayCommand(validCommand, sizeof(validCommand), true, request) ==
         PlayCommandResult::Accepted);
  assert(request.sound == Sound::RotatingBicycleBell);
  assert(request.volumePercent == 64);
}
