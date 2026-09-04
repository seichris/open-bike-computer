#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace world_radio_protocol {

inline constexpr char REQUEST_MAGIC[] = "WRQ1";
inline constexpr char STATUS_MAGIC[] = "WRS1";
inline constexpr uint8_t VERSION = 1;
inline constexpr std::size_t REQUEST_BYTES = 20;
inline constexpr std::size_t STATUS_HEADER_BYTES = 32;
inline constexpr std::size_t STATUS_MAX_BYTES = 160;
inline constexpr std::size_t STATION_NAME_BYTES = 48;
inline constexpr std::size_t PLACE_BYTES = 28;
inline constexpr std::size_t MESSAGE_BYTES = 24;

inline constexpr uint8_t STATUS_FLAG_FAVORITE = 1U << 0;
inline constexpr uint8_t STATUS_FLAG_HAS_STATION = 1U << 1;

enum class Command : uint8_t {
  SelectLocation = 1,
  RandomStation = 2,
  PlayPause = 3,
  PreviousStation = 4,
  NextStation = 5,
  Stop = 6,
};

enum class PlaybackState : uint8_t {
  Idle = 0,
  Searching = 1,
  Connecting = 2,
  Buffering = 3,
  Playing = 4,
  Paused = 5,
  NoStations = 6,
  Error = 7,
};

struct Request {
  Command command = Command::SelectLocation;
  uint8_t flags = 0;
  uint32_t requestId = 0;
  int32_t latitudeE7 = 0;
  int32_t longitudeE7 = 0;
};

struct Status {
  PlaybackState state = PlaybackState::Idle;
  bool favorite = false;
  bool hasStation = false;
  uint8_t stationIndex = 0;
  uint8_t stationCount = 0;
  uint16_t bitrateKbps = 0;
  uint32_t requestId = 0;
  int32_t stationLatitudeE7 = 0;
  int32_t stationLongitudeE7 = 0;
  char countryCode[3]{};
  char stationName[STATION_NAME_BYTES + 1]{};
  char place[PLACE_BYTES + 1]{};
  char message[MESSAGE_BYTES + 1]{};
};

inline bool isKnownCommand(Command command) {
  switch (command) {
  case Command::SelectLocation:
  case Command::RandomStation:
  case Command::PlayPause:
  case Command::PreviousStation:
  case Command::NextStation:
  case Command::Stop:
    return true;
  }
  return false;
}

inline bool isKnownState(PlaybackState state) {
  switch (state) {
  case PlaybackState::Idle:
  case PlaybackState::Searching:
  case PlaybackState::Connecting:
  case PlaybackState::Buffering:
  case PlaybackState::Playing:
  case PlaybackState::Paused:
  case PlaybackState::NoStations:
  case PlaybackState::Error:
    return true;
  }
  return false;
}

inline void writeU16(uint8_t *output, uint16_t value) {
  output[0] = static_cast<uint8_t>(value);
  output[1] = static_cast<uint8_t>(value >> 8);
}

inline void writeU32(uint8_t *output, uint32_t value) {
  output[0] = static_cast<uint8_t>(value);
  output[1] = static_cast<uint8_t>(value >> 8);
  output[2] = static_cast<uint8_t>(value >> 16);
  output[3] = static_cast<uint8_t>(value >> 24);
}

inline uint16_t readU16(const uint8_t *input) {
  return static_cast<uint16_t>(input[0]) |
         (static_cast<uint16_t>(input[1]) << 8);
}

inline uint32_t readU32(const uint8_t *input) {
  return static_cast<uint32_t>(input[0]) |
         (static_cast<uint32_t>(input[1]) << 8) |
         (static_cast<uint32_t>(input[2]) << 16) |
         (static_cast<uint32_t>(input[3]) << 24);
}

inline std::size_t boundedLength(const char *text, std::size_t maximum) {
  if (text == nullptr) {
    return 0;
  }
  std::size_t length = 0;
  while (length < maximum && text[length] != '\0') {
    ++length;
  }
  return length;
}

inline bool validCoordinate(int32_t latitudeE7, int32_t longitudeE7) {
  return latitudeE7 >= -900000000 && latitudeE7 <= 900000000 &&
         longitudeE7 >= -1800000000 && longitudeE7 <= 1800000000;
}

inline bool encodeRequest(const Request &request, uint8_t *output,
                          std::size_t capacity) {
  if (output == nullptr || capacity < REQUEST_BYTES || request.requestId == 0 ||
      !isKnownCommand(request.command)) {
    return false;
  }
  if (request.command == Command::SelectLocation &&
      !validCoordinate(request.latitudeE7, request.longitudeE7)) {
    return false;
  }

  std::memset(output, 0, REQUEST_BYTES);
  std::memcpy(output, REQUEST_MAGIC, 4);
  output[4] = VERSION;
  output[5] = static_cast<uint8_t>(request.command);
  output[6] = request.flags;
  writeU32(output + 8, request.requestId);
  writeU32(output + 12, static_cast<uint32_t>(request.latitudeE7));
  writeU32(output + 16, static_cast<uint32_t>(request.longitudeE7));
  return true;
}

inline bool decodeRequest(const uint8_t *input, std::size_t length,
                          Request &request) {
  if (input == nullptr || length != REQUEST_BYTES ||
      std::memcmp(input, REQUEST_MAGIC, 4) != 0 || input[4] != VERSION ||
      input[7] != 0) {
    return false;
  }
  const Command command = static_cast<Command>(input[5]);
  const uint32_t requestId = readU32(input + 8);
  const int32_t latitudeE7 = static_cast<int32_t>(readU32(input + 12));
  const int32_t longitudeE7 = static_cast<int32_t>(readU32(input + 16));
  if (!isKnownCommand(command) || requestId == 0 ||
      (command == Command::SelectLocation &&
       !validCoordinate(latitudeE7, longitudeE7))) {
    return false;
  }
  request.command = command;
  request.flags = input[6];
  request.requestId = requestId;
  request.latitudeE7 = latitudeE7;
  request.longitudeE7 = longitudeE7;
  return true;
}

inline bool encodeStatus(const Status &status, uint8_t *output,
                         std::size_t capacity, std::size_t &written) {
  written = 0;
  if (output == nullptr || status.requestId == 0 ||
      !isKnownState(status.state)) {
    return false;
  }
  const std::size_t nameLength =
      boundedLength(status.stationName, STATION_NAME_BYTES);
  const std::size_t placeLength = boundedLength(status.place, PLACE_BYTES);
  const std::size_t messageLength = boundedLength(status.message, MESSAGE_BYTES);
  const std::size_t total = STATUS_HEADER_BYTES + nameLength + placeLength +
                            messageLength;
  if (total > STATUS_MAX_BYTES || capacity < total) {
    return false;
  }

  std::memset(output, 0, total);
  std::memcpy(output, STATUS_MAGIC, 4);
  output[4] = VERSION;
  output[5] = static_cast<uint8_t>(status.state);
  output[6] = (status.favorite ? STATUS_FLAG_FAVORITE : 0) |
              (status.hasStation ? STATUS_FLAG_HAS_STATION : 0);
  output[7] = status.stationIndex;
  output[8] = status.stationCount;
  writeU16(output + 10, status.bitrateKbps);
  writeU32(output + 12, status.requestId);
  writeU32(output + 16, static_cast<uint32_t>(status.stationLatitudeE7));
  writeU32(output + 20, static_cast<uint32_t>(status.stationLongitudeE7));
  output[24] = static_cast<uint8_t>(status.countryCode[0]);
  output[25] = static_cast<uint8_t>(status.countryCode[1]);
  output[26] = static_cast<uint8_t>(nameLength);
  output[27] = static_cast<uint8_t>(placeLength);
  output[28] = static_cast<uint8_t>(messageLength);

  std::size_t cursor = STATUS_HEADER_BYTES;
  std::memcpy(output + cursor, status.stationName, nameLength);
  cursor += nameLength;
  std::memcpy(output + cursor, status.place, placeLength);
  cursor += placeLength;
  std::memcpy(output + cursor, status.message, messageLength);
  written = total;
  return true;
}

inline bool decodeStatus(const uint8_t *input, std::size_t length,
                         Status &status) {
  if (input == nullptr || length < STATUS_HEADER_BYTES ||
      length > STATUS_MAX_BYTES || std::memcmp(input, STATUS_MAGIC, 4) != 0 ||
      input[4] != VERSION || input[9] != 0 || input[29] != 0 ||
      input[30] != 0 || input[31] != 0) {
    return false;
  }
  const PlaybackState state = static_cast<PlaybackState>(input[5]);
  const std::size_t nameLength = input[26];
  const std::size_t placeLength = input[27];
  const std::size_t messageLength = input[28];
  const std::size_t expectedLength = STATUS_HEADER_BYTES + nameLength +
                                     placeLength + messageLength;
  const uint32_t requestId = readU32(input + 12);
  if (!isKnownState(state) || requestId == 0 || expectedLength != length ||
      nameLength > STATION_NAME_BYTES || placeLength > PLACE_BYTES ||
      messageLength > MESSAGE_BYTES) {
    return false;
  }

  Status decoded{};
  decoded.state = state;
  decoded.favorite = (input[6] & STATUS_FLAG_FAVORITE) != 0;
  decoded.hasStation = (input[6] & STATUS_FLAG_HAS_STATION) != 0;
  decoded.stationIndex = input[7];
  decoded.stationCount = input[8];
  decoded.bitrateKbps = readU16(input + 10);
  decoded.requestId = requestId;
  decoded.stationLatitudeE7 = static_cast<int32_t>(readU32(input + 16));
  decoded.stationLongitudeE7 = static_cast<int32_t>(readU32(input + 20));
  decoded.countryCode[0] = static_cast<char>(input[24]);
  decoded.countryCode[1] = static_cast<char>(input[25]);
  decoded.countryCode[2] = '\0';

  std::size_t cursor = STATUS_HEADER_BYTES;
  std::memcpy(decoded.stationName, input + cursor, nameLength);
  cursor += nameLength;
  std::memcpy(decoded.place, input + cursor, placeLength);
  cursor += placeLength;
  std::memcpy(decoded.message, input + cursor, messageLength);
  status = decoded;
  return true;
}

} // namespace world_radio_protocol
