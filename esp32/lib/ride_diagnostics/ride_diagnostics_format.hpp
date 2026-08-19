#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace ride_diagnostics::detail {

constexpr const char *kAllowedFieldKeys[] = {
    "accuracy",                 "accuracyAvailable",       "accuracyBucket",
    "active",                   "activeStage",             "acknowledgedKind",
    "ageMs",                    "alertMode",               "autoPauseEnabled",
    "authorization",            "authorized",               "available",
    "background",               "bootSequence",             "bytes",
    "chunk",                    "code",                     "completedStage",
    "connectionState",          "consecutiveEarlyFailures", "decisionSequence",
    "diagnosticHold",           "domain",                   "droppedCount",
    "durationLimit",            "eventCount",                "expectedState",
    "fallback",                 "firmwareBuild",             "firmwareFingerprint",
    "firmwareTarget",           "firstMissingUptimeMs",       "fixValid",
    "importedCount",            "kind",                      "lastCriticalCategory",
    "lastCriticalEvent",        "lastGapMs",                  "lastMissingUptimeMs",
    "maximumGapMs",              "messageBytes",               "messageDigest",
    "mode",                     "navigating",                "networkTransport",
    "origin",                   "pendingControl",            "profileVersion",
    "ready",                    "reason",                    "resetReason",
    "result",                   "rideDetectionArmed",         "rideGeneration",
    "routeLoaded",              "rssiBucket",                "safeMode",
    "sampleCount",              "scope",                      "sequence",
    "sessionPresent",           "sha256Prefix",               "simulation",
    "sourceHealthMask",         "speedAvailable",              "startMode",
    "state",                    "storage",                    "storageErrorCount",
    "transition",               "viewingMap",                  "workoutActive",
};

constexpr std::size_t kAllowedFieldKeyCount =
    sizeof(kAllowedFieldKeys) / sizeof(kAllowedFieldKeys[0]);

inline bool allowedFieldKey(const char *key, std::size_t length) {
  if (key == nullptr || length == 0 || length > 64)
    return false;
  for (std::size_t index = 0; index < kAllowedFieldKeyCount; ++index) {
    const char *candidate = kAllowedFieldKeys[index];
    if (std::strlen(candidate) == length &&
        std::memcmp(candidate, key, length) == 0)
      return true;
  }
  return false;
}

inline void skipJsonWhitespace(const char *&cursor, const char *end) {
  while (cursor < end && (*cursor == ' ' || *cursor == '\t' ||
                          *cursor == '\n' || *cursor == '\r'))
    ++cursor;
}

inline bool consumeJsonString(const char *&cursor, const char *end,
                              char *capturedKey = nullptr,
                              std::size_t capturedCapacity = 0,
                              std::size_t *capturedLength = nullptr) {
  if (cursor >= end || *cursor != '"')
    return false;
  ++cursor;
  std::size_t length = 0;
  while (cursor < end) {
    const unsigned char byte = static_cast<unsigned char>(*cursor++);
    if (byte == '"') {
      if (capturedKey != nullptr) {
        if (length >= capturedCapacity)
          return false;
        capturedKey[length] = '\0';
      }
      if (capturedLength != nullptr)
        *capturedLength = length;
      return true;
    }
    if (byte < 0x20)
      return false;
    if (byte == '\\') {
      // Field names and values are emitted as simple UTF-8/scalar strings.
      // Accept JSON escapes for forward compatibility, but do not copy an
      // escaped field name into the allowlist buffer.
      if (cursor >= end || capturedKey != nullptr)
        return false;
      const char escaped = *cursor++;
      if (escaped == 'u') {
        if (static_cast<std::size_t>(end - cursor) < 4)
          return false;
        for (int index = 0; index < 4; ++index) {
          const char hex = *cursor++;
          const bool valid = (hex >= '0' && hex <= '9') ||
                             (hex >= 'a' && hex <= 'f') ||
                             (hex >= 'A' && hex <= 'F');
          if (!valid)
            return false;
        }
      } else if (escaped != '"' && escaped != '\\' && escaped != '/' &&
                 escaped != 'b' && escaped != 'f' && escaped != 'n' &&
                 escaped != 'r' && escaped != 't') {
        return false;
      }
      ++length;
    } else {
      if (capturedKey != nullptr) {
        if (length + 1 >= capturedCapacity)
          return false;
        capturedKey[length] = static_cast<char>(byte);
      }
      ++length;
    }
    if (length > 256)
      return false;
  }
  return false;
}

inline bool consumeJsonNumber(const char *&cursor, const char *end) {
  if (cursor >= end)
    return false;
  if (*cursor == '-')
    ++cursor;
  if (cursor >= end)
    return false;
  if (*cursor == '0') {
    ++cursor;
  } else {
    if (*cursor < '1' || *cursor > '9')
      return false;
    while (cursor < end && *cursor >= '0' && *cursor <= '9')
      ++cursor;
  }
  if (cursor < end && *cursor == '.') {
    ++cursor;
    const char *fractionStart = cursor;
    while (cursor < end && *cursor >= '0' && *cursor <= '9')
      ++cursor;
    if (cursor == fractionStart)
      return false;
  }
  if (cursor < end && (*cursor == 'e' || *cursor == 'E')) {
    ++cursor;
    if (cursor < end && (*cursor == '+' || *cursor == '-'))
      ++cursor;
    const char *exponentStart = cursor;
    while (cursor < end && *cursor >= '0' && *cursor <= '9')
      ++cursor;
    if (cursor == exponentStart)
      return false;
  }
  return true;
}

inline bool consumeJsonLiteral(const char *&cursor, const char *end,
                               const char *literal) {
  const std::size_t length = std::strlen(literal);
  if (static_cast<std::size_t>(end - cursor) < length ||
      std::memcmp(cursor, literal, length) != 0)
    return false;
  cursor += length;
  return true;
}

inline bool validateFieldsJson(const char *fieldsJson,
                               std::size_t fieldsLength) {
  if (fieldsJson == nullptr || fieldsLength < 2 || *fieldsJson != '{' ||
      fieldsJson[fieldsLength - 1] != '}')
    return false;
  const char *cursor = fieldsJson + 1;
  const char *end = fieldsJson + fieldsLength;
  skipJsonWhitespace(cursor, end);
  if (cursor < end && *cursor == '}')
    return cursor + 1 == end;

  std::size_t fieldCount = 0;
  while (cursor < end) {
    if (++fieldCount > 32)
      return false;
    char key[65] = {};
    std::size_t keyLength = 0;
    if (!consumeJsonString(cursor, end, key, sizeof(key), &keyLength) ||
        !allowedFieldKey(key, keyLength))
      return false;
    skipJsonWhitespace(cursor, end);
    if (cursor >= end || *cursor++ != ':')
      return false;
    skipJsonWhitespace(cursor, end);
    if (cursor >= end)
      return false;
    if (*cursor == '"') {
      if (!consumeJsonString(cursor, end))
        return false;
    } else if (*cursor == 't') {
      if (!consumeJsonLiteral(cursor, end, "true"))
        return false;
    } else if (*cursor == 'f') {
      if (!consumeJsonLiteral(cursor, end, "false"))
        return false;
    } else if (*cursor == 'n') {
      if (!consumeJsonLiteral(cursor, end, "null"))
        return false;
    } else if (!consumeJsonNumber(cursor, end)) {
      return false;
    }
    skipJsonWhitespace(cursor, end);
    if (cursor >= end)
      return false;
    if (*cursor == '}')
      return cursor + 1 == end;
    if (*cursor++ != ',')
      return false;
    skipJsonWhitespace(cursor, end);
  }
  return false;
}

constexpr uint32_t kFaultCapsuleMagic = 0x52444350; // "RDCP"

struct FaultCapsuleState {
  uint32_t magic;
  uint32_t bootSequence;
  uint32_t firstMissingUptimeMs;
  uint32_t lastMissingUptimeMs;
  uint32_t eventCount;
  uint32_t droppedCount;
  uint32_t storageErrorCount;
  uint32_t resetReason;
  uint16_t activeStage;
  uint16_t completedStage;
  char lastCriticalCategory[24];
  char lastCriticalEvent[48];
};

inline bool validFaultCapsule(const FaultCapsuleState &capsule) {
  return capsule.magic == kFaultCapsuleMagic && capsule.bootSequence != 0 &&
         capsule.eventCount != 0;
}

inline bool formatFaultCapsuleFields(const FaultCapsuleState &capsule,
                                     char *out, std::size_t capacity) {
  if (!validFaultCapsule(capsule) || out == nullptr || capacity == 0)
    return false;
  const int length = std::snprintf(
      out, capacity,
      "{\"bootSequence\":%lu,\"firstMissingUptimeMs\":%lu,"
      "\"lastMissingUptimeMs\":%lu,\"eventCount\":%lu,"
      "\"droppedCount\":%lu,\"storageErrorCount\":%lu,"
      "\"resetReason\":%lu,\"activeStage\":%u,"
      "\"completedStage\":%u,\"lastCriticalCategory\":\"%s\","
      "\"lastCriticalEvent\":\"%s\"}",
      static_cast<unsigned long>(capsule.bootSequence),
      static_cast<unsigned long>(capsule.firstMissingUptimeMs),
      static_cast<unsigned long>(capsule.lastMissingUptimeMs),
      static_cast<unsigned long>(capsule.eventCount),
      static_cast<unsigned long>(capsule.droppedCount),
      static_cast<unsigned long>(capsule.storageErrorCount),
      static_cast<unsigned long>(capsule.resetReason),
      static_cast<unsigned>(capsule.activeStage),
      static_cast<unsigned>(capsule.completedStage),
      capsule.lastCriticalCategory[0] == '\0' ? "unknown"
                                              : capsule.lastCriticalCategory,
      capsule.lastCriticalEvent[0] == '\0' ? "storage_unavailable"
                                           : capsule.lastCriticalEvent);
  return length > 0 && static_cast<std::size_t>(length) < capacity;
}

} // namespace ride_diagnostics::detail
