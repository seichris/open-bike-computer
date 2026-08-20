#include "../../lib/ride_diagnostics/ride_diagnostics_format.hpp"

#include <cassert>
#include <cstring>
#include <iostream>

int main() {
  using ride_diagnostics::detail::FaultCapsuleState;
  using ride_diagnostics::detail::formatFaultCapsuleFields;
  using ride_diagnostics::detail::sealFaultCapsule;
  using ride_diagnostics::detail::validateFieldsJson;

  FaultCapsuleState capsule{};
  capsule.bootSequence = 42;
  capsule.firstMissingUptimeMs = 100;
  capsule.lastMissingUptimeMs = 130;
  capsule.eventCount = 3;
  capsule.droppedCount = 2;
  capsule.storageErrorCount = 1;
  capsule.resetReason = 7;
  capsule.activeStage = 11;
  capsule.completedStage = 9;
  std::strcpy(capsule.lastCriticalCategory, "storage");
  std::strcpy(capsule.lastCriticalEvent, "write_failed");
  sealFaultCapsule(capsule);

  char output[512] = {};
  assert(formatFaultCapsuleFields(capsule, output, sizeof(output)));
  assert(std::strcmp(
             output,
             "{\"runtimeBootSequence\":42,\"firstMissingUptimeMs\":100,"
             "\"lastMissingUptimeMs\":130,\"eventCount\":3,"
             "\"droppedCount\":2,\"storageErrorCount\":1,"
             "\"resetReason\":7,\"activeStage\":11,"
             "\"completedStage\":9,\"lastCriticalCategory\":\"storage\","
             "\"lastCriticalEvent\":\"write_failed\"}") == 0);

  capsule.lastCriticalCategory[0] = '\0';
  capsule.lastCriticalEvent[0] = '\0';
  sealFaultCapsule(capsule);
  assert(formatFaultCapsuleFields(capsule, output, sizeof(output)));
  assert(std::strstr(output, "\"lastCriticalCategory\":\"unknown\"") !=
         nullptr);
  assert(std::strstr(
             output, "\"lastCriticalEvent\":\"storage_unavailable\"") !=
         nullptr);

  capsule.magic = 0;
  assert(!formatFaultCapsuleFields(capsule, output, sizeof(output)));
  sealFaultCapsule(capsule);
  assert(!formatFaultCapsuleFields(capsule, output, 16));

  std::memset(capsule.lastCriticalEvent, 'x',
              sizeof(capsule.lastCriticalEvent));
  sealFaultCapsule(capsule);
  assert(!formatFaultCapsuleFields(capsule, output, sizeof(output)));

  const char *validFields =
      "{\"bootSequence\":7,\"ready\":true,"
      "\"firmwareFingerprint\":\"A1B2C3D4\"}";
  assert(validateFieldsJson(validFields, std::strlen(validFields)));
  const char *validEmptyFields = "{}";
  assert(validateFieldsJson(validEmptyFields, 2));
  const char *unknownField = "{\"privateValue\":1}";
  assert(!validateFieldsJson(unknownField, std::strlen(unknownField)));
  const char *nestedField = "{\"ready\":{\"value\":true}}";
  assert(!validateFieldsJson(nestedField, std::strlen(nestedField)));
  const char *malformedField = "{\"ready\":tru}";
  assert(!validateFieldsJson(malformedField, std::strlen(malformedField)));
  const char *wrongBooleanType = "{\"ready\":\"true\"}";
  assert(!validateFieldsJson(wrongBooleanType,
                             std::strlen(wrongBooleanType)));
  const char *wrongNumberType = "{\"bootSequence\":\"7\"}";
  assert(!validateFieldsJson(wrongNumberType, std::strlen(wrongNumberType)));

  std::cout << "ride diagnostics format tests passed\n";
  return 0;
}
