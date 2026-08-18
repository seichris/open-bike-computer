#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>

namespace renderer_tuning {

enum class Profile : uint8_t {
  Flat = 0,
  Current = 1,
  Medium = 2,
  High = 3,
};

struct BuildingQuotas {
  size_t maximumRecords = 96;
  size_t maximumPoints = 8192;
  uint64_t maximumProjectedPixels = 220000;
  size_t maximumExtrudedRecords = 32;
  size_t maximumExtrudedPoints = 3072;
  uint64_t maximumExtrudedPixels = 90000;
};

struct Definition {
  Profile profile = Profile::Current;
  const char *name = "current";
  BuildingQuotas buildings{};
  uint32_t minimumExtrusionAreaPixels = 6;
};

constexpr Definition kFlat{
    Profile::Flat,
    "flat",
    {96, 8192, 220000, 0, 0, 0},
    6,
};

constexpr Definition kCurrent{
    Profile::Current,
    "current",
    {96, 8192, 220000, 32, 3072, 90000},
    6,
};

constexpr Definition kMedium{
    Profile::Medium,
    "medium",
    {96, 8192, 220000, 40, 3840, 112500},
    6,
};

constexpr Definition kHigh{
    Profile::High,
    "high",
    {96, 8192, 220000, 48, 4608, 135000},
    6,
};

inline const Definition &definition(Profile profile) {
  switch (profile) {
  case Profile::Flat:
    return kFlat;
  case Profile::Medium:
    return kMedium;
  case Profile::High:
    return kHigh;
  case Profile::Current:
  default:
    return kCurrent;
  }
}

inline const char *name(Profile profile) { return definition(profile).name; }

inline bool parse(const char *value, Profile &profile) {
  if (value == nullptr)
    return false;
  for (const Definition *candidate : {&kFlat, &kCurrent, &kMedium, &kHigh}) {
    if (std::strcmp(value, candidate->name) == 0) {
      profile = candidate->profile;
      return true;
    }
  }
  return false;
}

inline uint64_t fingerprint(const Definition &value) {
  uint64_t hash = 1469598103934665603ULL;
  const auto mix = [&hash](uint64_t part) {
    hash ^= part;
    hash *= 1099511628211ULL;
  };
  mix(static_cast<uint8_t>(value.profile));
  mix(value.buildings.maximumRecords);
  mix(value.buildings.maximumPoints);
  mix(value.buildings.maximumProjectedPixels);
  mix(value.buildings.maximumExtrudedRecords);
  mix(value.buildings.maximumExtrudedPoints);
  mix(value.buildings.maximumExtrudedPixels);
  mix(value.minimumExtrusionAreaPixels);
  return hash;
}

} // namespace renderer_tuning
