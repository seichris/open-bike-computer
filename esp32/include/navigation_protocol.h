#pragma once

#include <ctype.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

static constexpr size_t NAV_PAYLOAD_MAX_LEN = 96;
static constexpr size_t NAV_INSTRUCTION_MAX_LEN = 63;

struct NavigationData {
  uint8_t iconID;
  uint32_t distance;
  char instruction[NAV_INSTRUCTION_MAX_LEN + 1];
};

inline bool isValidNavigationIcon(uint8_t iconID) {
  return iconID >= 1 && iconID <= 4;
}

inline bool parseUnsignedField(const char *start, const char *end, uint32_t maxValue, uint32_t *out) {
  if (start == nullptr || end == nullptr || out == nullptr || start >= end) {
    return false;
  }

  uint32_t value = 0;
  for (const char *cursor = start; cursor < end; cursor++) {
    if (!isdigit((unsigned char)*cursor)) {
      return false;
    }

    uint32_t digit = (uint32_t)(*cursor - '0');
    if (value > (maxValue - digit) / 10) {
      return false;
    }

    value = (value * 10) + digit;
  }

  *out = value;
  return true;
}

inline bool parseNavigationData(const char *payload, NavigationData *parsed) {
  if (payload == nullptr || parsed == nullptr) {
    return false;
  }

  if (strlen(payload) > NAV_PAYLOAD_MAX_LEN) {
    return false;
  }

  const char *firstPipe = strchr(payload, '|');
  const char *secondPipe = firstPipe == nullptr ? nullptr : strchr(firstPipe + 1, '|');
  if (firstPipe == nullptr || secondPipe == nullptr || strchr(secondPipe + 1, '|') != nullptr) {
    return false;
  }

  uint32_t iconValue = 0;
  uint32_t distanceValue = 0;
  if (!parseUnsignedField(payload, firstPipe, UINT8_MAX, &iconValue) ||
      !parseUnsignedField(firstPipe + 1, secondPipe, UINT32_MAX, &distanceValue)) {
    return false;
  }

  if (!isValidNavigationIcon((uint8_t)iconValue)) {
    return false;
  }

  const char *instruction = secondPipe + 1;
  if (*instruction == '\0') {
    return false;
  }

  parsed->iconID = (uint8_t)iconValue;
  parsed->distance = distanceValue;
  strncpy(parsed->instruction, instruction, NAV_INSTRUCTION_MAX_LEN);
  parsed->instruction[NAV_INSTRUCTION_MAX_LEN] = '\0';

  return true;
}
