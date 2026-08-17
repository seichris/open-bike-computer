#include "map_transfer.hpp"
#include "../maps/src/mapRendererFileValidator.hpp"
#include "../maps/src/mapFontAsset.hpp"
#include "../maps/src/mapLabelBlock.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <limits>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace map_transfer {
namespace {

constexpr const char *kVectMapPrefix = "VECTMAP/";
constexpr const char *kActiveMapFile = "/VECTMAP/active-map.json";
constexpr const char *kActivationTransactionFile =
    "/VECTMAP/.activation-transaction.json";
constexpr const char *kPendingArchiveActivationFile =
    "/VECTMAP/.pending-archive-activation";
constexpr const char *kPendingStreamActivationFile =
    "/VECTMAP/.pending-stream-activation.json";
constexpr const char *kInstalledManifestFile = ".manifest.json";
constexpr const char *kInstalledReceiptFile = ".verified.sha256";
constexpr const char *kStreamReadyFile = ".ready";
constexpr const char *kStreamConsumedFile = ".activation-consumed";
constexpr const char *kStreamCheckpointFile = ".stream-checkpoint";
constexpr const char *kStreamInstallingFile = ".installing";
constexpr const char *kRendererValidationReceiptPrefix = "renderer-v1:";
// Large city packs can contain several thousand map files; their hash manifest
// is currently about 1 MB for 5,500 entries. Keep a firm upper bound while
// allowing those production packs to validate in PSRAM-backed builds.
constexpr size_t kMaxManifestBytes = 2 * 1024 * 1024;
constexpr uint32_t kZipLocalHeaderSignature = 0x04034b50;
constexpr uint32_t kZipCentralHeaderSignature = 0x02014b50;
constexpr uint32_t kZipEndSignature = 0x06054b50;

static bool isFontAssetPath(const std::string &path,
                            const std::string &mapId) {
  return path == std::string(kVectMapPrefix) + mapId +
                     "/assets/street-labels.fma";
}

static uint16_t readLe16(const uint8_t *data) {
  return static_cast<uint16_t>(data[0]) | (static_cast<uint16_t>(data[1]) << 8);
}

static uint32_t readLe32(const uint8_t *data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

static std::string joinPath(const std::string &a, const std::string &b) {
  if (a.empty())
    return b;
  if (b.empty())
    return a;
  if (a.back() == '/')
    return a + (b.front() == '/' ? b.substr(1) : b);
  return a + "/" + (b.front() == '/' ? b.substr(1) : b);
}

static std::string dirnameOf(const std::string &path) {
  size_t slash = path.find_last_of('/');
  if (slash == std::string::npos)
    return "";
  if (slash == 0)
    return "/";
  return path.substr(0, slash);
}

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

static bool startsWith(const std::string &value, const std::string &prefix) {
  return value.size() >= prefix.size() &&
         value.compare(0, prefix.size(), prefix) == 0;
}

static std::string jsonStringValue(const std::string &json,
                                   const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos)
    return "";
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos)
    return "";
  pos = json.find('"', pos + 1);
  if (pos == std::string::npos)
    return "";
  std::string out;
  bool escaped = false;
  for (size_t i = pos + 1; i < json.size(); i++) {
    char c = json[i];
    if (escaped) {
      out.push_back(c);
      escaped = false;
      continue;
    }
    if (c == '\\') {
      escaped = true;
      continue;
    }
    if (c == '"')
      return out;
    out.push_back(c);
  }
  return "";
}

static int hexValue(char value) {
  if (value >= '0' && value <= '9')
    return value - '0';
  if (value >= 'a' && value <= 'f')
    return value - 'a' + 10;
  if (value >= 'A' && value <= 'F')
    return value - 'A' + 10;
  return -1;
}

static bool appendUtf8(uint32_t codePoint, std::string &output) {
  if (codePoint <= 0x7f) {
    output.push_back(static_cast<char>(codePoint));
  } else if (codePoint <= 0x7ff) {
    output.push_back(static_cast<char>(0xc0 | (codePoint >> 6)));
    output.push_back(static_cast<char>(0x80 | (codePoint & 0x3f)));
  } else if (codePoint <= 0xffff) {
    if (codePoint >= 0xd800 && codePoint <= 0xdfff)
      return false;
    output.push_back(static_cast<char>(0xe0 | (codePoint >> 12)));
    output.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | (codePoint & 0x3f)));
  } else if (codePoint <= 0x10ffff) {
    output.push_back(static_cast<char>(0xf0 | (codePoint >> 18)));
    output.push_back(static_cast<char>(0x80 | ((codePoint >> 12) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | (codePoint & 0x3f)));
  } else {
    return false;
  }
  return true;
}

static bool validUtf8(const std::string &value) {
  for (size_t index = 0; index < value.size();) {
    const uint8_t first = static_cast<uint8_t>(value[index]);
    size_t continuationCount = 0;
    uint8_t secondMinimum = 0x80;
    uint8_t secondMaximum = 0xbf;
    if (first <= 0x7f) {
      index++;
      continue;
    } else if (first >= 0xc2 && first <= 0xdf) {
      continuationCount = 1;
    } else if (first == 0xe0) {
      continuationCount = 2;
      secondMinimum = 0xa0;
    } else if (first >= 0xe1 && first <= 0xec) {
      continuationCount = 2;
    } else if (first == 0xed) {
      continuationCount = 2;
      secondMaximum = 0x9f;
    } else if (first >= 0xee && first <= 0xef) {
      continuationCount = 2;
    } else if (first == 0xf0) {
      continuationCount = 3;
      secondMinimum = 0x90;
    } else if (first >= 0xf1 && first <= 0xf3) {
      continuationCount = 3;
    } else if (first == 0xf4) {
      continuationCount = 3;
      secondMaximum = 0x8f;
    } else {
      return false;
    }
    if (index + continuationCount >= value.size())
      return false;
    const uint8_t second = static_cast<uint8_t>(value[index + 1]);
    if (second < secondMinimum || second > secondMaximum)
      return false;
    if (first == 0xc2 && second >= 0x80 && second <= 0x9f)
      return false;
    for (size_t offset = 2; offset <= continuationCount; ++offset) {
      const uint8_t continuation =
          static_cast<uint8_t>(value[index + offset]);
      if (continuation < 0x80 || continuation > 0xbf)
        return false;
    }
    index += continuationCount + 1;
  }
  return true;
}

static bool readUnicodeEscape(const std::string &json, size_t &cursor,
                              uint16_t &value) {
  if (cursor + 4 > json.size())
    return false;
  value = 0;
  for (size_t index = 0; index < 4; ++index) {
    const int digit = hexValue(json[cursor + index]);
    if (digit < 0)
      return false;
    value = static_cast<uint16_t>((value << 4) | digit);
  }
  cursor += 4;
  return true;
}

static std::string jsonPresentationStringValue(const std::string &json,
                                               const std::string &key) {
  constexpr size_t kMaximumDisplayNameBytes = 240;
  const std::string needle = "\"" + key + "\"";
  size_t cursor = json.find(needle);
  if (cursor == std::string::npos)
    return "";
  cursor = json.find(':', cursor + needle.size());
  if (cursor == std::string::npos)
    return "";
  cursor++;
  while (cursor < json.size() &&
         std::isspace(static_cast<unsigned char>(json[cursor])) != 0)
    cursor++;
  if (cursor >= json.size() || json[cursor++] != '"')
    return "";

  std::string output;
  output.reserve(80);
  while (cursor < json.size()) {
    const unsigned char character =
        static_cast<unsigned char>(json[cursor++]);
    if (character == '"') {
      return !output.empty() && output.size() <= kMaximumDisplayNameBytes &&
                     validUtf8(output)
                 ? output
                 : std::string();
    }
    if (character < 0x20 || character == 0x7f)
      return "";
    if (character != '\\') {
      output.push_back(static_cast<char>(character));
    } else {
      if (cursor >= json.size())
        return "";
      const char escaped = json[cursor++];
      if (escaped == '"' || escaped == '\\' || escaped == '/') {
        output.push_back(escaped);
      } else if (escaped == 'u') {
        uint16_t first = 0;
        if (!readUnicodeEscape(json, cursor, first) || first < 0x20 ||
            (first >= 0x7f && first <= 0x9f))
          return "";
        uint32_t codePoint = first;
        if (first >= 0xd800 && first <= 0xdbff) {
          if (cursor + 2 > json.size() || json[cursor] != '\\' ||
              json[cursor + 1] != 'u')
            return "";
          cursor += 2;
          uint16_t second = 0;
          if (!readUnicodeEscape(json, cursor, second) || second < 0xdc00 ||
              second > 0xdfff)
            return "";
          codePoint = 0x10000u +
                      ((static_cast<uint32_t>(first) - 0xd800u) << 10) +
                      (static_cast<uint32_t>(second) - 0xdc00u);
        } else if (first >= 0xdc00 && first <= 0xdfff) {
          return "";
        }
        if (!appendUtf8(codePoint, output))
          return "";
      } else {
        // Escaped controls are not valid display-name content.
        return "";
      }
    }
    if (output.size() > kMaximumDisplayNameBytes)
      return "";
  }
  return "";
}

static bool jsonNumberArray4(const std::string &json, const std::string &key,
                             std::array<double, 4> &values, bool &found) {
  found = false;
  const std::string needle = "\"" + key + "\"";
  size_t cursor = json.find(needle);
  if (cursor == std::string::npos)
    return false;
  found = true;
  cursor = json.find(':', cursor + needle.size());
  if (cursor == std::string::npos)
    return false;
  cursor++;
  while (cursor < json.size() &&
         std::isspace(static_cast<unsigned char>(json[cursor])) != 0)
    cursor++;
  if (cursor >= json.size() || json[cursor++] != '[')
    return false;
  for (size_t index = 0; index < values.size(); ++index) {
    while (cursor < json.size() &&
           std::isspace(static_cast<unsigned char>(json[cursor])) != 0)
      cursor++;
    if (cursor >= json.size())
      return false;
    errno = 0;
    char *end = nullptr;
    const char *start = json.c_str() + cursor;
    const double parsed = std::strtod(start, &end);
    if (end == start || errno == ERANGE || !std::isfinite(parsed))
      return false;
    cursor = static_cast<size_t>(end - json.c_str());
    values[index] = parsed;
    while (cursor < json.size() &&
           std::isspace(static_cast<unsigned char>(json[cursor])) != 0)
      cursor++;
    const char expected = index + 1 == values.size() ? ']' : ',';
    if (cursor >= json.size() || json[cursor++] != expected)
      return false;
  }
  return true;
}

static bool boundsE7Valid(const std::array<int32_t, 4> &bounds) {
  return bounds[0] >= -1800000000 && bounds[0] <= 1800000000 &&
         bounds[2] >= -1800000000 && bounds[2] <= 1800000000 &&
         bounds[1] >= -900000000 && bounds[1] <= 900000000 &&
         bounds[3] >= -900000000 && bounds[3] <= 900000000 &&
         bounds[0] < bounds[2] && bounds[1] < bounds[3];
}

static bool jsonPresentationBoundsE7(const std::string &json,
                                     std::array<int32_t, 4> &bounds) {
  std::array<double, 4> values = {};
  bool found = false;
  if (jsonNumberArray4(json, "boundsE7", values, found)) {
    for (size_t index = 0; index < values.size(); ++index) {
      if (values[index] != std::trunc(values[index]) ||
          values[index] < std::numeric_limits<int32_t>::min() ||
          values[index] > std::numeric_limits<int32_t>::max())
        return false;
      bounds[index] = static_cast<int32_t>(values[index]);
    }
    return boundsE7Valid(bounds);
  }
  if (found)
    return false;

  if (!jsonNumberArray4(json, "bounds", values, found))
    return false;
  for (size_t index = 0; index < values.size(); ++index) {
    const double scaled = values[index] * 10000000.0;
    if (!std::isfinite(scaled) ||
        scaled < std::numeric_limits<int32_t>::min() ||
        scaled > std::numeric_limits<int32_t>::max())
      return false;
    bounds[index] = static_cast<int32_t>(std::llround(scaled));
  }
  return boundsE7Valid(bounds);
}

static uint64_t jsonUintValue(const std::string &json, const std::string &key) {
  const std::string needle = "\"" + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos)
    return 0;
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos)
    return 0;
  pos++;
  while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\n' ||
                               json[pos] == '\t' || json[pos] == '\r')) {
    pos++;
  }
  uint64_t value = 0;
  while (pos < json.size() && json[pos] >= '0' && json[pos] <= '9') {
    value = value * 10 + static_cast<uint64_t>(json[pos] - '0');
    pos++;
  }
  return value;
}

static std::vector<std::string>
jsonStringArrayValue(const std::string &json, const std::string &key,
                     bool *valid = nullptr) {
  if (valid != nullptr)
    *valid = false;
  std::vector<std::string> values;
  const std::string needle = "\"" + key + "\"";
  size_t cursor = json.find(needle);
  if (cursor == std::string::npos)
    return values;
  cursor = json.find('[', cursor + needle.size());
  if (cursor == std::string::npos)
    return values;
  cursor++;
  bool requireValue = false;
  while (cursor < json.size()) {
    while (cursor < json.size() &&
           std::isspace(static_cast<unsigned char>(json[cursor])) != 0)
      cursor++;
    if (cursor < json.size() && json[cursor] == ']') {
      if (requireValue)
        return {};
      if (valid != nullptr)
        *valid = true;
      return values;
    }
    if (cursor >= json.size())
      return {};
    if (json[cursor++] != '"')
      return {};
    std::string value;
    bool complete = false;
    while (cursor < json.size()) {
      const char character = json[cursor++];
      if (character == '"') {
        complete = true;
        break;
      }
      if (character == '\\' ||
          static_cast<unsigned char>(character) < 0x20)
        return {};
      value.push_back(character);
    }
    if (!complete)
      return {};
    values.push_back(value);
    while (cursor < json.size() &&
           std::isspace(static_cast<unsigned char>(json[cursor])) != 0)
      cursor++;
    if (cursor < json.size() && json[cursor] == ',') {
      cursor++;
      requireValue = true;
      continue;
    }
    requireValue = false;
    if (cursor >= json.size() || json[cursor] != ']')
      return {};
  }
  return {};
}

static bool safeLanguageTag(const std::string &value) {
  if (value.size() < 2 || value.size() > 35)
    return false;
  size_t subtagStart = 0;
  size_t subtagIndex = 0;
  while (subtagStart < value.size()) {
    const size_t separator = value.find('-', subtagStart);
    const size_t subtagEnd =
        separator == std::string::npos ? value.size() : separator;
    const size_t subtagLength = subtagEnd - subtagStart;
    if (subtagLength == 0 || subtagLength > 8)
      return false;
    for (size_t index = subtagStart; index < subtagEnd; ++index) {
      const unsigned char character = value[index];
      if ((subtagIndex == 0 && !std::islower(character)) ||
          (subtagIndex == 0 && !std::isalpha(character)) ||
          (subtagIndex != 0 && !std::isalnum(character)))
        return false;
    }
    if (subtagIndex == 0 && subtagLength < 2)
      return false;
    if (separator == std::string::npos)
      return true;
    subtagStart = separator + 1;
    subtagIndex++;
    if (subtagIndex >= 4)
      return false;
  }
  return false;
}

static MapTargetMetadata targetMetadata(const MapManifest &manifest) {
  MapTargetMetadata target;
  target.renderer = manifest.renderer;
  target.formatVersion = manifest.formatVersion;
  target.labelProfileVersion = manifest.labelProfileVersion;
  target.labelLanguages = manifest.labelLanguages;
  target.internationalFallback = manifest.internationalFallback;
  target.buildingProfileVersion = manifest.buildingProfileVersion;
  return target;
}

static bool targetMetadataEmpty(const MapTargetMetadata &target) {
  return target.renderer.empty() && target.formatVersion == 0 &&
         target.labelProfileVersion == 0 && target.labelLanguages.empty() &&
         target.internationalFallback.empty() &&
         target.buildingProfileVersion == 0;
}

static bool targetMetadataValid(const MapTargetMetadata &target) {
  if (targetMetadataEmpty(target))
    return true;
  if (target.renderer != "esp32-fmb" ||
      (target.formatVersion != 1 && target.formatVersion != 2 &&
       target.formatVersion != 3)) {
    return false;
  }
  if (target.formatVersion == 1) {
    return target.labelProfileVersion == 0 &&
           target.labelLanguages.empty() &&
           target.internationalFallback.empty() &&
           target.buildingProfileVersion == 0;
  }
  if (target.labelProfileVersion != 1 ||
      target.labelLanguages.size() > 3 ||
      !safeLanguageTag(target.internationalFallback) ||
      !std::all_of(target.labelLanguages.begin(),
                   target.labelLanguages.end(), safeLanguageTag)) {
    return false;
  }
  for (size_t index = 0; index < target.labelLanguages.size(); ++index) {
    for (size_t other = index + 1; other < target.labelLanguages.size();
         ++other) {
      if (target.labelLanguages[index] == target.labelLanguages[other])
        return false;
    }
  }
  return target.formatVersion == 3 ? target.buildingProfileVersion == 1
                                   : target.buildingProfileVersion == 0;
}

static bool targetMetadataMatches(const MapTargetMetadata &left,
                                  const MapTargetMetadata &right) {
  return left.renderer == right.renderer &&
         left.formatVersion == right.formatVersion &&
         left.labelProfileVersion == right.labelProfileVersion &&
         left.labelLanguages == right.labelLanguages &&
         left.internationalFallback == right.internationalFallback &&
         left.buildingProfileVersion == right.buildingProfileVersion;
}

static MapTargetMetadata targetMetadataFromJson(const std::string &json,
                                                const std::string &prefix,
                                                bool *valid = nullptr) {
  MapTargetMetadata target;
  const auto key = [&](const char *name) {
    if (!prefix.empty())
      return prefix + name;
    std::string value = name;
    value.front() = static_cast<char>(std::tolower(value.front()));
    return value;
  };
  const std::string rendererKey = key("Renderer");
  const std::string formatKey = key("FormatVersion");
  const std::string profileKey = key("LabelProfileVersion");
  const std::string languagesKey = key("LabelLanguages");
  const std::string fallbackKey = key("InternationalFallback");
  const std::string buildingProfileKey = key("BuildingProfileVersion");
  const auto hasKey = [&](const std::string &name) {
    return json.find("\"" + name + "\"") != std::string::npos;
  };
  target.renderer = jsonStringValue(json, rendererKey);
  const uint64_t formatVersion = jsonUintValue(json, formatKey);
  const uint64_t labelProfileVersion = jsonUintValue(json, profileKey);
  target.formatVersion = static_cast<uint32_t>(formatVersion);
  target.labelProfileVersion = static_cast<uint32_t>(labelProfileVersion);
  bool languagesValid = false;
  target.labelLanguages =
      jsonStringArrayValue(json, languagesKey, &languagesValid);
  target.internationalFallback =
      jsonStringValue(json, fallbackKey);
  const uint64_t buildingProfileVersion =
      jsonUintValue(json, buildingProfileKey);
  target.buildingProfileVersion =
      static_cast<uint32_t>(buildingProfileVersion);
  const bool metadataPresent =
      hasKey(rendererKey) || hasKey(formatKey) || hasKey(profileKey) ||
      hasKey(languagesKey) || hasKey(fallbackKey) ||
      hasKey(buildingProfileKey);
  if (valid != nullptr) {
    *valid = (!metadataPresent || languagesValid) &&
             formatVersion <= UINT32_MAX &&
             labelProfileVersion <= UINT32_MAX &&
             buildingProfileVersion <= UINT32_MAX;
  }
  return target;
}

static std::string targetMetadataJson(const MapTargetMetadata &target,
                                      const std::string &prefix) {
  if (targetMetadataEmpty(target))
    return "";
  const auto key = [&](const char *name) {
    if (!prefix.empty())
      return prefix + name;
    std::string value = name;
    value.front() = static_cast<char>(std::tolower(value.front()));
    return value;
  };
  std::string json = ",\"" + key("Renderer") + "\":\"" +
                     jsonEscape(target.renderer) + "\",\"" +
                     key("FormatVersion") + "\":" +
                     std::to_string(target.formatVersion) + ",\"" +
                     key("LabelProfileVersion") + "\":" +
                     std::to_string(target.labelProfileVersion) + ",\"" +
                     key("LabelLanguages") + "\":[";
  for (size_t index = 0; index < target.labelLanguages.size(); ++index) {
    if (index != 0)
      json += ",";
    json += "\"" + jsonEscape(target.labelLanguages[index]) + "\"";
  }
  json += "],\"" + key("InternationalFallback") + "\":\"" +
          jsonEscape(target.internationalFallback) + "\",\"" +
          key("BuildingProfileVersion") + "\":" +
          std::to_string(target.buildingProfileVersion);
  return json;
}

static std::vector<std::string> fileObjects(const std::string &json) {
  std::vector<std::string> objects;
  size_t filesPos = json.find("\"files\"");
  if (filesPos == std::string::npos)
    return objects;
  size_t arrayStart = json.find('[', filesPos);
  if (arrayStart == std::string::npos)
    return objects;

  int arrayDepth = 0;
  int objectDepth = 0;
  bool inString = false;
  bool escaped = false;
  size_t objectStart = std::string::npos;

  for (size_t i = arrayStart; i < json.size(); i++) {
    char c = json[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == '\\' && inString) {
      escaped = true;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      continue;
    }
    if (inString)
      continue;
    if (c == '[')
      arrayDepth++;
    else if (c == ']') {
      arrayDepth--;
      if (arrayDepth == 0)
        break;
    } else if (c == '{') {
      if (arrayDepth == 1 && objectDepth == 0)
        objectStart = i;
      objectDepth++;
    } else if (c == '}') {
      objectDepth--;
      if (arrayDepth == 1 && objectDepth == 0 &&
          objectStart != std::string::npos) {
        objects.push_back(json.substr(objectStart, i - objectStart + 1));
        objectStart = std::string::npos;
      }
    }
  }
  return objects;
}

static std::string publishPathFor(const std::string &manifestPath,
                                  const std::string &mapId) {
  const std::string mapPrefix = std::string(kVectMapPrefix) + mapId + "/";
  if (startsWith(manifestPath, mapPrefix)) {
    return std::string(kVectMapPrefix) + manifestPath.substr(mapPrefix.size());
  }
  return manifestPath;
}

static bool isHexSha256(const std::string &value) {
  if (value.size() != 64)
    return false;
  for (char c : value) {
    bool digit = c >= '0' && c <= '9';
    bool lower = c >= 'a' && c <= 'f';
    bool upper = c >= 'A' && c <= 'F';
    if (!digit && !lower && !upper)
      return false;
  }
  return true;
}

static bool hasHiddenPathComponent(const std::string &path) {
  std::stringstream stream(path);
  std::string part;
  while (std::getline(stream, part, '/')) {
    if (!part.empty() && part[0] == '.')
      return true;
  }
  return false;
}

static uint32_t rotr(uint32_t value, uint32_t bits) {
  return (value >> bits) | (value << (32 - bits));
}

static const uint32_t kSha256RoundConstants[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

} // namespace

void Sha256Hasher::update(const uint8_t *data, size_t len) {
  totalLen_ += len;
  while (len > 0) {
    size_t n = std::min(len, block_.size() - blockLen_);
    memcpy(block_.data() + blockLen_, data, n);
    blockLen_ += n;
    data += n;
    len -= n;
    if (blockLen_ == block_.size()) {
      transform(block_.data());
      blockLen_ = 0;
    }
  }
}

std::string Sha256Hasher::finalHex() {
  uint64_t bitLen = totalLen_ * 8;
  uint8_t one = 0x80;
  update(&one, 1);
  uint8_t zero = 0;
  while (blockLen_ != 56)
    update(&zero, 1);
  uint8_t lengthBytes[8];
  for (int i = 0; i < 8; i++)
    lengthBytes[i] = static_cast<uint8_t>(bitLen >> (56 - (i * 8)));
  update(lengthBytes, sizeof(lengthBytes));

  static const char hex[] = "0123456789abcdef";
  std::string out;
  out.reserve(64);
  for (uint32_t word : h_) {
    for (int shift = 28; shift >= 0; shift -= 4)
      out.push_back(hex[(word >> shift) & 0x0F]);
  }
  return out;
}

void Sha256Hasher::transform(const uint8_t *chunk) {
  uint32_t w[64] = {};
  for (int i = 0; i < 16; i++) {
    size_t j = static_cast<size_t>(i) * 4;
    w[i] = (static_cast<uint32_t>(chunk[j]) << 24) |
           (static_cast<uint32_t>(chunk[j + 1]) << 16) |
           (static_cast<uint32_t>(chunk[j + 2]) << 8) |
           static_cast<uint32_t>(chunk[j + 3]);
  }
  for (int i = 16; i < 64; i++) {
    uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }

  uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3];
  uint32_t e = h_[4], f = h_[5], g = h_[6], hh = h_[7];
  for (int i = 0; i < 64; i++) {
    uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    uint32_t ch = (e & f) ^ ((~e) & g);
    uint32_t temp1 = hh + s1 + ch + kSha256RoundConstants[i] + w[i];
    uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t temp2 = s0 + maj;
    hh = g;
    g = f;
    f = e;
    e = d + temp1;
    d = c;
    c = b;
    b = a;
    a = temp1 + temp2;
  }
  h_[0] += a;
  h_[1] += b;
  h_[2] += c;
  h_[3] += d;
  h_[4] += e;
  h_[5] += f;
  h_[6] += g;
  h_[7] += hh;
}

std::string sha256Hex(const uint8_t *data, size_t len) {
  Sha256Hasher sha;
  sha.update(data, len);
  return sha.finalHex();
}

ActivationBeginResult MapActivationState::begin(const std::string &sessionId,
                                                uint8_t totalSteps,
                                                uint32_t minimumSequence) {
  if (state_.running) {
    return state_.sessionId == sessionId ? ActivationBeginResult::AlreadyRunning
                                         : ActivationBeginResult::Busy;
  }
  if (state_.status == "installed" && state_.sessionId == sessionId) {
    return ActivationBeginResult::AlreadyInstalled;
  }
  state_.running = true;
  const uint32_t nextSequence =
      state_.sequence == UINT32_MAX ? UINT32_MAX : state_.sequence + 1;
  state_.sequence = std::max<uint32_t>(nextSequence, minimumSequence);
  if (state_.sequence == 0)
    state_.sequence = 1;
  state_.status = "activating";
  state_.sessionId = sessionId;
  state_.mapId.clear();
  state_.step = 1;
  state_.totalSteps = std::max<uint8_t>(1, totalSteps);
  state_.progress = 0;
  state_.errorCode.clear();
  state_.errorMessage.clear();
  return ActivationBeginResult::Started;
}

void MapActivationState::updateProgress(const ActivationProgress &progress) {
  if (!state_.running)
    return;
  state_.step = std::max<uint8_t>(1, progress.step);
  state_.totalSteps = std::max<uint8_t>(state_.step, progress.totalSteps);
  if (progress.total == 0) {
    state_.progress = progress.completed > 0 ? 100 : 0;
  } else {
    state_.progress = static_cast<uint8_t>(
        std::min<uint64_t>(100, (progress.completed * 100) / progress.total));
  }
}

void MapActivationState::finish(const std::string &status,
                                const std::string &mapId,
                                const std::string &errorCode,
                                const std::string &errorMessage) {
  state_.running = false;
  state_.status = status;
  state_.mapId = mapId;
  if (status == "installed") {
    state_.step = state_.totalSteps;
    state_.progress = 100;
  }
  state_.errorCode = errorCode;
  state_.errorMessage = errorMessage;
}

bool MapActivationState::acceptsUploads() const { return !state_.running; }

MapActivationSnapshot MapActivationState::snapshot() const { return state_; }

std::string MapActivationState::json(bool compact) const {
  std::string body = std::string("{\"status\":\"") + jsonEscape(state_.status) +
                     "\",\"sequence\":" + std::to_string(state_.sequence);
  if (!state_.sessionId.empty())
    body += ",\"sessionId\":\"" + jsonEscape(state_.sessionId) + "\"";
  if (state_.step > 0) {
    body += ",\"step\":" + std::to_string(state_.step) +
            ",\"steps\":" + std::to_string(state_.totalSteps) +
            ",\"progress\":" + std::to_string(state_.progress);
  }
  if (!compact && !state_.mapId.empty())
    body += ",\"mapId\":\"" + jsonEscape(state_.mapId) + "\"";
  if (!state_.errorCode.empty()) {
    body += ",\"error\":{\"code\":\"" + jsonEscape(state_.errorCode) + "\"";
    if (!compact && !state_.errorMessage.empty())
      body += ",\"message\":\"" + jsonEscape(state_.errorMessage) + "\"";
    body += "}";
  }
  body += "}";
  return body;
}

MapTransferInstaller::MapTransferInstaller(std::string storageRoot)
    : storageRoot_(std::move(storageRoot)) {
  if (!storageRoot_.empty() && storageRoot_.back() == '/')
    storageRoot_.pop_back();
}

InstallStatus
MapTransferInstaller::validateManifestText(const std::string &manifestText,
                                           MapManifest &manifest) const {
  manifest = MapManifest();
  if (manifestText.empty() || manifestText.size() > kMaxManifestBytes)
    return fail("manifest_size", "manifest size is invalid");

  manifest.schemaVersion =
      static_cast<uint32_t>(jsonUintValue(manifestText, "schemaVersion"));
  manifest.mapId = jsonStringValue(manifestText, "mapId");
  manifest.displayName =
      jsonPresentationStringValue(manifestText, "displayName");
  manifest.hasBoundsE7 =
      jsonPresentationBoundsE7(manifestText, manifest.boundsE7);
  manifest.renderer = jsonStringValue(manifestText, "renderer");
  manifest.formatVersion =
      static_cast<uint32_t>(jsonUintValue(manifestText, "formatVersion"));
  manifest.labelProfileVersion = static_cast<uint32_t>(
      jsonUintValue(manifestText, "labelProfileVersion"));
  bool labelLanguagesValid = false;
  manifest.labelLanguages =
      jsonStringArrayValue(manifestText, "labelLanguages", &labelLanguagesValid);
  manifest.internationalFallback =
      jsonStringValue(manifestText, "internationalFallback");
  manifest.buildingProfileVersion = static_cast<uint32_t>(
      jsonUintValue(manifestText, "buildingProfileVersion"));
  manifest.buildingRecordCount = static_cast<uint32_t>(
      jsonUintValue(manifestText, "recordCount"));
  manifest.buildingProvenanceCounts[0] = static_cast<uint32_t>(
      jsonUintValue(manifestText, "explicitHeightCount"));
  manifest.buildingProvenanceCounts[1] = static_cast<uint32_t>(
      jsonUintValue(manifestText, "levelsHeightCount"));
  manifest.buildingProvenanceCounts[2] = static_cast<uint32_t>(
      jsonUintValue(manifestText, "inheritedHeightCount"));
  manifest.buildingProvenanceCounts[3] = static_cast<uint32_t>(
      jsonUintValue(manifestText, "localMedianHeightCount"));
  manifest.buildingProvenanceCounts[4] = static_cast<uint32_t>(
      jsonUintValue(manifestText, "classDefaultHeightCount"));
  manifest.minimumFirmwareVersion =
      jsonStringValue(manifestText, "minFirmwareVersion");
  if (manifest.renderer.empty() && manifest.formatVersion == 0) {
    manifest.renderer = "esp32-fmb";
    manifest.formatVersion = 1;
  }
  if (manifest.schemaVersion != 1)
    return fail("manifest_schema", "unsupported manifest schema version");
  if (!safeMapId(manifest.mapId))
    return fail("manifest_map_id", "mapId contains unsafe characters");

  uint32_t fontAssetCount = 0;
  uint32_t legacyTextBlockCount = 0;
  for (const std::string &object : fileObjects(manifestText)) {
    ManifestFile file;
    file.path = jsonStringValue(object, "path");
    file.sha256 = jsonStringValue(object, "sha256");
    file.bytes = jsonUintValue(object, "bytes");
    file.publishPath = publishPathFor(file.path, manifest.mapId);
    const std::string mapPrefix =
        std::string(kVectMapPrefix) + manifest.mapId + "/";
    if (!safeRelativePath(file.path) || !safeRelativePath(file.publishPath))
      return fail("manifest_path", "manifest contains unsafe file path");
    if (!startsWith(file.path, mapPrefix) ||
        !startsWith(file.publishPath, kVectMapPrefix))
      return fail("manifest_path", "map files must live under VECTMAP/<mapId>");
    if (hasHiddenPathComponent(file.publishPath))
      return fail("manifest_path", "map files may not use hidden folders");
    if (file.publishPath == std::string(kActiveMapFile).substr(1))
      return fail("manifest_path", "manifest may not overwrite active map");
    const bool isFontAsset = isFontAssetPath(file.path, manifest.mapId);
    const bool isBlock = file.path.size() >= 4 &&
                         (file.path.rfind(".fmb") == file.path.size() - 4 ||
                          file.path.rfind(".fmp") == file.path.size() - 4);
    if (!isBlock && !isFontAsset)
      return fail("manifest_path", "manifest contains an unsupported map file");
    if (file.bytes == 0 ||
        file.bytes > (isFontAsset
                          ? map_font_asset_format::kMaximumFontAssetBytes
                          : map_block_format::kMaximumBlockBytes))
      return fail("manifest_bytes", "map file byte count is invalid");
    if (!isHexSha256(file.sha256))
      return fail("manifest_sha256", "map file sha256 is invalid");
    manifest.files.push_back(file);
    if (isFontAsset)
      fontAssetCount++;
    if (file.path.rfind(".fmp") == file.path.size() - 4)
      legacyTextBlockCount++;
  }
  if (manifest.files.empty())
    return fail("manifest_files", "manifest contains no map files");
  if (manifest.renderer != "esp32-fmb" ||
      (manifest.formatVersion != 1 && manifest.formatVersion != 2 &&
       manifest.formatVersion != 3))
    return fail("manifest_target", "manifest renderer target is unsupported");
  if (((manifest.formatVersion == 2 || manifest.formatVersion == 3) &&
       (fontAssetCount != 1 || legacyTextBlockCount != 0)) ||
      (manifest.formatVersion == 1 && fontAssetCount != 0))
    return fail("manifest_target", "manifest files do not match renderer target");
  if (manifest.formatVersion == 2 || manifest.formatVersion == 3) {
    bool uniqueLanguages = true;
    for (size_t index = 0; index < manifest.labelLanguages.size(); ++index)
      for (size_t other = index + 1; other < manifest.labelLanguages.size(); ++other)
        if (manifest.labelLanguages[index] == manifest.labelLanguages[other])
          uniqueLanguages = false;
    if (manifest.labelProfileVersion != 1 ||
        !labelLanguagesValid ||
        manifest.labelLanguages.size() > 3 ||
        !uniqueLanguages ||
        !std::all_of(manifest.labelLanguages.begin(),
                     manifest.labelLanguages.end(), safeLanguageTag) ||
        !safeLanguageTag(manifest.internationalFallback))
      return fail("manifest_labels", "manifest label profile is invalid");
  } else if (manifest.labelProfileVersion != 0 ||
             !manifest.labelLanguages.empty() ||
             !manifest.internationalFallback.empty()) {
    return fail("manifest_labels", "legacy manifest contains label metadata");
  }
  uint64_t provenanceTotal = 0;
  for (uint32_t count : manifest.buildingProvenanceCounts)
    provenanceTotal += count;
  if (manifest.formatVersion == 3) {
    if (manifest.buildingProfileVersion != 1 ||
        provenanceTotal != manifest.buildingRecordCount)
      return fail("manifest_buildings", "manifest building profile is invalid");
  } else if (manifest.buildingProfileVersion != 0 ||
             manifest.buildingRecordCount != 0 || provenanceTotal != 0) {
    return fail("manifest_buildings", "non-v3 manifest contains building metadata");
  }
  return {true, "ok", ""};
}

InstallStatus
MapTransferInstaller::readStagedManifest(const std::string &sessionId,
                                         MapManifest &manifest) const {
  if (!safeId(sessionId))
    return fail("session_id", "session id contains unsafe characters");
  std::string manifestText;
  if (!readTextFile(joinPath(stagingRoot(sessionId), "manifest.json"),
                    manifestText, kMaxManifestBytes)) {
    return fail("manifest_missing", "staged manifest is missing");
  }
  return validateManifestText(manifestText, manifest);
}

InstallStatus MapTransferInstaller::validateStagedMap(
    const std::string &sessionId, MapManifest &manifest,
    const ActivationProgressCallback &onProgress) const {
  InstallStatus parsed = readStagedManifest(sessionId, manifest);
  if (!parsed.ok)
    return parsed;

  uint64_t completed = 0;
  const uint64_t total = manifest.files.size();
  if (onProgress)
    onProgress({3, 5, 0, total});
  for (const ManifestFile &file : manifest.files) {
    const std::string stagedPath = joinPath(stagingRoot(sessionId), file.path);
    uint64_t size = 0;
    if (!fileSize(stagedPath, size))
      return fail("file_missing", "staged map file is missing: " + file.path);
    if (size != file.bytes)
      return fail("file_size", "staged map file size mismatch: " + file.path);
    if (!stagedFileVerified(sessionId, file)) {
      // Compatibility path for a transfer staged by older firmware. New
      // uploads are hashed while streaming and only reach activation with a
      // verification receipt, so the normal activation path performs no
      // full-file reads.
      std::ifstream input(stagedPath, std::ios::binary);
      if (!input)
        return fail("file_sha256", "could not read staged map file: " +
                                       file.path);
      Sha256Hasher hasher;
      map_renderer_format::StreamValidator rendererValidator(file.path);
      std::array<uint8_t, 4096> buffer = {};
      while (input) {
        input.read(reinterpret_cast<char *>(buffer.data()), buffer.size());
        const std::streamsize count = input.gcount();
        if (count <= 0)
          break;
        hasher.update(buffer.data(), static_cast<size_t>(count));
        if (!rendererValidator.feed(buffer.data(),
                                    static_cast<size_t>(count))) {
          return fail("file_renderer_format",
                      "staged map file is not renderer-compatible: " +
                          file.path);
        }
      }
      if (!input.eof() || !rendererValidator.finish())
        return fail("file_renderer_format",
                    "staged map file is not renderer-compatible: " +
                        file.path);
      std::string sha = hasher.finalHex();
      std::transform(sha.begin(), sha.end(), sha.begin(), ::tolower);
      std::string expected = file.sha256;
      std::transform(expected.begin(), expected.end(), expected.begin(),
                     ::tolower);
      if (sha != expected)
        return fail("file_sha256",
                    "staged map file sha256 mismatch: " + file.path);
      if (!markStagedFileVerified(sessionId, file))
        return fail("file_receipt",
                    "could not record staged map verification: " + file.path);
    }
    completed++;
    if (onProgress)
      onProgress({3, 5, completed, total});
  }
  const InstallStatus labels =
      validateLabelContracts(stagingRoot(sessionId), manifest, true);
  if (!labels.ok)
    return labels;
  return {true, "ok", ""};
}

InstallStatus MapTransferInstaller::prepareStagedArchive(
    const std::string &sessionId,
    const ActivationProgressCallback &onProgress) const {
  if (!safeId(sessionId))
    return fail("session_id", "session id contains unsafe characters");
  const std::string archivePath = stagedArchivePath(sessionId);
  if (!fileExists(archivePath))
    return {true, "legacy_files", ""};

  const std::string root = stagingRoot(sessionId);
  if (!mkdirs(root))
    return fail("archive_cleanup",
                "could not prepare archive staging directory");

  uint64_t archiveBytes = 0;
  if (!fileSize(archivePath, archiveBytes))
    return fail("archive_missing", "staged archive is missing");
  std::ifstream input(archivePath, std::ios::binary);
  if (!input)
    return fail("archive_open", "could not open staged archive");

  uint64_t manifestOffset = 0;
  uint64_t manifestBytes = 0;
  bool sawCentralDirectory = false;
  bool foundManifest = false;
  uint64_t offset = 0;
  int lastScanPercent = -1;
  const auto reportScanProgress = [&](uint64_t completed, bool force = false) {
    if (!onProgress)
      return;
    const int percent = archiveBytes == 0
                            ? 0
                            : static_cast<int>(std::min<uint64_t>(
                                  100, completed * 100 / archiveBytes));
    if (force || percent != lastScanPercent) {
      lastScanPercent = percent;
      onProgress({1, 5, completed, archiveBytes});
    }
  };
  reportScanProgress(0, true);
  while (offset + 4 <= archiveBytes) {
    uint8_t signatureBytes[4] = {};
    input.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    input.read(reinterpret_cast<char *>(signatureBytes),
               sizeof(signatureBytes));
    if (input.gcount() != static_cast<std::streamsize>(sizeof(signatureBytes)))
      break;
    const uint32_t signature = readLe32(signatureBytes);
    if (signature == kZipCentralHeaderSignature ||
        signature == kZipEndSignature) {
      sawCentralDirectory = true;
      reportScanProgress(archiveBytes, true);
      break;
    }
    if (signature != kZipLocalHeaderSignature) {
      return fail("archive_header",
                  "stored archive has an invalid local header");
    }

    uint8_t header[26] = {};
    input.read(reinterpret_cast<char *>(header), sizeof(header));
    if (input.gcount() != static_cast<std::streamsize>(sizeof(header))) {
      return fail("archive_truncated", "stored archive header is truncated");
    }
    const uint16_t flags = readLe16(header + 2);
    const uint16_t compression = readLe16(header + 4);
    const uint64_t compressedSize = readLe32(header + 14);
    const uint64_t uncompressedSize = readLe32(header + 18);
    const uint16_t nameLength = readLe16(header + 22);
    const uint16_t extraLength = readLe16(header + 24);
    if ((flags & 0x0009) != 0 || compression != 0 ||
        compressedSize != uncompressedSize || nameLength == 0 ||
        nameLength > 240) {
      return fail("archive_format",
                  "map archive must use stored entries without descriptors");
    }

    std::string path(nameLength, '\0');
    input.read(path.data(), static_cast<std::streamsize>(nameLength));
    if (input.gcount() != static_cast<std::streamsize>(nameLength) ||
        path.find('\0') != std::string::npos) {
      return fail("archive_path", "map archive contains an invalid path");
    }
    const uint64_t dataOffset = offset + 30 + nameLength + extraLength;
    if (dataOffset > archiveBytes ||
        compressedSize > archiveBytes - dataOffset) {
      return fail("archive_truncated",
                  "map archive entry extends past end of file");
    }

    const bool isManifest = path == "manifest.json";
    const bool isMapFile =
        startsWith(path, kVectMapPrefix) && safeRelativePath(path) &&
        ((path.size() >= 4 && (path.rfind(".fmb") == path.size() - 4 ||
                               path.rfind(".fmp") == path.size() - 4)) ||
         map_renderer_format::isFontAssetPath(path));
    const bool isMetadata =
        path == "ATTRIBUTION.txt" || startsWith(path, "LICENSES/");
    if (!isManifest && !isMapFile && !isMetadata && path.back() != '/') {
      return fail("archive_path", "map archive contains an unexpected path");
    }

    if (isManifest) {
      if (foundManifest)
        return fail("archive_path", "map archive contains multiple manifests");
      if (compressedSize > kMaxManifestBytes)
        return fail("manifest_size", "manifest size is invalid");
      foundManifest = true;
      manifestOffset = dataOffset;
      manifestBytes = compressedSize;
    }
    offset = dataOffset + compressedSize;
    reportScanProgress(offset);
  }

  if (!sawCentralDirectory || !foundManifest)
    return fail("archive_truncated", "map archive is incomplete");

  const std::string manifestPath = joinPath(root, "manifest.json");
  const std::string manifestTemp = manifestPath + ".part";
  std::ofstream manifestOutput(manifestTemp,
                               std::ios::binary | std::ios::trunc);
  if (!manifestOutput)
    return fail("archive_write", "could not create extracted manifest");
  input.clear();
  input.seekg(static_cast<std::streamoff>(manifestOffset), std::ios::beg);
  std::array<uint8_t, 4096> buffer = {};
  uint64_t remaining = manifestBytes;
  while (remaining > 0) {
    const size_t count =
        static_cast<size_t>(std::min<uint64_t>(remaining, buffer.size()));
    input.read(reinterpret_cast<char *>(buffer.data()),
               static_cast<std::streamsize>(count));
    if (input.gcount() != static_cast<std::streamsize>(count)) {
      manifestOutput.close();
      removeTree(manifestTemp);
      return fail("archive_truncated", "map archive data is truncated");
    }
    manifestOutput.write(reinterpret_cast<const char *>(buffer.data()),
                         static_cast<std::streamsize>(count));
    if (!manifestOutput) {
      manifestOutput.close();
      removeTree(manifestTemp);
      return fail("archive_write", "could not write extracted manifest");
    }
    remaining -= count;
  }
  manifestOutput.close();
  if (!manifestOutput.good() || !removeTree(manifestPath) ||
      ::rename(manifestTemp.c_str(), manifestPath.c_str()) != 0) {
    removeTree(manifestTemp);
    return fail("archive_write", "could not finish extracted manifest");
  }

  MapManifest manifest;
  InstallStatus parsed = readStagedManifest(sessionId, manifest);
  if (!parsed.ok)
    return parsed;
  uint64_t totalMapBytes = 0;
  for (const ManifestFile &file : manifest.files)
    totalMapBytes += file.bytes;

  uint64_t completedMapBytes = 0;
  int lastReportedPercent = -1;
  const auto reportProgress = [&](bool force = false) {
    if (!onProgress)
      return;
    const int percent =
        totalMapBytes == 0 ? (completedMapBytes > 0 ? 100 : 0)
                           : static_cast<int>(std::min<uint64_t>(
                                 100, completedMapBytes * 100 / totalMapBytes));
    if (force || percent != lastReportedPercent) {
      lastReportedPercent = percent;
      onProgress({2, 5, completedMapBytes, totalMapBytes});
    }
  };
  reportProgress(true);

  input.clear();
  offset = 0;
  size_t manifestFileIndex = 0;
  sawCentralDirectory = false;
  while (offset + 4 <= archiveBytes) {
    uint8_t signatureBytes[4] = {};
    input.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    input.read(reinterpret_cast<char *>(signatureBytes),
               sizeof(signatureBytes));
    if (input.gcount() != static_cast<std::streamsize>(sizeof(signatureBytes)))
      break;
    const uint32_t signature = readLe32(signatureBytes);
    if (signature == kZipCentralHeaderSignature ||
        signature == kZipEndSignature) {
      sawCentralDirectory = true;
      break;
    }
    if (signature != kZipLocalHeaderSignature)
      return fail("archive_header",
                  "stored archive has an invalid local header");

    uint8_t header[26] = {};
    input.read(reinterpret_cast<char *>(header), sizeof(header));
    if (input.gcount() != static_cast<std::streamsize>(sizeof(header)))
      return fail("archive_truncated", "stored archive header is truncated");
    const uint64_t compressedSize = readLe32(header + 14);
    const uint16_t nameLength = readLe16(header + 22);
    const uint16_t extraLength = readLe16(header + 24);
    std::string path(nameLength, '\0');
    input.read(path.data(), static_cast<std::streamsize>(nameLength));
    if (input.gcount() != static_cast<std::streamsize>(nameLength))
      return fail("archive_path", "map archive contains an invalid path");
    const uint64_t dataOffset = offset + 30 + nameLength + extraLength;
    const bool isMapFile = startsWith(path, kVectMapPrefix) &&
                           safeRelativePath(path) && path.size() >= 4 &&
                           (path.rfind(".fmb") == path.size() - 4 ||
                            path.rfind(".fmp") == path.size() - 4 ||
                            isFontAssetPath(path, manifest.mapId));
    if (isMapFile) {
      if (manifestFileIndex >= manifest.files.size() ||
          manifest.files[manifestFileIndex].path != path)
        return fail("archive_manifest",
                    "map archive files do not match the manifest");
      const ManifestFile &expected = manifest.files[manifestFileIndex++];
      if (compressedSize != expected.bytes)
        return fail("file_size", "archive map file size mismatch: " + path);

      if (stagedFileVerified(sessionId, expected)) {
        completedMapBytes += expected.bytes;
        reportProgress();
        offset = dataOffset + compressedSize;
        continue;
      }

      clearStagedFileVerification(sessionId, expected);
      const std::string destination = joinPath(root, path);
      const std::string tempDestination = destination + ".part";
      if (!mkdirs(dirnameOf(destination)))
        return fail("archive_mkdir",
                    "could not create extracted map directory");
      std::ofstream output(tempDestination, std::ios::binary | std::ios::trunc);
      if (!output)
        return fail("archive_write", "could not create extracted map file");
      input.seekg(static_cast<std::streamoff>(dataOffset), std::ios::beg);
      Sha256Hasher hasher;
      map_renderer_format::StreamValidator rendererValidator(path);
      remaining = compressedSize;
      while (remaining > 0) {
        const size_t count =
            static_cast<size_t>(std::min<uint64_t>(remaining, buffer.size()));
        input.read(reinterpret_cast<char *>(buffer.data()),
                   static_cast<std::streamsize>(count));
        if (input.gcount() != static_cast<std::streamsize>(count)) {
          output.close();
          removeTree(tempDestination);
          return fail("archive_truncated", "map archive data is truncated");
        }
        hasher.update(buffer.data(), count);
        if (!rendererValidator.feed(buffer.data(), count)) {
          output.close();
          removeTree(tempDestination);
          return fail("file_renderer_format",
                      "archive map file is not renderer-compatible: " +
                          path);
        }
        output.write(reinterpret_cast<const char *>(buffer.data()),
                     static_cast<std::streamsize>(count));
        if (!output) {
          output.close();
          removeTree(tempDestination);
          return fail("archive_write", "could not write extracted map file");
        }
        remaining -= count;
        completedMapBytes += count;
        reportProgress();
      }
      output.close();
      if (!output.good()) {
        removeTree(tempDestination);
        return fail("archive_write", "could not finish extracted map file");
      }
      if (!rendererValidator.finish()) {
        removeTree(tempDestination);
        return fail("file_renderer_format",
                    "archive map file is not renderer-compatible: " + path);
      }
      std::string actualSha = hasher.finalHex();
      std::string expectedSha = expected.sha256;
      std::transform(expectedSha.begin(), expectedSha.end(),
                     expectedSha.begin(), ::tolower);
      if (actualSha != expectedSha) {
        removeTree(tempDestination);
        return fail("file_sha256", "archive map file sha256 mismatch: " + path);
      }
      if (!removeTree(destination) ||
          ::rename(tempDestination.c_str(), destination.c_str()) != 0) {
        removeTree(tempDestination);
        return fail("archive_write", "could not publish extracted map file");
      }
      if (!markStagedFileVerified(sessionId, expected))
        return fail("file_receipt",
                    "could not record extracted map verification: " + path);
    }
    offset = dataOffset + compressedSize;
  }

  if (!sawCentralDirectory || manifestFileIndex != manifest.files.size())
    return fail("archive_manifest", "map archive is missing manifest files");
  completedMapBytes = totalMapBytes;
  reportProgress(true);
  return {true, "archive_extracted", ""};
}

InstallStatus
MapTransferInstaller::expectedStagedFile(const std::string &sessionId,
                                         const std::string &path,
                                         ManifestFile &file) const {
  if (!safeId(sessionId) || !safeRelativePath(path))
    return fail("path", "staged map path is invalid");
  MapManifest manifest;
  InstallStatus parsed = readStagedManifest(sessionId, manifest);
  if (!parsed.ok)
    return parsed;
  for (const ManifestFile &candidate : manifest.files) {
    if (candidate.path == path) {
      file = candidate;
      return {true, "ok", ""};
    }
  }
  return fail("manifest_path", "file is not declared by the staged manifest");
}

bool MapTransferInstaller::stagedFileVerified(const std::string &sessionId,
                                              const ManifestFile &file) const {
  uint64_t size = 0;
  if (!fileSize(joinPath(stagingRoot(sessionId), file.path), size) ||
      size != file.bytes) {
    return false;
  }
  std::string receipt;
  if (!readTextFile(verificationPath(sessionId, file), receipt, 96))
    return false;
  std::transform(receipt.begin(), receipt.end(), receipt.begin(), ::tolower);
  std::string expected = file.sha256;
  std::transform(expected.begin(), expected.end(), expected.begin(), ::tolower);
  return receipt == std::string(kRendererValidationReceiptPrefix) + expected;
}

bool MapTransferInstaller::markStagedFileVerified(
    const std::string &sessionId, const ManifestFile &file) const {
  if (!safeId(sessionId) || !safeRelativePath(file.path) ||
      !isHexSha256(file.sha256)) {
    return false;
  }
  std::string sha = file.sha256;
  std::transform(sha.begin(), sha.end(), sha.begin(), ::tolower);
  return writeTextFileAtomic(verificationPath(sessionId, file),
                             std::string(kRendererValidationReceiptPrefix) +
                                 sha);
}

void MapTransferInstaller::clearStagedFileVerification(
    const std::string &sessionId, const ManifestFile &file) const {
  removeTree(verificationPath(sessionId, file));
  removeTree(verificationPath(sessionId, file) + ".bak");
  removeTree(verificationPath(sessionId, file) + ".tmp");
}

InstallStatus MapTransferInstaller::activateStagedMap(
    const std::string &sessionId, const MapManifest &manifest,
    const ActivationProgressCallback &onProgress) const {
  if (!safeId(sessionId))
    return fail("session_id", "session id contains unsafe characters");
  if (!safeMapId(manifest.mapId))
    return fail("manifest_map_id", "mapId contains unsafe characters");

  const std::string transactionPath =
      joinPath(storageRoot_, kActivationTransactionFile);
  const std::string baseRoot = std::string("/VECTMAP/.maps/") + sessionId;
  std::string root = baseRoot;

  ActiveMapSelection previous;
  InstallStatus previousStatus = readActiveMap(previous);
  if (!previousStatus.ok && previousStatus.code != "active_missing")
    return previousStatus;
  if (previousStatus.ok && previous.sessionId == sessionId) {
    const bool stagedReplacement =
        fileExists(joinPath(stagingRoot(sessionId), "manifest.json"));
    if (!stagedReplacement &&
        installedMapReceiptMatches(previous.root, manifest)) {
      removeTree(stagingRoot(sessionId));
      return {true, "ok", ""};
    }
    const std::string repairDigest = sha256Hex(
        reinterpret_cast<const uint8_t *>(sessionId.data()), sessionId.size());
    const std::string repairName =
        sessionId.substr(0, 63) + "-repair-" + repairDigest.substr(0, 8);
    const std::string repairRoot = std::string("/VECTMAP/.maps/") + repairName;
    root = previous.root == repairRoot ? baseRoot : repairRoot;
  }
  const std::string destinationRoot = joinPath(storageRoot_, root);
  const MapTargetMetadata selectedTarget = targetMetadata(manifest);

  const auto transactionJson = [&](const char *phase) {
    return std::string("{\"sessionId\":\"") + sessionId + "\",\"mapId\":\"" +
           manifest.mapId + "\",\"root\":\"" + root + "\"" +
           targetMetadataJson(selectedTarget, "") +
           ",\"previousMapId\":\"" + jsonEscape(previous.mapId) +
           "\",\"previousSessionId\":\"" + jsonEscape(previous.sessionId) +
           "\",\"previousRoot\":\"" + jsonEscape(previous.root) + "\"" +
           targetMetadataJson(previous.target, "previous") +
           ",\"previousManifestReceipt\":\"" +
           jsonEscape(previous.manifestReceipt) +
           "\",\"previousSignedManifestReceipt\":\"" +
           jsonEscape(previous.signedManifestReceipt) + "\",\"phase\":\"" +
           phase + "\"}\n";
  };
  const auto abandonNewRoot = [&]() {
    const bool cleaned = removeTree(destinationRoot) &&
                         removeTree(stagingRoot(sessionId)) &&
                         removeTree(transactionPath + ".bak") &&
                         removeTree(transactionPath + ".tmp");
    return cleaned && removeTree(transactionPath);
  };

  if (!removeTree(destinationRoot))
    return fail("install_cleanup", "could not clear incomplete map version");
  if (onProgress)
    onProgress({4, 5, 0, manifest.files.size()});
  if (!writeTextFileAtomic(transactionPath, transactionJson("publishing"))) {
    return fail("transaction", "could not start map activation transaction");
  }
  if (!publishStagedFiles(sessionId, manifest, destinationRoot, onProgress)) {
    abandonNewRoot();
    return fail("publish_move", "could not publish verified map files");
  }
  if (!publishInstalledMetadata(sessionId, manifest, destinationRoot)) {
    abandonNewRoot();
    return fail("publish_metadata",
                "could not publish map verification metadata");
  }
  const InstallStatus labelStatus =
      validateLabelContracts(destinationRoot, manifest, false);
  if (!labelStatus.ok) {
    abandonNewRoot();
    return labelStatus;
  }
  if (!writeTextFileAtomic(transactionPath, transactionJson("ready"))) {
    abandonNewRoot();
    return fail("transaction", "could not prepare map activation switch");
  }

  if (onProgress)
    onProgress({5, 5, 0, 1});

  ActiveMapSelection selected;
  selected.mapId = manifest.mapId;
  selected.sessionId = sessionId;
  selected.root = root;
  selected.target = selectedTarget;
  if (previousStatus.ok) {
    selected.previousMapId = previous.mapId;
    selected.previousSessionId = previous.sessionId;
    selected.previousRoot = previous.root;
    selected.previousTarget = previous.target;
    selected.previousManifestReceipt = previous.manifestReceipt;
    selected.previousSignedManifestReceipt = previous.signedManifestReceipt;
  }
  if (!writeActiveMap(selected)) {
    InstallStatus recovered = recoverInterruptedActivation();
    if (!recovered.ok)
      return fail("active_recovery", recovered.message);
    return fail("active_write", "could not select installed map version");
  }
  if (onProgress)
    onProgress({5, 5, 1, 1});
  if (!writeTextFileAtomic(transactionPath, transactionJson("committed"))) {
    return {true, "cleanup_pending",
            "map selected; activation journal cleanup will retry"};
  }

  const bool cleanupComplete = removeTree(stagingRoot(sessionId)) &&
                               removeTree(transactionPath + ".bak") &&
                               removeTree(transactionPath + ".tmp");
  if (cleanupComplete && removeTree(transactionPath))
    return {true, "ok", ""};
  return {true, "cleanup_pending",
          "map installed; cleanup will retry after restart"};
}

InstallStatus
MapTransferInstaller::readReadyStreamMap(const std::string &sessionId,
                                         ReadyStreamMap &ready) const {
  ready = ReadyStreamMap();
  if (!safeId(sessionId))
    return fail("stream_session_id", "stream session ID is invalid");
  ready.sessionId = sessionId;
  ready.root = std::string("/VECTMAP/.maps/") + sessionId;
  const std::string root = joinPath(storageRoot_, ready.root);
  const auto candidates = [](const std::string &path) {
    return std::array<std::string, 2>{path, path + ".bak"};
  };
  const auto parseMarker = [&](const std::string &marker,
                               ReadyStreamMap &candidate) {
    candidate = ReadyStreamMap();
    candidate.sessionId = sessionId;
    candidate.root = std::string("/VECTMAP/.maps/") + sessionId;
    candidate.mapId = jsonStringValue(marker, "mapId");
    candidate.manifestReceipt = jsonStringValue(marker, "manifestReceipt");
    candidate.signedManifestReceipt =
        jsonStringValue(marker, "signedManifestReceipt");
    const uint64_t protocolVersion = jsonUintValue(marker, "protocolVersion");
    const uint64_t formatVersion = jsonUintValue(marker, "streamFormatVersion");
    const uint64_t validationVersion =
        jsonUintValue(marker, "validationVersion");
    const uint64_t fileCount = jsonUintValue(marker, "fileCount");
    candidate.payloadBytes = jsonUintValue(marker, "payloadBytes");
    if (jsonStringValue(marker, "sessionId") != sessionId ||
        protocolVersion != 2 || formatVersion != 1 || validationVersion != 1 ||
        !safeMapId(candidate.mapId) ||
        !isHexSha256(candidate.manifestReceipt) ||
        !isHexSha256(candidate.signedManifestReceipt) || fileCount == 0 ||
        fileCount > 100000 || candidate.payloadBytes == 0 ||
        candidate.payloadBytes > 512ULL * 1024ULL * 1024ULL) {
      return false;
    }
    candidate.fileCount = static_cast<uint32_t>(fileCount);
    return true;
  };
  std::string value;
  bool markerFound = false;
  for (const std::string &path : candidates(joinPath(root, kStreamReadyFile))) {
    ReadyStreamMap candidate;
    if (readTextFile(path, value, 2048) && parseMarker(value, candidate)) {
      ready = std::move(candidate);
      markerFound = true;
      break;
    }
  }
  if (!markerFound)
    return fail("stream_ready_invalid",
                "stream map ready marker is missing or invalid");

  // The writer publishes `.ready` only after every file was hashed, fsynced,
  // renamed, and covered by the completion checkpoint. Activation deliberately
  // validates bounded metadata receipts only; retry/resume separately checks
  // every checkpointed destination size before it skips incoming payload.
  bool manifestFound = false;
  for (const std::string &path :
       candidates(joinPath(root, kInstalledManifestFile))) {
    uint64_t manifestBytes = 0;
    std::string receipt;
    if (fileSize(path, manifestBytes) && manifestBytes > 0 &&
        manifestBytes <= kMaxManifestBytes && fileSha256Hex(path, receipt) &&
        receipt == ready.manifestReceipt) {
      manifestFound = true;
      break;
    }
  }
  if (!manifestFound) {
    return fail("stream_manifest_receipt",
                "stream map manifest or receipt does not match");
  }
  bool receiptFound = false;
  for (const std::string &path :
       candidates(joinPath(root, kInstalledReceiptFile))) {
    if (readTextFile(path, value, 64) && value == ready.manifestReceipt) {
      receiptFound = true;
      break;
    }
  }
  if (!receiptFound) {
    return fail("stream_installed_receipt",
                "stream installed receipt does not match");
  }
  const std::string checkpointPath = joinPath(root, kStreamCheckpointFile);
  if (fileExists(checkpointPath) || fileExists(checkpointPath + ".bak")) {
    bool checkpointFound = false;
    for (const std::string &path : candidates(checkpointPath)) {
      if (readTextFile(path, value, 4096) &&
          jsonStringValue(value, "sessionId") == ready.sessionId &&
          jsonStringValue(value, "mapId") == ready.mapId &&
          jsonStringValue(value, "manifestReceipt") == ready.manifestReceipt &&
          jsonStringValue(value, "signedManifestReceipt") ==
              ready.signedManifestReceipt &&
          jsonUintValue(value, "completedFilePrefix") == ready.fileCount &&
          jsonUintValue(value, "completedPayloadBytes") == ready.payloadBytes &&
          jsonUintValue(value, "totalFiles") == ready.fileCount &&
          jsonUintValue(value, "totalPayloadBytes") == ready.payloadBytes) {
        checkpointFound = true;
        break;
      }
    }
    if (!checkpointFound) {
      return fail("stream_checkpoint_invalid",
                  "stream completion checkpoint is invalid");
    }
  }
  return {true, "stream_ready", ""};
}

bool MapTransferInstaller::clearPendingStreamActivation(
    const std::string &sessionId) const {
  const std::string path = joinPath(storageRoot_, kPendingStreamActivationFile);
  if (!fileExists(path) && !fileExists(path + ".bak"))
    return removeTree(path + ".tmp") && removeTree(path + ".bak");
  std::string pending;
  if ((!readTextFile(path, pending, 2048) &&
       !readTextFile(path + ".bak", pending, 2048)) ||
      jsonStringValue(pending, "sessionId") != sessionId) {
    return false;
  }
  return removeTree(path) && removeTree(path + ".tmp") &&
         removeTree(path + ".bak");
}

bool MapTransferInstaller::markStreamActivationConsumed(
    const ReadyStreamMap &ready) const {
  const std::string marker =
      std::string("{\"manifestReceipt\":\"") + ready.manifestReceipt +
      "\",\"mapId\":\"" + jsonEscape(ready.mapId) + "\",\"sessionId\":\"" +
      jsonEscape(ready.sessionId) + "\",\"signedManifestReceipt\":\"" +
      ready.signedManifestReceipt + "\"}\n";
  return writeTextFileAtomic(
      joinPath(joinPath(storageRoot_, ready.root), kStreamConsumedFile),
      marker);
}

InstallStatus MapTransferInstaller::activateReadyStreamMap(
    const std::string &sessionId,
    const ActivationProgressCallback &onProgress) const {
  if (hasInterruptedActivation()) {
    InstallStatus recovered = recoverInterruptedActivation();
    if (!recovered.ok)
      return recovered;
  }
  ReadyStreamMap ready;
  InstallStatus readyStatus = readReadyStreamMap(sessionId, ready);
  if (!readyStatus.ok)
    return readyStatus;
  MapManifest readyManifest;
  const InstallStatus manifestStatus =
      readInstalledManifest(ready.root, readyManifest);
  if (!manifestStatus.ok)
    return manifestStatus;
  const InstallStatus labelStatus = validateLabelContracts(
      joinPath(storageRoot_, ready.root), readyManifest, false);
  if (!labelStatus.ok)
    return labelStatus;
  const MapTargetMetadata selectedTarget = targetMetadata(readyManifest);
  ActiveMapSelection previous;
  InstallStatus previousStatus = readActiveMap(previous);
  if (!previousStatus.ok && previousStatus.code != "active_missing")
    return previousStatus;
  if (previousStatus.ok && previous.root == ready.root) {
    if (previous.mapId != ready.mapId ||
        previous.signedManifestReceipt != ready.signedManifestReceipt) {
      return fail("stream_active_conflict",
                  "active stream root has a different identity");
    }
    if (!targetMetadataMatches(previous.target, selectedTarget)) {
      previous.target = selectedTarget;
      if (!writeActiveMap(previous))
        return fail("stream_active_write",
                    "could not refresh active map target metadata");
    }
    const bool cleaned = markStreamActivationConsumed(ready) &&
                         clearPendingStreamActivation(sessionId) &&
                         removeTree(joinPath(joinPath(storageRoot_, ready.root),
                                             kStreamCheckpointFile)) &&
                         removeTree(joinPath(joinPath(storageRoot_, ready.root),
                                             kStreamInstallingFile));
    if (onProgress)
      onProgress({3, 3, 3, 3});
    return cleaned ? InstallStatus{true, "stream_installed", ""}
                   : InstallStatus{true, "cleanup_pending",
                                   "map is active; cleanup will retry"};
  }
  std::string pending;
  const std::string pendingPath =
      joinPath(storageRoot_, kPendingStreamActivationFile);
  if ((!readTextFile(pendingPath, pending, 2048) &&
       !readTextFile(pendingPath + ".bak", pending, 2048)) ||
      jsonStringValue(pending, "sessionId") != ready.sessionId ||
      jsonStringValue(pending, "mapId") != ready.mapId ||
      jsonStringValue(pending, "root") != ready.root ||
      jsonStringValue(pending, "manifestReceipt") != ready.manifestReceipt ||
      jsonStringValue(pending, "signedManifestReceipt") !=
          ready.signedManifestReceipt) {
    return fail("stream_pending_invalid",
                "pending stream activation does not match ready map");
  }
  const std::string transactionPath =
      joinPath(storageRoot_, kActivationTransactionFile);
  const auto transaction = [&](const char *phase) {
    std::string value =
        std::string("{\"protocolVersion\":2,\"sessionId\":\"") +
        ready.sessionId + "\",\"mapId\":\"" + ready.mapId + "\",\"root\":\"" +
        ready.root + "\"" + targetMetadataJson(selectedTarget, "") +
        ",\"manifestReceipt\":\"" + ready.manifestReceipt +
        "\",\"signedManifestReceipt\":\"" + ready.signedManifestReceipt +
        "\",\"previousMapId\":\"" + jsonEscape(previous.mapId) +
        "\",\"previousSessionId\":\"" + jsonEscape(previous.sessionId) +
        "\",\"previousRoot\":\"" + jsonEscape(previous.root) +
        "\"" + targetMetadataJson(previous.target, "previous") +
        ",\"previousManifestReceipt\":\"" +
        jsonEscape(previous.manifestReceipt) +
        "\",\"previousSignedManifestReceipt\":\"" +
        jsonEscape(previous.signedManifestReceipt) + "\",\"phase\":\"" + phase +
        "\"}\n";
    return value;
  };
  if (!writeTextFileAtomic(transactionPath, transaction("ready")))
    return fail("stream_transaction_write",
                "could not start stream activation transaction");
  if (onProgress)
    onProgress({3, 3, 1, 3});
  ActiveMapSelection selected;
  selected.mapId = ready.mapId;
  selected.sessionId = ready.sessionId;
  selected.root = ready.root;
  selected.target = selectedTarget;
  selected.manifestReceipt = ready.manifestReceipt;
  selected.signedManifestReceipt = ready.signedManifestReceipt;
  if (previousStatus.ok) {
    selected.previousMapId = previous.mapId;
    selected.previousSessionId = previous.sessionId;
    selected.previousRoot = previous.root;
    selected.previousTarget = previous.target;
    selected.previousManifestReceipt = previous.manifestReceipt;
    selected.previousSignedManifestReceipt = previous.signedManifestReceipt;
  }
  if (!writeActiveMap(selected)) {
    InstallStatus recovered = recoverInterruptedActivation();
    return recovered.ok
               ? fail("stream_active_write", "could not select ready map")
               : recovered;
  }
  if (onProgress)
    onProgress({3, 3, 2, 3});
  if (!markStreamActivationConsumed(ready))
    return {true, "cleanup_pending",
            "stream map selected; consumed marker will retry"};
  if (!writeTextFileAtomic(transactionPath, transaction("committed")))
    return {true, "cleanup_pending",
            "stream map selected; journal cleanup will retry"};
  const std::string root = joinPath(storageRoot_, ready.root);
  const bool cleaned = markStreamActivationConsumed(ready) &&
                       clearPendingStreamActivation(sessionId) &&
                       removeTree(joinPath(root, kStreamCheckpointFile)) &&
                       removeTree(joinPath(root, kStreamInstallingFile)) &&
                       removeTree(transactionPath + ".tmp") &&
                       removeTree(transactionPath + ".bak") &&
                       removeTree(transactionPath);
  if (onProgress)
    onProgress({3, 3, 3, 3});
  return cleaned ? InstallStatus{true, "stream_installed", ""}
                 : InstallStatus{true, "cleanup_pending",
                                 "stream map installed; cleanup will retry"};
}

InstallStatus MapTransferInstaller::recoverPendingStreamActivation(
    const ActivationProgressCallback &onProgress) const {
  if (hasInterruptedActivation()) {
    InstallStatus recovered = recoverInterruptedActivation();
    if (!recovered.ok)
      return recovered;
  }
  std::string pending;
  const std::string pendingPath =
      joinPath(storageRoot_, kPendingStreamActivationFile);
  if (!readTextFile(pendingPath, pending, 2048) &&
      !readTextFile(pendingPath + ".bak", pending, 2048)) {
    ActiveMapSelection active;
    const InstallStatus activeStatus = readActiveMap(active);
    const std::string mapsRoot = joinPath(storageRoot_, "/VECTMAP/.maps");
    DIR *directory = ::opendir(mapsRoot.c_str());
    if (directory == nullptr)
      return errno == ENOENT
                 ? InstallStatus{true, "stream_pending_none", ""}
                 : fail("stream_recovery_scan", "could not scan map roots");
    ReadyStreamMap candidate;
    size_t candidates = 0;
    while (struct dirent *entry = ::readdir(directory)) {
      const std::string name = entry->d_name;
      if (name == "." || name == ".." || !safeId(name))
        continue;
      ReadyStreamMap ready;
      if (!readReadyStreamMap(name, ready).ok)
        continue;
      const std::string readyRoot = joinPath(mapsRoot, name);
      if (fileExists(joinPath(readyRoot, kStreamConsumedFile)) ||
          fileExists(joinPath(readyRoot, kStreamConsumedFile) + ".bak")) {
        continue;
      }
      if (activeStatus.ok && active.root == ready.root &&
          active.signedManifestReceipt == ready.signedManifestReceipt) {
        continue;
      }
      if (activeStatus.ok && active.previousRoot == ready.root)
        continue;
      candidate = std::move(ready);
      candidates++;
    }
    ::closedir(directory);
    if (candidates == 0)
      return {true, "stream_pending_none", ""};
    if (candidates != 1)
      return fail("stream_ready_ambiguous",
                  "multiple unselected ready map roots require reconciliation");
    pending = std::string("{\"manifestReceipt\":\"") +
              candidate.manifestReceipt + "\",\"mapId\":\"" +
              jsonEscape(candidate.mapId) + "\",\"root\":\"" + candidate.root +
              "\",\"sessionId\":\"" + jsonEscape(candidate.sessionId) +
              "\",\"signedManifestReceipt\":\"" +
              candidate.signedManifestReceipt + "\"}\n";
    if (!writeTextFileAtomic(pendingPath, pending))
      return fail("stream_pending_recovery",
                  "could not restore pending stream activation");
  }
  const std::string sessionId = jsonStringValue(pending, "sessionId");
  if (!safeId(sessionId))
    return fail("stream_pending_invalid", "pending stream session is invalid");
  return activateReadyStreamMap(sessionId, onProgress);
}

InstallStatus MapTransferInstaller::recoverStreamActivationTransaction(
    const std::string &transaction) const {
  const std::string sessionId = jsonStringValue(transaction, "sessionId");
  const std::string mapId = jsonStringValue(transaction, "mapId");
  const std::string root = jsonStringValue(transaction, "root");
  bool transactionTargetParsed = false;
  const MapTargetMetadata transactionTarget =
      targetMetadataFromJson(transaction, "", &transactionTargetParsed);
  const std::string manifestReceipt =
      jsonStringValue(transaction, "manifestReceipt");
  const std::string signedManifestReceipt =
      jsonStringValue(transaction, "signedManifestReceipt");
  const std::string previousMapId =
      jsonStringValue(transaction, "previousMapId");
  const std::string previousSessionId =
      jsonStringValue(transaction, "previousSessionId");
  const std::string previousRoot = jsonStringValue(transaction, "previousRoot");
  const std::string previousManifestReceipt =
      jsonStringValue(transaction, "previousManifestReceipt");
  const std::string previousSignedManifestReceipt =
      jsonStringValue(transaction, "previousSignedManifestReceipt");
  bool previousTargetParsed = false;
  const MapTargetMetadata previousTarget = targetMetadataFromJson(
      transaction, "previous", &previousTargetParsed);
  const std::string phase = jsonStringValue(transaction, "phase");
  const std::string transactionPath =
      joinPath(storageRoot_, kActivationTransactionFile);
  if (!safeId(sessionId) || !safeMapId(mapId) ||
      root != std::string("/VECTMAP/.maps/") + sessionId ||
      !isHexSha256(manifestReceipt) || !isHexSha256(signedManifestReceipt) ||
      !transactionTargetParsed || !targetMetadataValid(transactionTarget) ||
      (!previousRoot.empty() &&
       (!safeActiveRoot(previousRoot) || !safeMapId(previousMapId) ||
        (!previousSessionId.empty() && !safeId(previousSessionId)) ||
        (previousManifestReceipt.empty() !=
         previousSignedManifestReceipt.empty()) ||
         (!previousManifestReceipt.empty() &&
          (!isHexSha256(previousManifestReceipt) ||
          !isHexSha256(previousSignedManifestReceipt))) ||
        (!previousTargetParsed || !targetMetadataValid(previousTarget)))) ||
      (previousRoot.empty() &&
       (!previousMapId.empty() || !previousSessionId.empty() ||
        !previousTargetParsed ||
        !targetMetadataEmpty(previousTarget) ||
        !previousManifestReceipt.empty() ||
        !previousSignedManifestReceipt.empty())) ||
      (phase != "ready" && phase != "committed")) {
    return fail("stream_transaction_invalid",
                "stream activation transaction is invalid");
  }
  ReadyStreamMap ready;
  InstallStatus readyStatus = readReadyStreamMap(sessionId, ready);
  MapManifest installedManifest;
  const InstallStatus installedStatus =
      readyStatus.ok ? readInstalledManifest(root, installedManifest)
                     : InstallStatus{};
  const MapTargetMetadata installedTarget = targetMetadata(installedManifest);
  if (!readyStatus.ok || !installedStatus.ok || ready.mapId != mapId ||
      ready.root != root || installedManifest.mapId != mapId ||
      ready.manifestReceipt != manifestReceipt ||
      ready.signedManifestReceipt != signedManifestReceipt ||
      (!targetMetadataEmpty(transactionTarget) &&
       !targetMetadataMatches(transactionTarget, installedTarget))) {
    ActiveMapSelection active;
    InstallStatus activeStatus = readActiveMap(active);
    if (activeStatus.ok && active.root == root) {
      if (!previousRoot.empty() &&
          rollbackRootMatches(previousRoot, previousMapId,
                              previousManifestReceipt,
                              previousSignedManifestReceipt)) {
        ActiveMapSelection rollback;
        rollback.mapId = previousMapId;
        rollback.sessionId = previousSessionId;
        rollback.root = previousRoot;
        rollback.target = previousTarget;
        rollback.manifestReceipt = previousManifestReceipt;
        rollback.signedManifestReceipt = previousSignedManifestReceipt;
        if (!writeActiveMap(rollback))
          return fail("stream_transaction_recovery",
                      "could not restore previous map selection");
      } else if (!removeTree(joinPath(storageRoot_, kActiveMapFile))) {
        return fail("stream_transaction_recovery",
                    "could not clear invalid stream selection");
      }
    }
    const bool cleaned = removeTree(joinPath(storageRoot_, root)) &&
                         clearPendingStreamActivation(sessionId) &&
                         removeTree(transactionPath + ".tmp") &&
                         removeTree(transactionPath + ".bak") &&
                         removeTree(transactionPath);
    return cleaned ? InstallStatus{true, "recovered_rollback",
                                   "discarded invalid ready stream map"}
                   : fail("stream_transaction_cleanup",
                          "could not clean invalid stream transaction");
  }
  ActiveMapSelection selected;
  selected.mapId = mapId;
  selected.sessionId = sessionId;
  selected.root = root;
  selected.target = installedTarget;
  selected.manifestReceipt = manifestReceipt;
  selected.signedManifestReceipt = signedManifestReceipt;
  if (!previousRoot.empty()) {
    selected.previousMapId = previousMapId;
    selected.previousSessionId = previousSessionId;
    selected.previousRoot = previousRoot;
    selected.previousTarget = previousTarget;
    selected.previousManifestReceipt = previousManifestReceipt;
    selected.previousSignedManifestReceipt = previousSignedManifestReceipt;
  }
  ActiveMapSelection active;
  InstallStatus activeStatus = readActiveMap(active);
  if (!previousRoot.empty() && targetMetadataEmpty(selected.previousTarget) &&
      activeStatus.ok) {
    if (active.root == previousRoot)
      selected.previousTarget = active.target;
    else if (active.root == root)
      selected.previousTarget = active.previousTarget;
  }
  const bool alreadySelected =
      activeStatus.ok && active.root == root &&
      active.signedManifestReceipt == signedManifestReceipt;
  const bool previousStillSelected =
      (!activeStatus.ok && activeStatus.code == "active_missing") ||
      (activeStatus.ok && active.root == previousRoot);
  if (alreadySelected) {
    if (!targetMetadataMatches(active.target, selected.target) ||
        !targetMetadataMatches(active.previousTarget,
                               selected.previousTarget)) {
      if (!writeActiveMap(selected))
        return fail("stream_transaction_recovery",
                    "could not refresh stream pointer metadata");
    }
  } else {
    if (!previousStillSelected)
      return fail("stream_transaction_conflict",
                  "another active map replaced the stream transaction");
    if (!writeActiveMap(selected))
      return fail("stream_transaction_recovery",
                  "could not complete stream pointer transaction");
  }
  const std::string installedRoot = joinPath(storageRoot_, root);
  const bool cleaned =
      markStreamActivationConsumed(ready) &&
      clearPendingStreamActivation(sessionId) &&
      removeTree(joinPath(installedRoot, kStreamCheckpointFile)) &&
      removeTree(joinPath(installedRoot, kStreamInstallingFile)) &&
      removeTree(transactionPath + ".tmp") &&
      removeTree(transactionPath + ".bak") && removeTree(transactionPath);
  return cleaned ? InstallStatus{true, "recovered_commit",
                                 "completed stream map activation"}
                 : fail("stream_transaction_cleanup",
                        "could not finish stream activation cleanup");
}

InstallStatus MapTransferInstaller::recoverInterruptedActivation() const {
  const std::string transactionPath =
      joinPath(storageRoot_, kActivationTransactionFile);
  const std::string activePath = joinPath(storageRoot_, kActiveMapFile);
  std::string transaction;
  if (!readTextFile(transactionPath, transaction, 2048)) {
    const std::string backupPath = transactionPath + ".bak";
    if (!fileExists(backupPath)) {
      removeTree(transactionPath + ".tmp");
      ActiveMapSelection selected;
      InstallStatus active = readActiveMap(selected);
      if (!active.ok || activeRootExists(selected.root)) {
        if (active.ok || active.code == "active_missing")
          return {true, "ok", ""};
        if (active.code == "active_invalid") {
          const std::string activeBackup = activePath + ".bak";
          removeTree(activePath);
          if (fileExists(activeBackup) &&
              ::rename(activeBackup.c_str(), activePath.c_str()) == 0) {
            ActiveMapSelection backup;
            InstallStatus backupStatus = readActiveMap(backup);
            if (backupStatus.ok && activeRootExists(backup.root)) {
              removeTree(activePath + ".tmp");
              return {true, "recovered_rollback",
                      "restored valid active map metadata backup"};
            }
            removeTree(activePath);
          }
          removeTree(activeBackup);
          removeTree(activePath + ".tmp");
          return {true, "recovered_rollback",
                  "cleared invalid active map metadata"};
        }
        return active;
      }
      if (!selected.previousRoot.empty() &&
          rollbackRootMatches(selected.previousRoot, selected.previousMapId,
                              selected.previousManifestReceipt,
                              selected.previousSignedManifestReceipt)) {
        ActiveMapSelection rollback;
        rollback.mapId = selected.previousMapId;
        rollback.sessionId = selected.previousSessionId;
        rollback.root = selected.previousRoot;
        rollback.target = selected.previousTarget;
        rollback.manifestReceipt = selected.previousManifestReceipt;
        rollback.signedManifestReceipt = selected.previousSignedManifestReceipt;
        if (!writeActiveMap(rollback))
          return fail("active_recovery",
                      "could not restore previous map selection");
        return {true, "recovered_rollback", "restored previous map selection"};
      }
      if (!removeTree(activePath) || !removeTree(activePath + ".bak") ||
          !removeTree(activePath + ".tmp")) {
        return fail("active_recovery",
                    "could not clear missing active map selection");
      }
      return {true, "recovered_rollback",
              "cleared missing active map selection"};
    }
    if (::rename(backupPath.c_str(), transactionPath.c_str()) != 0 ||
        !readTextFile(transactionPath, transaction, 2048)) {
      return fail("transaction_recovery",
                  "could not recover map activation journal");
    }
  }

  if (jsonUintValue(transaction, "protocolVersion") == 2)
    return recoverStreamActivationTransaction(transaction);

  const std::string sessionId = jsonStringValue(transaction, "sessionId");
  const std::string mapId = jsonStringValue(transaction, "mapId");
  const std::string root = jsonStringValue(transaction, "root");
  bool transactionTargetParsed = false;
  const MapTargetMetadata transactionTarget =
      targetMetadataFromJson(transaction, "", &transactionTargetParsed);
  const std::string previousMapId =
      jsonStringValue(transaction, "previousMapId");
  const std::string previousSessionId =
      jsonStringValue(transaction, "previousSessionId");
  const std::string previousRoot = jsonStringValue(transaction, "previousRoot");
  const std::string previousManifestReceipt =
      jsonStringValue(transaction, "previousManifestReceipt");
  const std::string previousSignedManifestReceipt =
      jsonStringValue(transaction, "previousSignedManifestReceipt");
  bool previousTargetParsed = false;
  const MapTargetMetadata previousTarget = targetMetadataFromJson(
      transaction, "previous", &previousTargetParsed);
  const std::string phase = jsonStringValue(transaction, "phase");
  if (!safeId(sessionId) || !safeMapId(mapId) || !safeActiveRoot(root) ||
      !transactionTargetParsed || !targetMetadataValid(transactionTarget) ||
      (!previousRoot.empty() &&
       (!safeActiveRoot(previousRoot) || !safeMapId(previousMapId) ||
        (!previousSessionId.empty() && !safeId(previousSessionId)) ||
        (previousManifestReceipt.empty() !=
         previousSignedManifestReceipt.empty()) ||
         (!previousManifestReceipt.empty() &&
          (!isHexSha256(previousManifestReceipt) ||
          !isHexSha256(previousSignedManifestReceipt))) ||
        (!previousTargetParsed || !targetMetadataValid(previousTarget)))) ||
      (previousRoot.empty() &&
       (!previousTargetParsed || !targetMetadataEmpty(previousTarget))) ||
      (phase != "publishing" && phase != "ready" && phase != "committed")) {
    const auto clearInvalidTransaction = [&]() {
      return removeTree(transactionPath) &&
             removeTree(transactionPath + ".bak") &&
             removeTree(transactionPath + ".tmp");
    };
    ActiveMapSelection selected;
    InstallStatus active = readActiveMap(selected);
    if (active.ok && selected.root != "/VECTMAP") {
      MapManifest installed;
      if (readInstalledManifest(selected.root, installed).ok &&
          installed.mapId == selected.mapId &&
          installedMapContentsMatch(selected.root, installed)) {
        if (!clearInvalidTransaction())
          return fail("transaction_invalid",
                      "could not clear invalid map activation transaction");
        return {true, "recovered_commit",
                "verified selected map after clearing invalid transaction"};
      }
      if (!selected.previousRoot.empty() &&
          rollbackRootMatches(selected.previousRoot, selected.previousMapId,
                              selected.previousManifestReceipt,
                              selected.previousSignedManifestReceipt)) {
        ActiveMapSelection rollback;
        rollback.mapId = selected.previousMapId;
        rollback.sessionId = selected.previousSessionId;
        rollback.root = selected.previousRoot;
        rollback.target = selected.previousTarget;
        rollback.manifestReceipt = selected.previousManifestReceipt;
        rollback.signedManifestReceipt = selected.previousSignedManifestReceipt;
        if (!writeActiveMap(rollback))
          return fail(
              "transaction_recovery",
              "could not restore previous map after invalid transaction");
        if (!clearInvalidTransaction())
          return fail("transaction_invalid",
                      "could not clear invalid map activation transaction");
        if (!removeTree(joinPath(storageRoot_, selected.root)))
          return fail(
              "transaction_cleanup",
              "restored previous map but could not remove invalid version");
        return {true, "recovered_rollback",
                "restored previous map after invalid transaction"};
      }
      if (!removeTree(activePath)) {
        return fail("transaction_recovery",
                    "could not clear invalid selected map metadata");
      }
      if (!clearInvalidTransaction() ||
          !removeTree(joinPath(storageRoot_, selected.root))) {
        return fail("transaction_recovery",
                    "could not clear unverifiable map transaction");
      }
      return {true, "recovered_rollback",
              "discarded unverifiable map after invalid transaction"};
    }
    if (!clearInvalidTransaction())
      return fail("transaction_invalid",
                  "could not clear invalid map activation transaction");
    InstallStatus recovered = recoverInterruptedActivation();
    if (!recovered.ok)
      return recovered;
    return {true, "recovered_rollback",
            "cleared invalid map activation transaction"};
  }

  std::string pendingArchiveSessionId;
  const bool preserveStagedArchive =
      readPendingArchiveActivation(pendingArchiveSessionId) &&
      pendingArchiveSessionId == sessionId &&
      fileExists(stagedArchivePath(sessionId));

  ActiveMapSelection active;
  InstallStatus activeStatus = readActiveMap(active);
  const bool activePointsToNewRoot = activeStatus.ok && active.root == root;
  const bool selectedNewRoot = activePointsToNewRoot && active.mapId == mapId &&
                               active.sessionId == sessionId;
  MapManifest installedManifest;
  const bool selectedRootVerified =
      selectedNewRoot && readInstalledManifest(root, installedManifest).ok &&
      installedManifest.mapId == mapId &&
      installedMapContentsMatch(root, installedManifest) &&
      (targetMetadataEmpty(transactionTarget) ||
       targetMetadataMatches(transactionTarget,
                             targetMetadata(installedManifest)));
  if (selectedRootVerified) {
    const MapTargetMetadata installedTarget = targetMetadata(installedManifest);
    bool pointerUpdated = true;
    if (!targetMetadataMatches(active.target, installedTarget) ||
        (targetMetadataEmpty(active.previousTarget) &&
         !targetMetadataEmpty(previousTarget))) {
      active.target = installedTarget;
      if (targetMetadataEmpty(active.previousTarget))
        active.previousTarget = previousTarget;
      pointerUpdated = writeActiveMap(active);
    }
    const bool cleanupComplete =
        pointerUpdated &&
        (preserveStagedArchive || removeTree(stagingRoot(sessionId))) &&
        removeTree(activePath + ".bak") && removeTree(activePath + ".tmp") &&
        removeTree(transactionPath + ".bak") &&
        removeTree(transactionPath + ".tmp");
    if (!cleanupComplete || !removeTree(transactionPath))
      return fail("transaction_cleanup", "could not finish map commit cleanup");
    return {true, "recovered_commit", "completed interrupted map commit"};
  }

  bool restoredPrevious = false;
  if ((!activeStatus.ok || activePointsToNewRoot) && !previousRoot.empty() &&
      rollbackRootMatches(previousRoot, previousMapId, previousManifestReceipt,
                          previousSignedManifestReceipt)) {
    ActiveMapSelection rollback;
    rollback.mapId = previousMapId;
    rollback.sessionId = previousSessionId;
    rollback.root = previousRoot;
    rollback.target = previousTarget;
    rollback.manifestReceipt = previousManifestReceipt;
    rollback.signedManifestReceipt = previousSignedManifestReceipt;
    if (!writeActiveMap(rollback))
      return fail("transaction_recovery",
                  "could not restore previous map selection");
    restoredPrevious = true;
  }

  const bool discardInvalidActive = !activeStatus.ok &&
                                    activeStatus.code == "active_invalid" &&
                                    !restoredPrevious;
  const bool discardIncompleteSelection =
      activePointsToNewRoot && !restoredPrevious;
  const bool cleanupComplete =
      (!(discardInvalidActive || discardIncompleteSelection) ||
       removeTree(activePath)) &&
      removeTree(joinPath(storageRoot_, root)) &&
      (preserveStagedArchive || removeTree(stagingRoot(sessionId))) &&
      removeTree(activePath + ".bak") && removeTree(activePath + ".tmp") &&
      removeTree(transactionPath + ".bak") &&
      removeTree(transactionPath + ".tmp");
  if (!cleanupComplete || !removeTree(transactionPath))
    return fail("transaction_cleanup",
                "could not clear interrupted map version");
  return {true, "recovered_rollback", "rolled back interrupted map activation"};
}

InstallStatus
MapTransferInstaller::rollbackActiveMap(const std::string &sessionId) const {
  if (!safeId(sessionId))
    return fail("active_rollback_session", "rollback session is invalid");
  ActiveMapSelection selected;
  const InstallStatus active = readActiveMap(selected);
  if (!active.ok)
    return active;
  if (selected.sessionId != sessionId)
    return fail("active_rollback_conflict",
                "active map no longer matches renderer rollback session");
  if (selected.previousRoot.empty()) {
    const std::string activePath =
        joinPath(storageRoot_, kActiveMapFile);
    if (!removeTree(activePath) || !removeTree(activePath + ".bak") ||
        !removeTree(activePath + ".tmp")) {
      return fail("active_rollback_clear",
                  "could not clear rejected first map selection");
    }
    return {true, "active_cleared",
            "cleared rejected first map selection"};
  }
  if (!rollbackRootMatches(selected.previousRoot, selected.previousMapId,
                           selected.previousManifestReceipt,
                           selected.previousSignedManifestReceipt)) {
    return fail("active_rollback_unavailable",
                "previous map is unavailable for renderer rollback");
  }
  ActiveMapSelection rollback;
  rollback.mapId = selected.previousMapId;
  rollback.sessionId = selected.previousSessionId;
  rollback.root = selected.previousRoot;
  rollback.target = selected.previousTarget;
  rollback.manifestReceipt = selected.previousManifestReceipt;
  rollback.signedManifestReceipt = selected.previousSignedManifestReceipt;
  if (!writeActiveMap(rollback))
    return fail("active_rollback_write",
                "could not restore previous active map selection");
  return {true, "active_rolled_back",
          "restored previous map after renderer reload failure"};
}

InstallStatus MapTransferInstaller::discardIncompleteStreamMap(
    const std::string &sessionId) const {
  if (!safeId(sessionId))
    return fail("stream_discard_session", "stream session is invalid");
  const std::string relativeRoot =
      std::string("/VECTMAP/.maps/") + sessionId;
  ActiveMapSelection selected;
  const InstallStatus active = readActiveMap(selected);
  if (active.ok &&
      (selected.root == relativeRoot || selected.previousRoot == relativeRoot)) {
    return fail("stream_discard_active",
                "cannot discard an active or rollback map root");
  }
  if (!active.ok && active.code != "active_missing")
    return active;
  const std::string root = joinPath(storageRoot_, relativeRoot);
  if (fileExists(joinPath(root, kStreamReadyFile)) ||
      fileExists(joinPath(root, kStreamReadyFile) + ".bak")) {
    return fail("stream_discard_ready",
                "cannot discard a ready stream map as incomplete");
  }
  if (!removeTree(root))
    return fail("stream_discard_cleanup",
                "could not remove incomplete stream map root");
  return {true, "stream_discarded", "removed incomplete stream map root"};
}

InstallStatus MapTransferInstaller::discardUnselectedStreamMap(
    const std::string &sessionId) const {
  if (!safeId(sessionId))
    return fail("stream_discard_session", "stream session is invalid");
  const std::string relativeRoot =
      std::string("/VECTMAP/.maps/") + sessionId;
  ActiveMapSelection selected;
  const InstallStatus active = readActiveMap(selected);
  if (active.ok &&
      (selected.root == relativeRoot || selected.previousRoot == relativeRoot)) {
    return fail("stream_discard_active",
                "cannot discard an active or rollback map root");
  }
  if (!active.ok && active.code != "active_missing")
    return active;

  std::string pending;
  const std::string pendingPath =
      joinPath(storageRoot_, kPendingStreamActivationFile);
  for (const std::string &candidate : {pendingPath, pendingPath + ".bak"}) {
    if (readTextFile(candidate, pending, 2048) &&
        jsonStringValue(pending, "sessionId") != sessionId) {
      return fail("stream_discard_pending_conflict",
                  "another streamed map owns the pending activation marker");
    }
  }
  if (!removeTree(joinPath(storageRoot_, relativeRoot)) ||
      !removeTree(pendingPath) || !removeTree(pendingPath + ".bak") ||
      !removeTree(pendingPath + ".tmp")) {
    return fail("stream_discard_cleanup",
                "could not remove superseded stream map state");
  }
  return {true, "stream_superseded",
          "removed streamed map superseded by archive transfer"};
}

InstallStatus MapTransferInstaller::discardAllUnselectedStreamMaps() const {
  ActiveMapSelection selected;
  const InstallStatus active = readActiveMap(selected);
  if (!active.ok && active.code != "active_missing")
    return active;

  const std::string mapsRoot = joinPath(storageRoot_, "/VECTMAP/.maps");
  DIR *directory = ::opendir(mapsRoot.c_str());
  if (directory == nullptr && errno != ENOENT) {
    return fail("stream_discard_scan",
                "could not scan unselected streamed maps");
  }
  bool cleaned = true;
  if (directory != nullptr) {
    while (struct dirent *entry = ::readdir(directory)) {
      const std::string sessionId = entry->d_name;
      if (sessionId == "." || sessionId == "..")
        continue;
      if (!safeId(sessionId)) {
        cleaned = false;
        continue;
      }
      const std::string relativeRoot =
          std::string("/VECTMAP/.maps/") + sessionId;
      if (relativeRoot == selected.root ||
          relativeRoot == selected.previousRoot) {
        continue;
      }
      const std::string root = joinPath(mapsRoot, sessionId);
      const bool streamState =
          fileExists(joinPath(root, kStreamReadyFile)) ||
          fileExists(joinPath(root, kStreamReadyFile) + ".bak") ||
          fileExists(joinPath(root, kStreamInstallingFile)) ||
          fileExists(joinPath(root, kStreamInstallingFile) + ".bak");
      if (streamState && !removeTree(root))
        cleaned = false;
    }
    ::closedir(directory);
  }

  const std::string pendingPath =
      joinPath(storageRoot_, kPendingStreamActivationFile);
  cleaned = removeTree(pendingPath) &&
            removeTree(pendingPath + ".bak") &&
            removeTree(pendingPath + ".tmp") && cleaned;
  if (!cleaned) {
    return fail("stream_discard_cleanup",
                "could not remove invalid unselected stream state");
  }
  return {true, "stream_superseded_all",
          "removed unselected streamed map state"};
}

bool MapTransferInstaller::hasInterruptedActivation() const {
  const std::string transactionPath =
      joinPath(storageRoot_, kActivationTransactionFile);
  return fileExists(transactionPath) || fileExists(transactionPath + ".bak");
}

InstallStatus
MapTransferInstaller::readActiveMap(ActiveMapSelection &selection) const {
  selection = ActiveMapSelection();
  const std::string activePath = joinPath(storageRoot_, kActiveMapFile);
  std::string text;
  if (!readTextFile(activePath, text, 2048))
    return fail("active_missing", "active map metadata is missing");
  selection.mapId = jsonStringValue(text, "mapId");
  selection.sessionId = jsonStringValue(text, "sessionId");
  selection.root = jsonStringValue(text, "root");
  bool targetParsed = false;
  selection.target = targetMetadataFromJson(text, "", &targetParsed);
  selection.previousMapId = jsonStringValue(text, "previousMapId");
  selection.previousSessionId = jsonStringValue(text, "previousSessionId");
  selection.previousRoot = jsonStringValue(text, "previousRoot");
  bool previousTargetParsed = false;
  selection.previousTarget =
      targetMetadataFromJson(text, "previous", &previousTargetParsed);
  selection.previousManifestReceipt =
      jsonStringValue(text, "previousManifestReceipt");
  selection.previousSignedManifestReceipt =
      jsonStringValue(text, "previousSignedManifestReceipt");
  selection.manifestReceipt = jsonStringValue(text, "manifestReceipt");
  selection.signedManifestReceipt =
      jsonStringValue(text, "signedManifestReceipt");
  if (selection.root.empty())
    selection.root = "/VECTMAP";
  if (!safeMapId(selection.mapId) || !safeActiveRoot(selection.root) ||
      (!selection.sessionId.empty() && !safeId(selection.sessionId)) ||
      !targetParsed || !targetMetadataValid(selection.target) ||
      (!selection.previousRoot.empty() &&
       (!safeActiveRoot(selection.previousRoot) ||
        !safeMapId(selection.previousMapId) ||
        (!selection.previousSessionId.empty() &&
         !safeId(selection.previousSessionId)) ||
        (selection.previousManifestReceipt.empty() !=
         selection.previousSignedManifestReceipt.empty()) ||
         (!selection.previousManifestReceipt.empty() &&
          (!isHexSha256(selection.previousManifestReceipt) ||
          !isHexSha256(selection.previousSignedManifestReceipt))) ||
        (!previousTargetParsed ||
         !targetMetadataValid(selection.previousTarget)))) ||
      (selection.previousRoot.empty() &&
       (!selection.previousMapId.empty() ||
        !selection.previousSessionId.empty() ||
        !previousTargetParsed ||
        !targetMetadataEmpty(selection.previousTarget) ||
        !selection.previousManifestReceipt.empty() ||
        !selection.previousSignedManifestReceipt.empty())) ||
      (selection.manifestReceipt.empty() !=
       selection.signedManifestReceipt.empty()) ||
      (!selection.manifestReceipt.empty() &&
       (!isHexSha256(selection.manifestReceipt) ||
        !isHexSha256(selection.signedManifestReceipt)))) {
    return fail("active_invalid", "active map metadata is invalid");
  }
  return {true, "ok", ""};
}

InstallStatus MapTransferInstaller::readActiveMapId(std::string &mapId) const {
  ActiveMapSelection selection;
  InstallStatus status = readActiveMap(selection);
  if (status.ok)
    mapId = selection.mapId;
  return status;
}

InstallStatus
MapTransferInstaller::readActiveManifest(MapManifest &manifest) const {
  ActiveMapSelection selection;
  const InstallStatus active = readActiveMap(selection);
  if (!active.ok)
    return active;
  return readInstalledManifest(selection.root, manifest);
}

InstallStatus MapTransferInstaller::readActiveMapPresentation(
    ActiveMapSelection &selection,
    MapPresentationMetadata &presentation) const {
  selection = ActiveMapSelection();
  presentation = MapPresentationMetadata();
  const InstallStatus active = readActiveMap(selection);
  if (!active.ok)
    return active;
  if (!safeActiveRoot(selection.root) || !activeRootExists(selection.root))
    return fail("installed_root", "installed map root is missing");
  std::string manifestText;
  if (!readTextFile(joinPath(joinPath(storageRoot_, selection.root),
                             kInstalledManifestFile),
                    manifestText, kMaxManifestBytes)) {
    return fail("installed_manifest", "installed map manifest is missing");
  }
  if (jsonStringValue(manifestText, "mapId") != selection.mapId) {
    return fail("installed_manifest_identity",
                "installed map manifest does not match active map ID");
  }
  if (!selection.manifestReceipt.empty()) {
    const std::string receipt = sha256Hex(
        reinterpret_cast<const uint8_t *>(manifestText.data()),
        manifestText.size());
    std::string expectedReceipt = selection.manifestReceipt;
    std::transform(expectedReceipt.begin(), expectedReceipt.end(),
                   expectedReceipt.begin(), ::tolower);
    if (receipt != expectedReceipt) {
      return fail("installed_manifest_receipt",
                  "installed map manifest does not match active selection");
    }
    presentation.displayName =
        jsonPresentationStringValue(manifestText, "displayName");
    presentation.hasBoundsE7 =
        jsonPresentationBoundsE7(manifestText, presentation.boundsE7);
    return {true, "ok", ""};
  }
  MapManifest manifest;
  const InstallStatus status = validateManifestText(manifestText, manifest);
  if (!status.ok)
    return status;
  presentation.displayName = manifest.displayName;
  presentation.boundsE7 = manifest.boundsE7;
  presentation.hasBoundsE7 = manifest.hasBoundsE7;
  return status;
}

bool MapTransferInstaller::readActiveMapPresentationRevision(
    const ActiveMapSelection &selection,
    MapPresentationRevision &revision) const {
  revision = MapPresentationRevision();
  if (!safeActiveRoot(selection.root))
    return false;
  struct stat info = {};
  const std::string path = joinPath(
      joinPath(storageRoot_, selection.root), kInstalledManifestFile);
  if (::stat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode) ||
      info.st_size <= 0 ||
      static_cast<uint64_t>(info.st_size) > kMaxManifestBytes) {
    return false;
  }
  revision.bytes = static_cast<uint64_t>(info.st_size);
  revision.modifiedSeconds = static_cast<int64_t>(info.st_mtime);
  revision.inode = static_cast<uint64_t>(info.st_ino);
  return true;
}

bool MapTransferInstaller::pruneStagingSessions(
    const std::string &keepSessionId) const {
  if (!safeId(keepSessionId))
    return false;
  const std::string root = joinPath(storageRoot_, "VECTMAP/.staging");
  DIR *dir = ::opendir(root.c_str());
  if (!dir)
    return errno == ENOENT;
  bool ok = true;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    const std::string name = entry->d_name;
    if (name == "." || name == ".." || name == keepSessionId)
      continue;
    // The SD card can contain metadata created by another OS or an older
    // firmware. Preserve entries outside our session-id namespace instead of
    // allowing an unrelated file to block a new map upload.
    if (!safeId(name))
      continue;
    if (!removeTree(joinPath(root, name)))
      ok = false;
  }
  ::closedir(dir);
  return ok;
}

bool MapTransferInstaller::pruneObsoleteInstalledMaps(
    const std::string &keepInstallingSessionId) const {
  if (!keepInstallingSessionId.empty() && !safeId(keepInstallingSessionId))
    return false;
  ActiveMapSelection selected;
  InstallStatus status = readActiveMap(selected);
  if (!status.ok && status.code != "active_missing")
    return false;
  const std::string root = joinPath(storageRoot_, "VECTMAP/.maps");
  std::string pendingRoot;
  std::string pending;
  const std::string pendingPath =
      joinPath(storageRoot_, kPendingStreamActivationFile);
  if (readTextFile(pendingPath, pending, 2048) ||
      readTextFile(pendingPath + ".bak", pending, 2048)) {
    const std::string candidate = jsonStringValue(pending, "root");
    if (safeActiveRoot(candidate))
      pendingRoot = candidate;
  }
  std::string transactionRoot;
  std::string transactionPreviousRoot;
  std::string transaction;
  if (readTextFile(joinPath(storageRoot_, kActivationTransactionFile),
                   transaction, 2048)) {
    const std::string candidate = jsonStringValue(transaction, "root");
    const std::string previousCandidate =
        jsonStringValue(transaction, "previousRoot");
    if (safeActiveRoot(candidate))
      transactionRoot = candidate;
    if (safeActiveRoot(previousCandidate))
      transactionPreviousRoot = previousCandidate;
  }
  DIR *dir = ::opendir(root.c_str());
  if (!dir)
    return errno == ENOENT;
  bool ok = true;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    const std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    const std::string candidate = std::string("/VECTMAP/.maps/") + name;
    const std::string candidatePath = joinPath(root, name);
    const bool consumed =
        fileExists(joinPath(candidatePath, kStreamConsumedFile)) ||
        fileExists(joinPath(candidatePath, kStreamConsumedFile) + ".bak");
    ReadyStreamMap recoverableReady;
    const bool freshReady =
        !consumed &&
        (fileExists(joinPath(candidatePath, kStreamReadyFile)) ||
         fileExists(joinPath(candidatePath, kStreamReadyFile) + ".bak")) &&
        readReadyStreamMap(name, recoverableReady).ok;
    if (candidate == selected.root || candidate == selected.previousRoot ||
        candidate == pendingRoot || candidate == transactionRoot ||
        candidate == transactionPreviousRoot ||
        freshReady ||
        ((keepInstallingSessionId.empty() ||
          name == keepInstallingSessionId) &&
         (fileExists(joinPath(candidatePath, kStreamInstallingFile)) ||
          fileExists(joinPath(candidatePath, kStreamInstallingFile) +
                     ".bak")))) {
      continue;
    }
    // Only delete directories that belong to our map-session namespace.
    // Foreign filesystem metadata must not make map installation fail.
    if (!safeId(name))
      continue;
    if (!removeTree(candidatePath))
      ok = false;
  }
  ::closedir(dir);
  if (selected.root != "/VECTMAP" && selected.previousRoot == "/VECTMAP") {
    const std::string vectmapRoot = joinPath(storageRoot_, "VECTMAP");
    DIR *legacy = ::opendir(vectmapRoot.c_str());
    if (!legacy)
      return false;
    while ((entry = ::readdir(legacy)) != nullptr) {
      const std::string name = entry->d_name;
      if (name == "." || name == ".." || name[0] == '.' ||
          startsWith(name, "active-map.json")) {
        continue;
      }
      if (!removeTree(joinPath(vectmapRoot, name)))
        ok = false;
    }
    ::closedir(legacy);
  }
  return ok;
}

bool MapTransferInstaller::markPendingArchiveActivation(
    const std::string &sessionId) const {
  if (!safeId(sessionId))
    return false;
  const std::string path =
      joinPath(storageRoot_, kPendingArchiveActivationFile);
  return mkdirs(dirnameOf(path)) && writeTextFileAtomic(path, sessionId);
}

bool MapTransferInstaller::readPendingArchiveActivation(
    std::string &sessionId) const {
  const std::string path =
      joinPath(storageRoot_, kPendingArchiveActivationFile);
  std::string value;
  if (!readTextFile(path, value, 80) || !safeId(value))
    return false;
  sessionId = value;
  return true;
}

bool MapTransferInstaller::clearPendingArchiveActivation() const {
  const std::string path =
      joinPath(storageRoot_, kPendingArchiveActivationFile);
  return removeTree(path) && removeTree(path + ".bak") &&
         removeTree(path + ".tmp");
}

bool MapTransferInstaller::discardStagedSession(
    const std::string &sessionId) const {
  return safeId(sessionId) && removeTree(stagingRoot(sessionId));
}

std::string
MapTransferInstaller::stagingRoot(const std::string &sessionId) const {
  return joinPath(joinPath(storageRoot_, "VECTMAP/.staging"), sessionId);
}

std::string
MapTransferInstaller::stagedArchivePath(const std::string &sessionId) const {
  return joinPath(stagingRoot(sessionId), "pack.zip");
}

InstallStatus MapTransferInstaller::fail(const std::string &code,
                                         const std::string &message) const {
  return {false, code, message};
}

bool MapTransferInstaller::safeId(const std::string &value) const {
  if (value.empty() || value.size() > 80 || value[0] == '.')
    return false;
  for (char c : value) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) {
      return false;
    }
  }
  return value.find("..") == std::string::npos;
}

bool MapTransferInstaller::safeMapId(const std::string &value) const {
  if (value.empty() || value.size() > 64 || value == "." || value == "..")
    return false;
  for (char c : value) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) {
      return false;
    }
  }
  return true;
}

bool MapTransferInstaller::safeActiveRoot(const std::string &value) const {
  if (value == "/VECTMAP")
    return true;
  const std::string prefix = "/VECTMAP/.maps/";
  return startsWith(value, prefix) && safeId(value.substr(prefix.size())) &&
         value.find('/', prefix.size()) == std::string::npos;
}

bool MapTransferInstaller::safeRelativePath(const std::string &path) const {
  if (path.empty() || path[0] == '/' || path.size() > 240 ||
      path.find('\\') != std::string::npos ||
      path.find("//") != std::string::npos)
    return false;
  std::stringstream stream(path);
  std::string part;
  while (std::getline(stream, part, '/')) {
    if (part.empty() || part == "." || part == "..")
      return false;
  }
  return path.find("..") == std::string::npos;
}

bool MapTransferInstaller::mkdirs(const std::string &path) const {
  if (path.empty())
    return false;
  std::string current;
  size_t i = 0;
  if (path[0] == '/') {
    current = "/";
    i = 1;
  }
  while (i <= path.size()) {
    size_t slash = path.find('/', i);
    std::string part =
        path.substr(i, slash == std::string::npos ? slash : slash - i);
    if (!part.empty()) {
      if (current.size() > 1)
        current += "/";
      current += part;
      if (::mkdir(current.c_str(), 0755) != 0 && errno != EEXIST)
        return false;
    }
    if (slash == std::string::npos)
      break;
    i = slash + 1;
  }
  return true;
}

bool MapTransferInstaller::copyFile(const std::string &from,
                                    const std::string &to) const {
  std::ifstream input(from, std::ios::binary);
  if (!input)
    return false;
  std::ofstream output(to, std::ios::binary | std::ios::trunc);
  if (!output)
    return false;
  std::array<char, 4096> buffer = {};
  while (input.good()) {
    input.read(buffer.data(), buffer.size());
    const std::streamsize count = input.gcount();
    if (count > 0)
      output.write(buffer.data(), count);
    if (!output.good())
      return false;
  }
  output.flush();
  if (!input.eof() || !output.good())
    return false;
  output.close();
  return !output.fail();
}

bool MapTransferInstaller::copyTree(const std::string &from,
                                    const std::string &to) const {
  struct stat st;
  if (::stat(from.c_str(), &st) != 0)
    return false;
  if (!S_ISDIR(st.st_mode))
    return copyFile(from, to);
  if (!mkdirs(to))
    return false;
  DIR *dir = ::opendir(from.c_str());
  if (!dir)
    return false;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    if (!copyTree(joinPath(from, name), joinPath(to, name))) {
      ::closedir(dir);
      return false;
    }
  }
  ::closedir(dir);
  return true;
}

bool MapTransferInstaller::movePath(const std::string &from,
                                    const std::string &to) const {
  if (!mkdirs(dirnameOf(to)))
    return false;
  if (::rename(from.c_str(), to.c_str()) == 0)
    return true;
  if (!copyTree(from, to))
    return false;
  return removeTree(from);
}

bool MapTransferInstaller::removeTree(const std::string &path) const {
  struct stat st;
  if (::stat(path.c_str(), &st) != 0)
    return true;
  if (!S_ISDIR(st.st_mode))
    return ::unlink(path.c_str()) == 0;
  DIR *dir = ::opendir(path.c_str());
  if (!dir)
    return false;
  struct dirent *entry = nullptr;
  while ((entry = ::readdir(dir)) != nullptr) {
    std::string name = entry->d_name;
    if (name == "." || name == "..")
      continue;
    if (!removeTree(joinPath(path, name))) {
      ::closedir(dir);
      return false;
    }
  }
  ::closedir(dir);
  return ::rmdir(path.c_str()) == 0;
}

std::string
MapTransferInstaller::verificationPath(const std::string &sessionId,
                                       const ManifestFile &file) const {
  const std::string key = sha256Hex(
      reinterpret_cast<const uint8_t *>(file.path.data()), file.path.size());
  return joinPath(joinPath(stagingRoot(sessionId), ".verified"),
                  key + ".sha256");
}

bool MapTransferInstaller::publishStagedFiles(
    const std::string &sessionId, const MapManifest &manifest,
    const std::string &destinationRoot,
    const ActivationProgressCallback &onProgress) const {
  const std::string sourcePrefix =
      std::string(kVectMapPrefix) + manifest.mapId + "/";
  if (!mkdirs(destinationRoot))
    return false;
  uint64_t completed = 0;
  for (const ManifestFile &file : manifest.files) {
    if (!startsWith(file.path, sourcePrefix))
      return false;
    const std::string relative = file.path.substr(sourcePrefix.size());
    const std::string source = joinPath(stagingRoot(sessionId), file.path);
    const std::string destination = joinPath(destinationRoot, relative);
    if (!movePath(source, destination))
      return false;
    completed++;
    if (onProgress)
      onProgress({4, 5, completed, manifest.files.size()});
  }
  return true;
}

bool MapTransferInstaller::publishInstalledMetadata(
    const std::string &sessionId, const MapManifest &manifest,
    const std::string &destinationRoot) const {
  std::string manifestText;
  if (!readTextFile(joinPath(stagingRoot(sessionId), "manifest.json"),
                    manifestText, kMaxManifestBytes)) {
    return false;
  }
  return writeTextFileAtomic(joinPath(destinationRoot, kInstalledManifestFile),
                             manifestText) &&
         writeTextFileAtomic(joinPath(destinationRoot, kInstalledReceiptFile),
                             manifestReceipt(manifest));
}

std::string
MapTransferInstaller::manifestReceipt(const MapManifest &manifest) const {
  std::string value =
      std::to_string(manifest.schemaVersion) + "\n" + manifest.mapId + "\n" +
      manifest.renderer + "\n" + std::to_string(manifest.formatVersion) + "\n" +
      std::to_string(manifest.labelProfileVersion) + "\n";
  for (const std::string &language : manifest.labelLanguages)
    value += language + "\n";
  value += manifest.internationalFallback + "\n" +
           std::to_string(manifest.buildingProfileVersion) + "\n" +
           std::to_string(manifest.buildingRecordCount) + "\n";
  for (uint32_t count : manifest.buildingProvenanceCounts)
    value += std::to_string(count) + "\n";
  value +=
           manifest.minimumFirmwareVersion + "\n";
  for (const ManifestFile &file : manifest.files) {
    value += file.path + "\n" + file.publishPath + "\n" +
             std::to_string(file.bytes) + "\n" + file.sha256 + "\n";
  }
  return sha256Hex(reinterpret_cast<const uint8_t *>(value.data()),
                   value.size());
}

InstallStatus
MapTransferInstaller::readInstalledManifest(const std::string &root,
                                            MapManifest &manifest) const {
  if (!safeActiveRoot(root) || !activeRootExists(root))
    return fail("installed_root", "installed map root is missing");
  std::string text;
  if (!readTextFile(
          joinPath(joinPath(storageRoot_, root), kInstalledManifestFile), text,
          kMaxManifestBytes)) {
    return fail("installed_manifest", "installed map manifest is missing");
  }
  return validateManifestText(text, manifest);
}

InstallStatus MapTransferInstaller::validateLabelContracts(
    const std::string &root, const MapManifest &manifest,
    bool useManifestPaths) const {
  if (manifest.formatVersion != 2 && manifest.formatVersion != 3)
    return {true, "ok", ""};
  const auto resolvedPath = [&](const ManifestFile &file) {
    if (useManifestPaths)
      return joinPath(root, file.path);
    const std::string prefix = kVectMapPrefix;
    if (!startsWith(file.publishPath, prefix))
      return std::string();
    return joinPath(root, file.publishPath.substr(prefix.size()));
  };

  const ManifestFile *fontFile = nullptr;
  for (const ManifestFile &file : manifest.files) {
    if (isFontAssetPath(file.path, manifest.mapId)) {
      fontFile = &file;
      break;
    }
  }
  if (fontFile == nullptr)
    return fail("label_font_missing", "label-aware map has no FMA1 asset");
  map_font_asset::Asset font;
  if (!font.open(resolvedPath(*fontFile)))
    return fail("label_font_invalid", "label-aware FMA1 asset is invalid");
  if (font.languageCount() != manifest.labelLanguages.size())
    return fail("label_languages", "FMA1 languages do not match manifest");
  for (uint8_t index = 0; index < font.languageCount(); ++index)
    if (font.language(index) != manifest.labelLanguages[index])
      return fail("label_languages", "FMA1 languages do not match manifest");

  for (const ManifestFile &file : manifest.files) {
    if (file.path.size() < 4 ||
        file.path.compare(file.path.size() - 4, 4, ".fmb") != 0)
      continue;
    const std::string path = resolvedPath(file);
    if (path.empty())
      return fail("label_block_path", "label-aware block path is invalid");
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input || input.tellg() <= 0 ||
        static_cast<uint64_t>(input.tellg()) >
            map_block_format::kMaximumBlockBytes)
      return fail("label_block_open", "could not read label-aware FMB block");
    const size_t size = static_cast<size_t>(input.tellg());
    input.seekg(0, std::ios::beg);
    std::vector<uint8_t> bytes(size);
    input.read(reinterpret_cast<char *>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
    const uint8_t expectedBlockVersion =
        manifest.formatVersion == 3 ? 4 : 3;
    if (!input || bytes.size() < 4 || bytes[3] != expectedBlockVersion)
      return fail("label_block_version",
                  "map block version does not match renderer target");
    map_label_block::Block labels;
    std::string error;
    if (!map_label_block::decode(bytes.data(), bytes.size(),
                                 std::numeric_limits<uint16_t>::max(), labels,
                                 &error) ||
        labels.profileFingerprint != font.profileFingerprint() ||
        !labels.referencesResolve(font.glyphCount(), font.languageCount())) {
      return fail("label_block_contract",
                  "FMB label references do not match FMA1");
    }
  }
  return {true, "ok", ""};
}

bool MapTransferInstaller::installedMapReceiptMatches(
    const std::string &root, const MapManifest &manifest) const {
  if (!activeRootExists(root))
    return false;
  MapManifest installedManifest;
  if (!readInstalledManifest(root, installedManifest).ok ||
      manifestReceipt(installedManifest) != manifestReceipt(manifest)) {
    return false;
  }
  std::string receipt;
  if (!readTextFile(
          joinPath(joinPath(storageRoot_, root), kInstalledReceiptFile),
          receipt, 64) ||
      receipt != manifestReceipt(manifest)) {
    return false;
  }
  const std::string publishPrefix = kVectMapPrefix;
  for (const ManifestFile &file : manifest.files) {
    if (!startsWith(file.publishPath, publishPrefix))
      return false;
    const std::string relative = file.publishPath.substr(publishPrefix.size());
    const std::string path = joinPath(joinPath(storageRoot_, root), relative);
    uint64_t size = 0;
    if (!fileSize(path, size) || size != file.bytes)
      return false;
  }
  return true;
}

bool MapTransferInstaller::installedMapContentsMatch(
    const std::string &root, const MapManifest &manifest) const {
  if (!installedMapReceiptMatches(root, manifest))
    return false;
  const std::string publishPrefix = kVectMapPrefix;
  for (const ManifestFile &file : manifest.files) {
    const std::string relative = file.publishPath.substr(publishPrefix.size());
    const std::string path = joinPath(joinPath(storageRoot_, root), relative);
    std::string actual;
    if (!fileSha256Hex(path, actual))
      return false;
    std::transform(actual.begin(), actual.end(), actual.begin(), ::tolower);
    std::string expected = file.sha256;
    std::transform(expected.begin(), expected.end(), expected.begin(),
                   ::tolower);
    if (actual != expected)
      return false;
  }
  return true;
}

bool MapTransferInstaller::writeActiveMap(
    const ActiveMapSelection &selection) const {
  if (!safeMapId(selection.mapId) || !safeActiveRoot(selection.root) ||
      (!selection.sessionId.empty() && !safeId(selection.sessionId)) ||
      !targetMetadataValid(selection.target) ||
      (!selection.previousRoot.empty() &&
       (!safeActiveRoot(selection.previousRoot) ||
        !safeMapId(selection.previousMapId) ||
        (!selection.previousSessionId.empty() &&
         !safeId(selection.previousSessionId)) ||
        (selection.previousManifestReceipt.empty() !=
         selection.previousSignedManifestReceipt.empty()) ||
         (!selection.previousManifestReceipt.empty() &&
          (!isHexSha256(selection.previousManifestReceipt) ||
          !isHexSha256(selection.previousSignedManifestReceipt))) ||
        !targetMetadataValid(selection.previousTarget))) ||
      (selection.previousRoot.empty() &&
       (!selection.previousMapId.empty() ||
        !selection.previousSessionId.empty() ||
        !targetMetadataEmpty(selection.previousTarget) ||
        !selection.previousManifestReceipt.empty() ||
        !selection.previousSignedManifestReceipt.empty())) ||
      (selection.manifestReceipt.empty() !=
       selection.signedManifestReceipt.empty()) ||
      (!selection.manifestReceipt.empty() &&
       (!isHexSha256(selection.manifestReceipt) ||
        !isHexSha256(selection.signedManifestReceipt)))) {
    return false;
  }
  std::string json = std::string("{\"mapId\":\"") +
                     jsonEscape(selection.mapId) + "\",\"sessionId\":\"" +
                     jsonEscape(selection.sessionId) + "\",\"root\":\"" +
                     jsonEscape(selection.root) + "\"" +
                     targetMetadataJson(selection.target, "");
  if (!selection.previousRoot.empty()) {
    json += ",\"previousMapId\":\"" + jsonEscape(selection.previousMapId) +
            "\",\"previousSessionId\":\"" +
            jsonEscape(selection.previousSessionId) + "\",\"previousRoot\":\"" +
            jsonEscape(selection.previousRoot) + "\"" +
            targetMetadataJson(selection.previousTarget, "previous");
    if (!selection.previousManifestReceipt.empty()) {
      json += ",\"previousManifestReceipt\":\"" +
              selection.previousManifestReceipt +
              "\",\"previousSignedManifestReceipt\":\"" +
              selection.previousSignedManifestReceipt + "\"";
    }
  }
  if (!selection.manifestReceipt.empty()) {
    json += ",\"manifestReceipt\":\"" + selection.manifestReceipt +
            "\",\"signedManifestReceipt\":\"" +
            selection.signedManifestReceipt + "\"";
  }
  json += "}\n";
  return writeTextFileAtomic(joinPath(storageRoot_, kActiveMapFile), json);
}

bool MapTransferInstaller::activeRootExists(const std::string &root) const {
  if (!safeActiveRoot(root))
    return false;
  const std::string path = joinPath(storageRoot_, root);
  if (!dirExists(path))
    return false;
  if (root == "/VECTMAP")
    return true;
  const bool installing =
      fileExists(joinPath(path, kStreamInstallingFile)) ||
      fileExists(joinPath(path, kStreamInstallingFile) + ".bak");
  const bool readyMarker =
      fileExists(joinPath(path, kStreamReadyFile)) ||
      fileExists(joinPath(path, kStreamReadyFile) + ".bak");
  if (installing && !readyMarker) {
    return false;
  }
  if (readyMarker) {
    const std::string prefix = "/VECTMAP/.maps/";
    ReadyStreamMap ready;
    return readReadyStreamMap(root.substr(prefix.size()), ready).ok;
  }
  // Protocol-v1 roots predate `.ready`; their transaction path retains its
  // existing compatibility validation.
  return true;
}

bool MapTransferInstaller::rollbackRootMatches(
    const std::string &root, const std::string &mapId,
    const std::string &manifestReceipt,
    const std::string &signedManifestReceipt) const {
  if (!activeRootExists(root))
    return false;
  if (manifestReceipt.empty() && signedManifestReceipt.empty())
    return true;
  const std::string prefix = "/VECTMAP/.maps/";
  if (!startsWith(root, prefix))
    return false;
  ReadyStreamMap ready;
  return readReadyStreamMap(root.substr(prefix.size()), ready).ok &&
         ready.mapId == mapId && ready.manifestReceipt == manifestReceipt &&
         ready.signedManifestReceipt == signedManifestReceipt;
}

bool MapTransferInstaller::fileExists(const std::string &path) const {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

bool MapTransferInstaller::dirExists(const std::string &path) const {
  struct stat st;
  return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool MapTransferInstaller::fileSize(const std::string &path,
                                    uint64_t &size) const {
  struct stat st;
  if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode))
    return false;
  size = static_cast<uint64_t>(st.st_size);
  return true;
}

bool MapTransferInstaller::fileSha256Hex(const std::string &path,
                                         std::string &hex) const {
  std::ifstream input(path, std::ios::binary);
  if (!input)
    return false;
  Sha256Hasher sha;
  std::array<uint8_t, 1024> buffer = {};
  while (input.good()) {
    input.read(reinterpret_cast<char *>(buffer.data()), buffer.size());
    std::streamsize n = input.gcount();
    if (n > 0)
      sha.update(buffer.data(), static_cast<size_t>(n));
  }
  if (!input.eof())
    return false;
  hex = sha.finalHex();
  return true;
}

bool MapTransferInstaller::writeTextFile(const std::string &path,
                                         const std::string &text) const {
  if (!mkdirs(dirnameOf(path)))
    return false;
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output)
    return false;
  output << text;
  output.flush();
  if (!output.good())
    return false;
  output.close();
  return !output.fail();
}

bool MapTransferInstaller::writeTextFileAtomic(const std::string &path,
                                               const std::string &text) const {
  const std::string temporaryPath = path + ".tmp";
  const std::string backupPath = path + ".bak";
  removeTree(temporaryPath);
  if (!writeTextFile(temporaryPath, text))
    return false;

  // POSIX filesystems replace the destination atomically. Some embedded FAT
  // implementations reject replacement, so retain a recoverable backup while
  // using their two-rename fallback.
  if (::rename(temporaryPath.c_str(), path.c_str()) == 0) {
    removeTree(backupPath);
    return true;
  }

  removeTree(backupPath);
  const bool hadPrevious = fileExists(path);
  if (hadPrevious && ::rename(path.c_str(), backupPath.c_str()) != 0) {
    removeTree(temporaryPath);
    return false;
  }
  if (::rename(temporaryPath.c_str(), path.c_str()) != 0) {
    if (hadPrevious)
      ::rename(backupPath.c_str(), path.c_str());
    removeTree(temporaryPath);
    return false;
  }
  removeTree(backupPath);
  return true;
}

bool MapTransferInstaller::readTextFile(const std::string &path,
                                        std::string &text,
                                        size_t maxBytes) const {
  uint64_t size = 0;
  if (!fileSize(path, size) || size > maxBytes)
    return false;
  std::ifstream input(path, std::ios::binary);
  if (!input)
    return false;
  text.assign((std::istreambuf_iterator<char>(input)),
              std::istreambuf_iterator<char>());
  return true;
}

} // namespace map_transfer
