#pragma once

#include <cstdint>
#include <cstring>
#include <string>

namespace ride_diagnostics::control {

enum class CaptureMode : uint8_t { Standard = 0, Detailed = 1 };

struct CaptureBinding {
  CaptureMode mode = CaptureMode::Standard;
  std::string captureId;
};

struct IssueMarker {
  uint32_t sequence = 0;
  std::string code;
};

inline bool bindingRequiresChunkBoundary(
    const char *currentCaptureId, CaptureMode currentMode,
    const char *nextCaptureId, CaptureMode nextMode) {
  if (currentCaptureId == nullptr || nextCaptureId == nullptr)
    return true;
  return std::strcmp(currentCaptureId, nextCaptureId) != 0 ||
         currentMode != nextMode;
}

inline bool markerSequenceCanAdvance(uint32_t previous, uint32_t next) {
  return next != 0 && next > previous;
}

inline uint32_t markerSequenceAfterBinding(
    const char *currentCaptureId, const char *nextCaptureId,
    uint32_t previousMarkerSequence) {
  if (currentCaptureId == nullptr || nextCaptureId == nullptr ||
      std::strcmp(currentCaptureId, nextCaptureId) != 0) {
    return 0;
  }
  return previousMarkerSequence;
}

inline bool parsePositiveUint32(const std::string &value, uint32_t &out) {
  if (value.empty() || value.size() > 10)
    return false;
  uint64_t parsed = 0;
  for (char byte : value) {
    if (byte < '0' || byte > '9')
      return false;
    parsed = parsed * 10U + static_cast<unsigned>(byte - '0');
    if (parsed > UINT32_MAX)
      return false;
  }
  if (parsed == 0)
    return false;
  out = static_cast<uint32_t>(parsed);
  return true;
}

inline bool parseCaptureBinding(const std::string &command,
                                CaptureBinding &binding) {
  constexpr char prefix[] = "capture|1|";
  if (command.rfind(prefix, 0) != 0 || command.size() <= sizeof(prefix))
    return false;
  const std::size_t modeEnd = command.find('|', sizeof(prefix) - 1);
  if (modeEnd == std::string::npos)
    return false;
  const std::string mode =
      command.substr(sizeof(prefix) - 1, modeEnd - (sizeof(prefix) - 1));
  if (mode == "standard")
    binding.mode = CaptureMode::Standard;
  else if (mode == "detailed")
    binding.mode = CaptureMode::Detailed;
  else
    return false;
  binding.captureId = command.substr(modeEnd + 1);
  return !binding.captureId.empty() &&
         binding.captureId.find('|') == std::string::npos;
}

inline bool parseIssueMarker(const std::string &command, IssueMarker &marker) {
  constexpr char prefix[] = "mark|1|";
  if (command.rfind(prefix, 0) != 0 || command.size() <= sizeof(prefix))
    return false;
  const std::size_t sequenceEnd = command.find('|', sizeof(prefix) - 1);
  if (sequenceEnd == std::string::npos ||
      !parsePositiveUint32(
          command.substr(sizeof(prefix) - 1,
                         sequenceEnd - (sizeof(prefix) - 1)),
          marker.sequence)) {
    return false;
  }
  marker.code = command.substr(sequenceEnd + 1);
  return !marker.code.empty() && marker.code.find('|') == std::string::npos;
}

} // namespace ride_diagnostics::control
