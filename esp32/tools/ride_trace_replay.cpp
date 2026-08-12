#include "../lib/ride_automation/ride_automation_policy.hpp"

#include <cstdint>
#include <cmath>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>

namespace {

using ride_automation::ConfirmedLifecycle;
using ride_automation::RideAutomationPolicy;
using ride_automation::RideEvidenceObservation;
using ride_automation::Settings;
using ride_automation::StartMode;
using ride_automation::TimedMetric;
using ride_automation::TimedFlag;
using ride_automation::Transition;

bool parseLifecycle(const std::string &value, ConfirmedLifecycle &result) {
  if (value == "idle")
    result = ConfirmedLifecycle::Idle;
  else if (value == "running")
    result = ConfirmedLifecycle::Running;
  else if (value == "auto_paused")
    result = ConfirmedLifecycle::AutomaticallyPaused;
  else if (value == "manual_paused")
    result = ConfirmedLifecycle::ManuallyPaused;
  else if (value == "finished")
    result = ConfirmedLifecycle::Finished;
  else
    return false;
  return true;
}

bool parseStartMode(const std::string &value, StartMode &result) {
  if (value == "off")
    result = StartMode::Off;
  else if (value == "ask")
    result = StartMode::Ask;
  else if (value == "automatic")
    result = StartMode::Automatic;
  else
    return false;
  return true;
}

bool parseBool(const std::string &value, bool &result) {
  if (value == "1" || value == "true")
    result = true;
  else if (value == "0" || value == "false")
    result = false;
  else
    return false;
  return true;
}

bool parseUInt32(const std::string &value, uint32_t &result) {
  try {
    std::size_t end = 0;
    const unsigned long long parsed = std::stoull(value, &end);
    if (end != value.size() || parsed > std::numeric_limits<uint32_t>::max())
      return false;
    result = static_cast<uint32_t>(parsed);
    return true;
  } catch (...) {
    return false;
  }
}

bool parseMetric(const std::string &value, const std::string &ageValue,
                 uint32_t nowMs, TimedMetric &result) {
  if (value == "-") {
    result = {};
    return ageValue == "-";
  }
  try {
    std::size_t valueEnd = 0;
    const float parsed = std::stof(value, &valueEnd);
    std::size_t ageEnd = 0;
    const unsigned long long parsedAge = std::stoull(ageValue, &ageEnd);
    if (valueEnd != value.size() || ageEnd != ageValue.size() ||
        !std::isfinite(parsed) || parsed < 0.0F ||
        parsedAge > std::numeric_limits<uint32_t>::max())
      return false;
    const uint32_t age = static_cast<uint32_t>(parsedAge);
    result = TimedMetric{true, parsed, nowMs - age, 0};
    return true;
  } catch (...) {
    return false;
  }
}

bool parseFlag(const std::string &value, const std::string &ageValue,
               uint32_t nowMs, TimedFlag &result) {
  if (value == "-") {
    result = {};
    return ageValue == "-";
  }
  bool parsed = false;
  if (!parseBool(value, parsed))
    return false;
  try {
    std::size_t ageEnd = 0;
    const unsigned long long parsedAge = std::stoull(ageValue, &ageEnd);
    if (ageEnd != ageValue.size() ||
        parsedAge > std::numeric_limits<uint32_t>::max())
      return false;
    result = TimedFlag{true, parsed,
                       nowMs - static_cast<uint32_t>(parsedAge), 0};
    return true;
  } catch (...) {
    return false;
  }
}

const char *name(Transition transition) {
  switch (transition) {
  case Transition::None:
    return "none";
  case Transition::Start:
    return "start";
  case Transition::Pause:
    return "pause";
  case Transition::Resume:
    return "resume";
  }
  return "unknown";
}

} // namespace

int main() {
  RideAutomationPolicy policy;
  std::string line;
  uint32_t lineNumber = 0;
  uint32_t previousTimestamp = 0;
  bool hasPreviousTimestamp = false;
  while (std::getline(std::cin, line)) {
    ++lineNumber;
    if (line.empty() || line[0] == '#')
      continue;

    std::istringstream input(line);
    uint32_t nowMs = 0;
    std::string timestampValue;
    std::string lifecycleValue;
    std::string startModeValue;
    std::string autoPauseValue;
    std::string wheel, wheelAge, cadence, cadenceAge, gps, gpsAge;
    std::string gpsFix, gpsFixAge, uncertainty, uncertaintyAge, stationary;
    std::string stationaryAge, displacement, displacementAge, imu, imuAge;
    if (!(input >> timestampValue >> lifecycleValue >> startModeValue >>
          autoPauseValue >> wheel >> wheelAge >> cadence >> cadenceAge >>
          gps >> gpsAge >> gpsFix >> gpsFixAge >> uncertainty >>
          uncertaintyAge >>
          stationary >> stationaryAge >> displacement >> displacementAge >>
          imu >> imuAge)) {
      std::cerr << "invalid replay row " << lineNumber << '\n';
      return 2;
    }
    if (!parseUInt32(timestampValue, nowMs) ||
        (hasPreviousTimestamp &&
         nowMs - previousTimestamp > std::numeric_limits<int32_t>::max())) {
      std::cerr << "invalid replay timestamp on row " << lineNumber << '\n';
      return 2;
    }
    previousTimestamp = nowMs;
    hasPreviousTimestamp = true;
    std::string unexpected;
    if (input >> unexpected) {
      std::cerr << "extra replay field on row " << lineNumber << '\n';
      return 2;
    }

    ConfirmedLifecycle lifecycle;
    Settings settings;
    if (!parseLifecycle(lifecycleValue, lifecycle) ||
        !parseStartMode(startModeValue, settings.startMode) ||
        !parseBool(autoPauseValue, settings.autoPauseEnabled)) {
      std::cerr << "invalid replay enum on row " << lineNumber << '\n';
      return 2;
    }

    RideEvidenceObservation observation;
    if (!parseMetric(wheel, wheelAge, nowMs,
                     observation.wheelSpeedMetersPerSecond) ||
        !parseMetric(cadence, cadenceAge, nowMs,
                     observation.cadenceRpm) ||
        !parseMetric(gps, gpsAge, nowMs,
                     observation.gpsSpeedMetersPerSecond) ||
        !parseFlag(gpsFix, gpsFixAge, nowMs, observation.gpsFixValid) ||
        !parseMetric(uncertainty, uncertaintyAge, nowMs,
                     observation.gpsHorizontalUncertaintyMeters) ||
        !parseFlag(stationary, stationaryAge, nowMs,
                   observation.gpsStationaryWindowValid) ||
        !parseMetric(displacement, displacementAge, nowMs,
                     observation.gpsNetDisplacementMeters) ||
        !parseMetric(imu, imuAge, nowMs, observation.imuMotionScore)) {
      std::cerr << "invalid replay metric on row " << lineNumber << '\n';
      return 2;
    }
    const auto decision = policy.update(nowMs, observation, lifecycle, settings);
    std::cout << nowMs << '\t' << name(decision.transition) << '\t'
              << decision.evidenceMask << '\t' << decision.sequence << '\t'
              << decision.profileVersion << '\t'
              << decision.candidateBeganAtMs << '\n';
  }
  return 0;
}
