#include "firmware_metadata.hpp"

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
namespace {

static std::string jsonEscape(const std::string &value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (char c : value) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(c);
    } else if (c == '\n') {
      out += "\\n";
    } else if (c == '\r') {
      out += "\\r";
    } else {
      out.push_back(c);
    }
  }
  return out;
}

} // namespace

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
  return std::string("{\"target\":\"") + jsonEscape(target()) +
         "\",\"version\":\"" + jsonEscape(version()) + "\",\"build\":" +
         std::to_string(build()) + ",\"gitSha\":\"" + jsonEscape(gitSha()) +
         "\",\"buildTimestamp\":\"" + jsonEscape(buildTimestamp()) +
         "\",\"updaterProtocol\":" +
         std::to_string(kUpdaterProtocolVersion) + "}";
}

} // namespace firmware_metadata
