#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace ride_diagnostics::detail {

constexpr const char *kAllowedFieldKeys[] = {
    "accuracy", "accuracyAvailable", "accuracyBucket", "acknowledgedKind",
    "active", "activeStage", "ageMs", "alertMode",
    "applyErrorCode", "applyErrorDomain", "applyResult", "attempt",
    "attemptId", "authorization", "authorized", "autoPauseEnabled",
    "available", "background", "blockLoadMs", "bootSequence",
    "bytes", "chunk", "class", "clockSynchronized",
    "code", "commandClass", "completedStage", "connectCompleted",
    "connectDurationMs", "connectStarted", "connectionGeneration", "connectionReused",
    "connectionState", "consecutiveEarlyFailures", "controllerRole", "decisionSequence",
    "diagnosticHold", "domain", "droppedCount", "durationLimit",
    "durationMs", "enqueuedCount", "errorCode", "errorDomain",
    "eventCount", "expectedState", "fallback", "featureFlags",
    "firmwareBuild", "firmwareFingerprint", "firmwareTarget", "firstMissingUptimeMs",
    "fixValid", "formatVersion", "generation", "highWater",
    "highWaterBytes", "httpStatus", "importedCount", "kind",
    "lastCriticalCategory", "lastCriticalEvent", "lastFailureCompletedStage", "lastFailureResetReason",
    "lastFailureStage", "lastGapMs", "lastMissingUptimeMs", "latencyMs",
    "leaseGeneration", "localAccessorySubnet", "mapDetail", "mapId",
    "mapPhase", "mapProgressMs", "maxQueueDepth", "maximumGapMs",
    "members", "messageBytes", "messageDigest", "mode",
    "navigating", "networkObservation", "networkProtocol", "networkTransport",
    "origin", "outcome", "pendingControl", "phase",
    "profileVersion", "proxyConnection", "queueBytes", "queueDepth",
    "ready", "reason", "rejectedCount", "remoteEndpointMatched",
    "replacedCount", "resetReason", "result", "retries",
    "rideDetectionArmed", "rideGeneration", "role", "routeLoaded",
    "rssiBucket", "runtimeBootSequence", "safeMode", "sampleCount",
    "schemaVersion", "scope", "sequence", "sessionPresent",
    "sha256Prefix", "simulation", "sizeBucket", "sourceHealthMask",
    "speedAvailable", "startMode", "state", "storage",
    "storageErrorCount", "tlsChallenge", "tlsCompleted", "tlsDurationMs",
    "tlsStarted", "transition", "uiPhase", "uiProgressMs",
    "underlyingErrorCode", "underlyingErrorDomain", "viewingMap", "visitedEntries",
    "waitedForConnectivity", "watchSequence", "watchUptimeMs", "watchdogCoreMask",
    "watchdogUptimeMs", "workoutActive", "writerDetail", "writerPhase",
    "writerProgressMs", "writtenCount",
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

enum class FieldValueKind : uint8_t { String, Number, Boolean, Null };

inline bool fieldKeyIn(const char *key, const char *const *keys,
                       std::size_t count) {
  for (std::size_t index = 0; index < count; ++index) {
    if (std::strcmp(key, keys[index]) == 0)
      return true;
  }
  return false;
}

inline bool allowedFieldValueKind(const char *key, FieldValueKind kind) {
static constexpr const char *kNumberKeys[] = {
      "accuracy", "activeStage", "ageMs", "alertMode",
      "applyErrorCode", "attempt", "blockLoadMs", "bootSequence",
      "bytes", "chunk", "commandClass", "completedStage",
      "connectDurationMs", "connectionGeneration", "consecutiveEarlyFailures", "decisionSequence",
      "droppedCount", "durationMs", "enqueuedCount", "errorCode",
      "eventCount", "firmwareBuild", "firstMissingUptimeMs", "formatVersion",
      "generation", "highWater", "highWaterBytes", "httpStatus",
      "importedCount", "lastFailureCompletedStage", "lastFailureResetReason", "lastFailureStage",
      "lastGapMs", "lastMissingUptimeMs", "latencyMs", "leaseGeneration",
      "mapDetail", "mapProgressMs", "maxQueueDepth", "maximumGapMs",
      "members", "messageBytes", "profileVersion", "queueBytes",
      "queueDepth", "rejectedCount", "replacedCount", "resetReason",
      "retries", "rideGeneration", "runtimeBootSequence", "sampleCount",
      "schemaVersion", "sequence", "sourceHealthMask", "storageErrorCount",
      "tlsDurationMs", "uiProgressMs", "underlyingErrorCode", "visitedEntries",
      "watchSequence", "watchUptimeMs", "watchdogCoreMask", "watchdogUptimeMs",
      "writerDetail", "writerProgressMs", "writtenCount",
  };
static constexpr const char *kBooleanKeys[] = {
      "accuracyAvailable", "active", "authorized", "autoPauseEnabled",
      "available", "background", "clockSynchronized", "connectCompleted",
      "connectStarted", "connectionReused", "diagnosticHold", "fallback",
      "fixValid", "localAccessorySubnet", "navigating", "pendingControl",
      "proxyConnection", "ready", "remoteEndpointMatched", "rideDetectionArmed",
      "routeLoaded", "safeMode", "sessionPresent", "simulation",
      "speedAvailable", "tlsCompleted", "tlsStarted", "viewingMap",
      "waitedForConnectivity", "workoutActive",
  };
  if (fieldKeyIn(key, kNumberKeys,
                 sizeof(kNumberKeys) / sizeof(kNumberKeys[0])))
    return kind == FieldValueKind::Number;
  if (fieldKeyIn(key, kBooleanKeys,
                 sizeof(kBooleanKeys) / sizeof(kBooleanKeys[0])))
    return kind == FieldValueKind::Boolean;
  return kind == FieldValueKind::String;
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
    FieldValueKind valueKind = FieldValueKind::Null;
    if (*cursor == '"') {
      if (!consumeJsonString(cursor, end))
        return false;
      valueKind = FieldValueKind::String;
    } else if (*cursor == 't') {
      if (!consumeJsonLiteral(cursor, end, "true"))
        return false;
      valueKind = FieldValueKind::Boolean;
    } else if (*cursor == 'f') {
      if (!consumeJsonLiteral(cursor, end, "false"))
        return false;
      valueKind = FieldValueKind::Boolean;
    } else if (*cursor == 'n') {
      if (!consumeJsonLiteral(cursor, end, "null"))
        return false;
      valueKind = FieldValueKind::Null;
    } else if (!consumeJsonNumber(cursor, end)) {
      return false;
    } else {
      valueKind = FieldValueKind::Number;
    }
    if (!allowedFieldValueKind(key, valueKind))
      return false;
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
constexpr uint16_t kFaultCapsuleSchema = 1;

struct FaultCapsuleState {
  uint32_t magic;
  uint16_t schema;
  uint16_t size;
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
  uint32_t checksum;
};

inline uint32_t faultCapsuleChecksum(const FaultCapsuleState &capsule) {
  const auto *bytes = reinterpret_cast<const uint8_t *>(&capsule);
  uint32_t checksum = 2166136261U;
  for (std::size_t index = 0; index < offsetof(FaultCapsuleState, checksum);
       ++index) {
    checksum ^= bytes[index];
    checksum *= 16777619U;
  }
  return checksum;
}

inline void sealFaultCapsule(FaultCapsuleState &capsule) {
  capsule.magic = kFaultCapsuleMagic;
  capsule.schema = kFaultCapsuleSchema;
  capsule.size = sizeof(FaultCapsuleState);
  capsule.checksum = faultCapsuleChecksum(capsule);
}

inline bool validFaultCapsuleEnvelope(const FaultCapsuleState &capsule) {
  return capsule.magic == kFaultCapsuleMagic &&
         capsule.schema == kFaultCapsuleSchema &&
         capsule.size == sizeof(FaultCapsuleState) &&
         capsule.bootSequence != 0 &&
         std::memchr(capsule.lastCriticalCategory, '\0',
                     sizeof(capsule.lastCriticalCategory)) != nullptr &&
         std::memchr(capsule.lastCriticalEvent, '\0',
                     sizeof(capsule.lastCriticalEvent)) != nullptr &&
         capsule.checksum == faultCapsuleChecksum(capsule);
}

inline bool validFaultCapsule(const FaultCapsuleState &capsule) {
  return validFaultCapsuleEnvelope(capsule) && capsule.eventCount != 0;
}

inline bool faultCapsuleIdentityMatches(const FaultCapsuleState &capsule,
                                        uint32_t bootSequence,
                                        uint32_t checksum) {
  return validFaultCapsuleEnvelope(capsule) &&
         capsule.bootSequence == bootSequence && capsule.checksum == checksum;
}

inline bool formatFaultCapsuleFields(const FaultCapsuleState &capsule,
                                     char *out, std::size_t capacity) {
  if (!validFaultCapsule(capsule) || out == nullptr || capacity == 0)
    return false;
  const int length = std::snprintf(
      out, capacity,
      "{\"runtimeBootSequence\":%lu,\"firstMissingUptimeMs\":%lu,"
      "\"lastMissingUptimeMs\":%lu,\"eventCount\":%lu,"
      "\"droppedCount\":%lu,\"storageErrorCount\":%lu,"
      "\"resetReason\":%lu,\"activeStage\":%u,"
      "\"completedStage\":%u,\"lastCriticalCategory\":\"%.*s\","
      "\"lastCriticalEvent\":\"%.*s\"}",
      static_cast<unsigned long>(capsule.bootSequence),
      static_cast<unsigned long>(capsule.firstMissingUptimeMs),
      static_cast<unsigned long>(capsule.lastMissingUptimeMs),
      static_cast<unsigned long>(capsule.eventCount),
      static_cast<unsigned long>(capsule.droppedCount),
      static_cast<unsigned long>(capsule.storageErrorCount),
      static_cast<unsigned long>(capsule.resetReason),
      static_cast<unsigned>(capsule.activeStage),
      static_cast<unsigned>(capsule.completedStage),
      static_cast<int>(sizeof(capsule.lastCriticalCategory) - 1),
      capsule.lastCriticalCategory[0] == '\0' ? "unknown"
                                              : capsule.lastCriticalCategory,
      static_cast<int>(sizeof(capsule.lastCriticalEvent) - 1),
      capsule.lastCriticalEvent[0] == '\0' ? "storage_unavailable"
                                           : capsule.lastCriticalEvent);
  return length > 0 && static_cast<std::size_t>(length) < capacity;
}

} // namespace ride_diagnostics::detail
