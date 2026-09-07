#pragma once

#include <cstdint>
#include <string>

namespace firmware_metadata {

static constexpr uint32_t kUpdaterProtocolVersion = 1;

const char *target();
const char *buildProfile();
const char *version();
uint32_t build();
const char *gitSha();
bool hasImmutableGitIdentity();
const char *buildTimestamp();
std::string json();
// Small enough for the existing persistent diagnostics fields budget.
std::string bootAcceptanceJson(bool ready, const char *otaState);

} // namespace firmware_metadata
