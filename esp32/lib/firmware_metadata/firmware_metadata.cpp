#include "firmware_metadata.hpp"
#include "../status_json/status_json.hpp"

#ifndef VERSION
#define VERSION "0.0.0"
#endif

#ifndef REVISION
#define REVISION 0
#endif

#ifndef FLAVOR
#define FLAVOR "unknown"
#endif

#ifndef BUILD_PROFILE
#define BUILD_PROFILE "unknown"
#endif

#ifndef GIT_SHA
#define GIT_SHA "unknown"
#endif

#ifndef BUILD_TIMESTAMP
#define BUILD_TIMESTAMP "unknown"
#endif

namespace firmware_metadata {
const char *target() { return FLAVOR; }

const char *buildProfile() { return BUILD_PROFILE; }

const char *version() { return VERSION; }

uint32_t build() { return static_cast<uint32_t>(REVISION); }

const char *gitSha() { return GIT_SHA; }

bool hasImmutableGitIdentity() {
  const std::string value = gitSha();
  if (value.size() != 40)
    return false;
  for (const char character : value) {
    const bool decimal = character >= '0' && character <= '9';
    const bool lowercaseHex = character >= 'a' && character <= 'f';
    if (!decimal && !lowercaseHex)
      return false;
  }
  return true;
}

const char *buildTimestamp() { return BUILD_TIMESTAMP; }

std::string json() {
  std::string body = "{\"target\":\"";
  body += status_json::escape(target());
  body += "\"";
  status_json::appendStringField(body, "version", version());
  status_json::appendUnsignedField(body, "build", build());
  status_json::appendStringField(body, "gitSha", gitSha());
  status_json::appendStringField(body, "buildTimestamp", buildTimestamp());
  status_json::appendUnsignedField(body, "updaterProtocol",
                                   kUpdaterProtocolVersion);
  body += "}";
  return body;
}

std::string bootAcceptanceJson(bool ready, const char *otaState) {
  std::string body = "{\"schemaVersion\":1";
  status_json::appendStringField(body, "firmwareTarget", target());
  status_json::appendStringField(body, "firmwareProfile", buildProfile());
  status_json::appendStringField(body, "firmwareVersion", version());
  status_json::appendUnsignedField(body, "firmwareBuild", build());
  status_json::appendStringField(body, "firmwareGitSha", gitSha());
  status_json::appendBoolField(body, "ready", ready);
  status_json::appendStringField(
      body, "otaState", otaState == nullptr ? "unknown" : otaState);
  body += "}";
  return body;
}

} // namespace firmware_metadata
