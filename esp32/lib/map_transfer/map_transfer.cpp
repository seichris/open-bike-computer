#include "map_transfer.hpp"
#include "map_file_io.hpp"
#include "../ble_navigation/map_profile_protocol.hpp"
#include "map_operation_journal.hpp"
#include "map_selection_anchor.hpp"
#include "map_activation_workspace.hpp"
#include "../maps/src/mapRendererFileValidator.hpp"
#include "../maps/src/mapFontAsset.hpp"
#include "../maps/src/mapBuildingBlock.hpp"
#include "../maps/src/mapLabelBlock.hpp"
#include "../maps/src/mapPoiBlock.hpp"
#include "../maps/src/mapPoiIndex.hpp"
#include "../maps/src/mapContourBlock.hpp"

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
#include <limits>
#include <memory>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace map_transfer {
namespace {

struct DirectoryCloser { void operator()(DIR *dir) const noexcept { ::closedir(dir); } };
using FileHandle = descriptor_file::File;

struct ActivationOperationWorkspace {
  MapOperationStorage storage;
  operation::Store store;
  ActivationOperationWorkspace(const std::string &root, const std::string &device)
      : storage(root), store(storage, device) {}
};

constexpr const char *kVectMapPrefix = "VECTMAP/";
constexpr const char *kActiveMapFile = "/VECTMAP/active-map.json";
constexpr const char *kActivationTransactionFile =
    "/VECTMAP/.activation-transaction.json";
constexpr size_t kActivationTransactionBytes = 4096;
// A contour-enabled target 5 map replacing another exceeds 2 KiB.
constexpr size_t kActiveMapBytes = 4096;
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
// Completed library evidence preserved while a same-content operation owns the
// root between promotion and its terminal result.
constexpr const char *kLibraryRetainedFile = ".library-retained";
constexpr const char *kManualSelectionIntentFile =
    "/VECTMAP/.library-selection-intent.json";
constexpr const char *kRendererValidationReceiptPrefix = "renderer-v1:";
// Large city packs can contain several thousand map files; their hash manifest
// is currently about 1 MB for 5,500 entries. Keep a firm upper bound while
// allowing those production packs to validate in PSRAM-backed builds.
constexpr size_t kMaxManifestBytes = 2 * 1024 * 1024;
constexpr uint32_t kZipLocalHeaderSignature = 0x04034b50;
constexpr uint32_t kZipCentralHeaderSignature = 0x02014b50;
constexpr uint32_t kZipEndSignature = 0x06054b50;

static bool isMapBlockPath(std::string_view path) {
  if (path.size() < 4)
    return false;
  const auto extension = path.substr(path.size() - 4);
// Terrain sidecars remain authenticated on production, which ignores their rendering.
  return extension == ".fme" || extension == ".fmb" || extension == ".fmp";
}

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

static std::string joinPath(const std::string &a, std::string_view b) {
  if (a.empty())
    return std::string(b);
  if (b.empty())
    return a;
  std::string result=a;
  if (result.back()!='/') result.push_back('/');
  if (b.front()=='/') b.remove_prefix(1);
  result.append(b.data(),b.size());
  return result;
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

static bool startsWith(const std::string &value, std::string_view prefix) {
  return value.size() >= prefix.size() &&
         value.compare(0, prefix.size(), prefix.data(),prefix.size()) == 0;
}

static size_t jsonKeyPosition(const std::string &json,std::string_view key) {
  if (key.empty()) return json.find("\"\"");
  size_t position=json.find(key.data(),0,key.size());
  while (position!=std::string::npos) {
    size_t colon=position+key.size()+1;
    while (colon<json.size() && std::isspace(static_cast<unsigned char>(json[colon]))) ++colon;
    // Only a quoted name followed by a colon is a key. A string value that
    // equals one, such as a user's map display name, is skipped.
    if (position!=0 && json[position-1]=='"' && position+key.size()<json.size() &&
        json[position+key.size()]=='"' && colon<json.size() && json[colon]==':') return position-1;
    position=json.find(key.data(),position+1,key.size());
  }
  return std::string::npos;
}

static std::string jsonStringValue(const std::string &json,
                                   std::string_view key) {
  size_t pos = jsonKeyPosition(json,key);
  if (pos == std::string::npos)
    return "";
  pos = json.find(':', pos + key.size()+2);
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

static uint64_t jsonUintValue(const std::string &json, std::string_view key) {
  size_t pos = jsonKeyPosition(json,key);
  if (pos == std::string::npos)
    return 0;
  pos = json.find(':', pos + key.size()+2);
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

static std::string jsonObjectValue(const std::string &json,
                                   const std::string &key) {
  size_t cursor = jsonKeyPosition(json, key);
  if (cursor == std::string::npos)
    return {};
  cursor = json.find('{', cursor + key.size() + 2);
  if (cursor == std::string::npos)
    return {};
  const size_t start = cursor;
  size_t depth = 0;
  bool inString = false;
  bool escaped = false;
  for (; cursor < json.size(); ++cursor) {
    const char value = json[cursor];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (inString && value == '\\') {
      escaped = true;
      continue;
    }
    if (value == '"') {
      inString = !inString;
      continue;
    }
    if (inString)
      continue;
    if (value == '{')
      ++depth;
    else if (value == '}' && --depth == 0)
      return json.substr(start, cursor - start + 1U);
  }
  return {};
}

static std::vector<std::string>
jsonStringArrayValue(const std::string &json, const std::string &key,
                     bool *valid = nullptr) {
  if (valid != nullptr)
    *valid = false;
  std::vector<std::string> values;
  size_t cursor = jsonKeyPosition(json, key);
  if (cursor == std::string::npos)
    return values;
  cursor = json.find('[', cursor + key.size() + 2);
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

static bool isHexSha256(const std::string &value);

static MapTargetMetadata targetMetadata(const MapManifest &manifest) {
  MapTargetMetadata target;
  target.renderer = manifest.renderer;
  target.formatVersion = manifest.formatVersion;
  target.labelProfileVersion = manifest.labelProfileVersion;
  target.labelLanguages = manifest.labelLanguages;
  target.internationalFallback = manifest.internationalFallback;
  target.buildingProfileVersion = manifest.buildingProfileVersion;
  target.poiProfileVersion = manifest.poiProfileVersion;
  target.poiIndexProfileVersion = manifest.poiIndexProfileVersion;
  target.poiRecordCount = manifest.poiRecordCount;
  target.contoursIncluded = manifest.contoursIncluded;
  for (const ManifestFile &file : manifest.files)
    if (file.path == std::string(kVectMapPrefix) + manifest.mapId +
                         "/assets/nearby-pois.fpi")
      target.poiIndexSha256 = file.sha256;
  target.topographyProfileVersion = manifest.topographyProfileVersion;
  target.topographyQualityMode = manifest.contourQualityMode;
  target.contourMinorIntervalM = manifest.contourMinorIntervalM;
  target.contourIndexIntervalM = manifest.contourIndexIntervalM;
  target.contourRecordCount = manifest.contourRecordCount;
  target.contourNoDataMillionths = manifest.contourNoDataMillionths;
  target.topographySourcePolicySha256 =
      manifest.topographySourcePolicySha256;
  return target;
}

static bool targetMetadataEmpty(const MapTargetMetadata &target) {
  return target.renderer.empty() && target.formatVersion == 0 &&
         target.labelProfileVersion == 0 && target.labelLanguages.empty() &&
         target.internationalFallback.empty() &&
         target.buildingProfileVersion == 0 &&
         target.poiProfileVersion == 0 &&
         target.poiIndexProfileVersion == 0 &&
         target.poiRecordCount == 0 && !target.contoursIncluded &&
         target.poiIndexSha256.empty() &&
         target.topographyProfileVersion == 0 &&
         target.topographyQualityMode.empty() &&
         target.contourMinorIntervalM == 0 &&
         target.contourIndexIntervalM == 0 &&
         target.contourRecordCount == 0 &&
         target.contourNoDataMillionths == 0 &&
         target.topographySourcePolicySha256.empty();
}

static bool targetMetadataValid(const MapTargetMetadata &target) {
  if (targetMetadataEmpty(target))
    return true;
  if (target.renderer != "esp32-fmb" ||
      (target.formatVersion != 1 && target.formatVersion != 2 &&
       target.formatVersion != 3 && target.formatVersion != 4 &&
       target.formatVersion != 5)) {
    return false;
  }
  if (target.formatVersion == 1) {
    return target.labelProfileVersion == 0 &&
           target.labelLanguages.empty() &&
           target.internationalFallback.empty() &&
           target.buildingProfileVersion == 0 &&
           target.poiProfileVersion == 0 &&
           target.poiIndexProfileVersion == 0 &&
           target.poiRecordCount == 0 && !target.contoursIncluded &&
           target.poiIndexSha256.empty() &&
           target.topographyProfileVersion == 0 &&
           target.topographyQualityMode.empty() &&
           target.contourMinorIntervalM == 0 &&
           target.contourIndexIntervalM == 0 &&
           target.contourRecordCount == 0 &&
           target.contourNoDataMillionths == 0 &&
           target.topographySourcePolicySha256.empty();
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
  const bool buildingsValid =
      (target.formatVersion >= 3)
          ? target.buildingProfileVersion == 1
          : target.buildingProfileVersion == 0;
  const bool contourIntervalsValid =
      (target.contourMinorIntervalM == 20 &&
       target.contourIndexIntervalM == 100) ||
      (target.contourMinorIntervalM == 50 &&
       target.contourIndexIntervalM == 250);
  const bool topographyValid = (target.formatVersion == 4 ||
                                (target.formatVersion == 5 &&
                                 target.contoursIncluded))
      ? target.topographyProfileVersion == 1 && contourIntervalsValid &&
            (target.topographyQualityMode == "standard-20m-v1" ||
             target.topographyQualityMode == "coarse-50m-v1") &&
            target.contourNoDataMillionths <= 1000000 &&
            isHexSha256(target.topographySourcePolicySha256)
      : target.topographyProfileVersion == 0 &&
            target.topographyQualityMode.empty() &&
            target.contourMinorIntervalM == 0 &&
            target.contourIndexIntervalM == 0 &&
            target.contourRecordCount == 0 &&
            target.contourNoDataMillionths == 0 &&
            target.topographySourcePolicySha256.empty();
  const bool poiValid = target.formatVersion == 5
      ? target.poiProfileVersion == 1 &&
            target.poiIndexProfileVersion == 1 &&
            isHexSha256(target.poiIndexSha256)
      : target.poiProfileVersion == 0 &&
            target.poiIndexProfileVersion == 0 &&
            target.poiRecordCount == 0 && !target.contoursIncluded &&
            target.poiIndexSha256.empty();
  return buildingsValid && topographyValid && poiValid;
}

static bool targetMetadataMatches(const MapTargetMetadata &left,
                                  const MapTargetMetadata &right) {
  return left.renderer == right.renderer &&
         left.formatVersion == right.formatVersion &&
         left.labelProfileVersion == right.labelProfileVersion &&
         left.labelLanguages == right.labelLanguages &&
         left.internationalFallback == right.internationalFallback &&
         left.buildingProfileVersion == right.buildingProfileVersion &&
         left.poiProfileVersion == right.poiProfileVersion &&
         left.poiIndexProfileVersion == right.poiIndexProfileVersion &&
         left.poiRecordCount == right.poiRecordCount &&
         left.contoursIncluded == right.contoursIncluded &&
         left.poiIndexSha256 == right.poiIndexSha256 &&
         left.topographyProfileVersion == right.topographyProfileVersion &&
         left.topographyQualityMode == right.topographyQualityMode &&
         left.contourMinorIntervalM == right.contourMinorIntervalM &&
         left.contourIndexIntervalM == right.contourIndexIntervalM &&
         left.contourRecordCount == right.contourRecordCount &&
         left.contourNoDataMillionths == right.contourNoDataMillionths &&
         left.topographySourcePolicySha256 ==
             right.topographySourcePolicySha256;
}

static __attribute__((noinline)) MapTargetMetadata targetMetadataFromJson(const std::string &json,
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
  const std::string poiProfileKey = key("PoiProfileVersion");
  const std::string poiIndexProfileKey = key("PoiIndexProfileVersion");
  const std::string poiRecordCountKey = key("PoiRecordCount");
  const std::string contoursIncludedKey = key("ContoursIncluded");
  const std::string poiIndexShaKey = key("PoiIndexSha256");
  const std::string topographyProfileKey = key("TopographyProfileVersion");
  const std::string topographyQualityKey = key("TopographyQualityMode");
  const std::string contourMinorIntervalKey = key("ContourMinorIntervalM");
  const std::string contourIndexIntervalKey = key("ContourIndexIntervalM");
  const std::string contourRecordCountKey = key("ContourRecordCount");
  const std::string contourNoDataKey = key("ContourNoDataMillionths");
  const std::string sourcePolicyKey = key("TopographySourcePolicySha256");
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
  const uint64_t poiProfileVersion = jsonUintValue(json, poiProfileKey);
  const uint64_t poiIndexProfileVersion =
      jsonUintValue(json, poiIndexProfileKey);
  const uint64_t poiRecordCount = jsonUintValue(json, poiRecordCountKey);
  const uint64_t contoursIncluded = jsonUintValue(json, contoursIncludedKey);
  target.poiProfileVersion = static_cast<uint32_t>(poiProfileVersion);
  target.poiIndexProfileVersion =
      static_cast<uint32_t>(poiIndexProfileVersion);
  target.poiRecordCount = static_cast<uint32_t>(poiRecordCount);
  target.contoursIncluded = contoursIncluded == 1;
  target.poiIndexSha256 = jsonStringValue(json, poiIndexShaKey);
  const uint64_t topographyProfileVersion =
      jsonUintValue(json, topographyProfileKey);
  target.topographyProfileVersion =
      static_cast<uint32_t>(topographyProfileVersion);
  target.topographyQualityMode =
      jsonStringValue(json, topographyQualityKey);
  const uint64_t contourMinorIntervalM =
      jsonUintValue(json, contourMinorIntervalKey);
  target.contourMinorIntervalM =
      static_cast<uint32_t>(contourMinorIntervalM);
  const uint64_t contourIndexIntervalM =
      jsonUintValue(json, contourIndexIntervalKey);
  target.contourIndexIntervalM =
      static_cast<uint32_t>(contourIndexIntervalM);
  const uint64_t contourRecordCount =
      jsonUintValue(json, contourRecordCountKey);
  target.contourRecordCount = static_cast<uint32_t>(contourRecordCount);
  const uint64_t contourNoDataMillionths =
      jsonUintValue(json, contourNoDataKey);
  target.contourNoDataMillionths =
      static_cast<uint32_t>(contourNoDataMillionths);
  target.topographySourcePolicySha256 =
      jsonStringValue(json, sourcePolicyKey);
  const bool metadataPresent =
      hasKey(rendererKey) || hasKey(formatKey) || hasKey(profileKey) ||
      hasKey(languagesKey) || hasKey(fallbackKey) ||
      hasKey(buildingProfileKey) || hasKey(poiProfileKey) ||
      hasKey(poiIndexProfileKey) || hasKey(poiRecordCountKey) ||
      hasKey(contoursIncludedKey) || hasKey(poiIndexShaKey) ||
      hasKey(topographyProfileKey) ||
      hasKey(topographyQualityKey) || hasKey(contourMinorIntervalKey) ||
      hasKey(contourIndexIntervalKey) || hasKey(contourRecordCountKey) ||
      hasKey(contourNoDataKey) || hasKey(sourcePolicyKey);
  if (valid != nullptr) {
    *valid = (!metadataPresent || languagesValid) &&
             formatVersion <= UINT32_MAX &&
             labelProfileVersion <= UINT32_MAX &&
             buildingProfileVersion <= UINT32_MAX &&
             poiProfileVersion <= UINT32_MAX &&
             poiIndexProfileVersion <= UINT32_MAX &&
             poiRecordCount <= UINT32_MAX &&
             contoursIncluded <= 1 &&
             topographyProfileVersion <= UINT32_MAX &&
             contourMinorIntervalM <= UINT32_MAX &&
             contourIndexIntervalM <= UINT32_MAX &&
             contourRecordCount <= UINT32_MAX &&
             contourNoDataMillionths <= UINT32_MAX;
  }
  return target;
}

// Appends ,"<key>": with an unprefixed key's first letter lower-cased. In-place
// appends keep this hot serializer free of string temporaries.
static void appendMetadataKey(std::string &json, const std::string &prefix,
                              const char *name) {
  json += ",\"";
  if (prefix.empty()) {
    json += static_cast<char>(std::tolower(name[0]));
    json += name + 1;
  } else {
    json += prefix;
    json += name;
  }
  json += "\":";
}

static void appendMetadataNumber(std::string &json, const std::string &prefix,
                                 const char *name, uint32_t value) {
  appendMetadataKey(json, prefix, name);
  json += std::to_string(value);
}

static void appendMetadataText(std::string &json, const std::string &prefix,
                               const char *name, const std::string &value) {
  appendMetadataKey(json, prefix, name);
  json += '"';
  json += jsonEscape(value);
  json += '"';
}

static std::string targetMetadataJson(const MapTargetMetadata &target,
                                      const std::string &prefix) {
  if (targetMetadataEmpty(target))
    return "";
  std::string json;
  appendMetadataText(json, prefix, "Renderer", target.renderer);
  appendMetadataNumber(json, prefix, "FormatVersion", target.formatVersion);
  appendMetadataNumber(json, prefix, "LabelProfileVersion",
                       target.labelProfileVersion);
  appendMetadataKey(json, prefix, "LabelLanguages");
  json += '[';
  for (size_t index = 0; index < target.labelLanguages.size(); ++index) {
    if (index != 0)
      json += ',';
    json += '"';
    json += jsonEscape(target.labelLanguages[index]);
    json += '"';
  }
  json += ']';
  appendMetadataText(json, prefix, "InternationalFallback",
                     target.internationalFallback);
  appendMetadataNumber(json, prefix, "BuildingProfileVersion",
                       target.buildingProfileVersion);
  if (target.formatVersion == 5) {
    appendMetadataNumber(json, prefix, "PoiProfileVersion",
                         target.poiProfileVersion);
    appendMetadataNumber(json, prefix, "PoiIndexProfileVersion",
                         target.poiIndexProfileVersion);
    appendMetadataNumber(json, prefix, "PoiRecordCount", target.poiRecordCount);
    appendMetadataNumber(json, prefix, "ContoursIncluded",
                         target.contoursIncluded ? 1 : 0);
    appendMetadataText(json, prefix, "PoiIndexSha256", target.poiIndexSha256);
  }
  if (target.formatVersion == 4 ||
      (target.formatVersion == 5 && target.contoursIncluded)) {
    appendMetadataNumber(json, prefix, "TopographyProfileVersion",
                         target.topographyProfileVersion);
    appendMetadataText(json, prefix, "TopographyQualityMode",
                       target.topographyQualityMode);
    appendMetadataNumber(json, prefix, "ContourMinorIntervalM",
                         target.contourMinorIntervalM);
    appendMetadataNumber(json, prefix, "ContourIndexIntervalM",
                         target.contourIndexIntervalM);
    appendMetadataNumber(json, prefix, "ContourRecordCount",
                         target.contourRecordCount);
    appendMetadataNumber(json, prefix, "ContourNoDataMillionths",
                         target.contourNoDataMillionths);
    appendMetadataText(json, prefix, "TopographySourcePolicySha256",
                       target.topographySourcePolicySha256);
  }
  return json;
}

static void appendJsonString(std::string &body, const char *key, const std::string &value) {
  body += ",\"";
  body += key;
  body += "\":\"";
  body += jsonEscape(value);
  body += '"';
}

// Bound serialization temporaries independently of selection/recovery frames.
static __attribute__((noinline)) std::string streamActivationTransaction(
    const ReadyStreamMap &ready, const MapTargetMetadata &target,
    const ActiveMapSelection &previous, const char *phase, bool retained = false) {
  std::string body = "{\"protocolVersion\":2";
  if (retained) {
    appendJsonString(body, "phase", phase);
    body += ",\"retainedSelection\":1";
  }
  appendJsonString(body, "operationID", ready.operationID);
  appendJsonString(body, "sessionId", ready.sessionId);
  appendJsonString(body, "mapId", ready.mapId);
  appendJsonString(body, "root", ready.root);
  body += targetMetadataJson(target, "");
  appendJsonString(body, "manifestReceipt", ready.manifestReceipt);
  appendJsonString(body, "signedManifestReceipt", ready.signedManifestReceipt);
  appendJsonString(body, "previousMapId", retained ? previous.previousMapId : previous.mapId);
  appendJsonString(body, "previousSessionId", retained ? previous.previousSessionId : previous.sessionId);
  appendJsonString(body, "previousRoot", retained ? previous.previousRoot : previous.root);
  body += targetMetadataJson(retained ? previous.previousTarget : previous.target, "previous");
  appendJsonString(body, "previousManifestReceipt", retained ? previous.previousManifestReceipt : previous.manifestReceipt);
  appendJsonString(body, "previousSignedManifestReceipt", retained ? previous.previousSignedManifestReceipt : previous.signedManifestReceipt);
  if (!retained) appendJsonString(body, "phase", phase);
  body += "}\n";
  return body;
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
  return (!path.empty() && path.front() == '.') ||
         path.find("/.") != std::string::npos;
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
  // Retry of this accepted session retains the first owner failure. A new
  // session or a completed attempt starts a separate diagnostic identity.
  if (state_.sessionId != sessionId || state_.terminalCode[0] != '\0') {
    state_.ownerRecoveryCode.fill(0);
    state_.terminalCode.fill(0);
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

void MapActivationState::finish(std::string status, std::string mapId,
              std::string errorCode, std::string errorMessage) {
  state_.running = false;
  state_.status = std::move(status);
  state_.mapId = std::move(mapId);
  if (state_.status == "installed") {
    state_.step = state_.totalSteps;
    state_.progress = 100;
  }
  state_.errorCode = std::move(errorCode);
  state_.errorMessage = std::move(errorMessage);
  if (state_.status == "failed" || state_.status == "installed") {
    state_.terminalCode.fill(0);
    const auto &code = state_.errorCode.empty() ? state_.status : state_.errorCode;
    std::copy_n(code.data(), std::min(code.size(), state_.terminalCode.size() - 1),
                state_.terminalCode.data());
  }
}

void MapActivationState::rememberOwnerRecovery(const char *code) noexcept {
  if (!code || state_.ownerRecoveryCode[0] != '\0') return;
  for (size_t i = 0; i + 1 < state_.ownerRecoveryCode.size() && code[i]; ++i)
    state_.ownerRecoveryCode[i] = code[i];
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
  if (state_.ownerRecoveryCode[0])
    body += ",\"ownerRecoveryCode\":\"" + jsonEscape(state_.ownerRecoveryCode.data()) + "\"";
  if (state_.terminalCode[0])
    body += ",\"terminalCode\":\"" + jsonEscape(state_.terminalCode.data()) + "\"";
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
  manifest.topographyProfileVersion = static_cast<uint32_t>(
      jsonUintValue(manifestText, "topographyProfileVersion"));
  manifest.poiProfileVersion = static_cast<uint32_t>(
      jsonUintValue(manifestText, "poiProfileVersion"));
  manifest.poiIndexProfileVersion = static_cast<uint32_t>(
      jsonUintValue(manifestText, "poiIndexProfileVersion"));
  bool requestedFeaturesValid = false;
  manifest.requestedFeatures = jsonStringArrayValue(
      manifestText, "requestedFeatures", &requestedFeaturesValid);
  const std::string layers = jsonObjectValue(manifestText, "layers");
  const std::string contourLayer = jsonStringValue(layers, "contours");
  manifest.contoursIncluded = contourLayer == "included";
  const std::string buildingSummary =
      jsonObjectValue(manifestText, "buildings");
  const std::string poiSummary = jsonObjectValue(manifestText, "pois");
  manifest.buildingRecordCount = static_cast<uint32_t>(
      jsonUintValue(buildingSummary, "recordCount"));
  manifest.buildingProvenanceCounts[0] = static_cast<uint32_t>(
      jsonUintValue(buildingSummary, "explicitHeightCount"));
  manifest.buildingProvenanceCounts[1] = static_cast<uint32_t>(
      jsonUintValue(buildingSummary, "levelsHeightCount"));
  manifest.buildingProvenanceCounts[2] = static_cast<uint32_t>(
      jsonUintValue(buildingSummary, "inheritedHeightCount"));
  manifest.buildingProvenanceCounts[3] = static_cast<uint32_t>(
      jsonUintValue(buildingSummary, "localMedianHeightCount"));
  manifest.buildingProvenanceCounts[4] = static_cast<uint32_t>(
      jsonUintValue(buildingSummary, "classDefaultHeightCount"));
  manifest.poiRecordCount = static_cast<uint32_t>(
      jsonUintValue(poiSummary, "recordCount"));
  manifest.poiCategoryCounts[0] = static_cast<uint32_t>(
      jsonUintValue(poiSummary, "shopsCount"));
  manifest.poiCategoryCounts[1] = static_cast<uint32_t>(
      jsonUintValue(poiSummary, "restaurantsAndCafesCount"));
  manifest.poiCategoryCounts[2] = static_cast<uint32_t>(
      jsonUintValue(poiSummary, "publicToiletsCount"));
  manifest.poiCategoryCounts[3] = static_cast<uint32_t>(
      jsonUintValue(poiSummary, "gasStationsCount"));
  manifest.poiCategoryCounts[4] = static_cast<uint32_t>(
      jsonUintValue(poiSummary, "bicycleServicesCount"));
  const size_t topographyPosition = manifestText.find("\"topography\"");
  const std::string topographyText =
      topographyPosition == std::string::npos
          ? std::string()
          : manifestText.substr(topographyPosition);
  manifest.contourRecordCount = static_cast<uint32_t>(
      jsonUintValue(topographyText, "recordCount"));
  manifest.contourPointCount = static_cast<uint32_t>(
      jsonUintValue(topographyText, "pointCount"));
  manifest.contourMinorIntervalM = static_cast<uint32_t>(
      jsonUintValue(topographyText, "minorIntervalM"));
  manifest.contourIndexIntervalM = static_cast<uint32_t>(
      jsonUintValue(topographyText, "indexIntervalM"));
  manifest.contourNoDataMillionths = static_cast<uint32_t>(
      jsonUintValue(topographyText, "noDataMillionths"));
  manifest.contourQualityMode =
      jsonStringValue(topographyText, "qualityMode");
  manifest.topographySourcePolicySha256 =
      jsonStringValue(topographyText, "sourcePolicySha256");
  manifest.topographyIntermediateSha256 =
      jsonStringValue(topographyText, "intermediateSha256");
  manifest.topographyAttributionSha256 =
      jsonStringValue(topographyText, "attributionSha256");
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
#if !MAP_POIS_RUNTIME_ENABLED
  // Disabled firmware must reject target-5 maps instead of accepting a map
  // whose POI companion it cannot present or query.
  if (manifest.formatVersion == 5)
    return fail("manifest_target", "POI target disabled");
#endif

  uint32_t fontAssetCount = 0;
  uint32_t poiIndexCount = 0;
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
    const bool isPoiIndex = file.path ==
        std::string(kVectMapPrefix) + manifest.mapId +
        "/assets/nearby-pois.fpi";
    if (file.path.size() >= 4 &&
        file.path.compare(file.path.size() - 4, 4, ".fme") == 0 &&
        (manifest.formatVersion != 4 || file.bytes != map_terrain::BYTES))
      return fail("manifest_terrain", "terrain requires renderer 4 and a complete grid");
    const bool isBlock = isMapBlockPath(file.path);
    if (!isBlock && !isFontAsset && !isPoiIndex)
      return fail("manifest_path", "manifest contains an unsupported map file");
    if (file.bytes == 0 ||
        file.bytes > (isFontAsset
                          ? map_font_asset_format::kMaximumFontAssetBytes
                          : (isPoiIndex ? map_poi_index::kMaximumBytes
                                        : map_block_format::kMaximumBlockBytes)))
      return fail("manifest_bytes", "map file byte count is invalid");
    if (!isHexSha256(file.sha256))
      return fail("manifest_sha256", "map file sha256 is invalid");
    manifest.files.push_back(file);
    if (isFontAsset)
      fontAssetCount++;
    if (isPoiIndex)
      poiIndexCount++;
    if (file.path.rfind(".fmp") == file.path.size() - 4)
      legacyTextBlockCount++;
  }
  if (manifest.files.empty())
    return fail("manifest_files", "manifest contains no map files");
  if (manifest.renderer != "esp32-fmb" ||
      (manifest.formatVersion != 1 && manifest.formatVersion != 2 &&
       manifest.formatVersion != 3 && manifest.formatVersion != 4 &&
       manifest.formatVersion != 5))
    return fail("manifest_target", "manifest renderer target is unsupported");
  if (manifest.formatVersion == 5) {
    if (!map_nearby_coverage::decodeManifest(
            manifestText, manifest.nearbyCoverageBlocks))
      return fail("manifest_poi_coverage", "invalid coverage");
    for (const ManifestFile &file : manifest.files) {
      if (file.path.size() < 4 ||
          file.path.compare(file.path.size() - 4, 4, ".fmb") != 0)
        continue;
      int32_t x = 0, y = 0;
      if (!map_poi_index::blockFromPath(manifest.mapId, file.path, x, y) ||
          !map_nearby_coverage::contains(
              manifest.nearbyCoverageBlocks, {x, y}))
        return fail("manifest_poi_coverage", "block outside coverage");
    }
  } else if (jsonKeyPosition(manifestText, "nearbyCoverage") != std::string::npos) {
    return fail("manifest_poi_coverage", "coverage needs target 5");
  }
  if (((manifest.formatVersion == 2 || manifest.formatVersion == 3 ||
        manifest.formatVersion == 4 || manifest.formatVersion == 5) &&
       (fontAssetCount != 1 || legacyTextBlockCount != 0)) ||
      (manifest.formatVersion == 1 && fontAssetCount != 0) ||
      ((manifest.formatVersion == 5) != (poiIndexCount == 1)) ||
      poiIndexCount > 1)
    return fail("manifest_target", "manifest files do not match renderer target");
  if (manifest.formatVersion == 2 || manifest.formatVersion == 3 ||
      manifest.formatVersion == 4 || manifest.formatVersion == 5) {
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
  if (manifest.formatVersion >= 3) {
    if (manifest.buildingProfileVersion != 1 ||
        provenanceTotal != manifest.buildingRecordCount)
      return fail("manifest_buildings", "manifest building profile is invalid");
  } else if (manifest.buildingProfileVersion != 0 ||
             manifest.buildingRecordCount != 0 || provenanceTotal != 0) {
    return fail("manifest_buildings", "legacy manifest contains building metadata");
  }
  uint64_t poiTotal = 0;
  for (uint32_t count : manifest.poiCategoryCounts)
    poiTotal += count;
  if (manifest.formatVersion == 5) {
    static constexpr const char *kRequiredPoiSummaryKeys[] = {
        "recordCount", "shopsCount", "restaurantsAndCafesCount",
        "publicToiletsCount", "gasStationsCount", "bicycleServicesCount"};
    bool completePoiSummary = true;
    for (const char *key : kRequiredPoiSummaryKeys) {
      completePoiSummary =
          completePoiSummary &&
          poiSummary.find(std::string("\"") + key + "\"") !=
              std::string::npos;
    }
    const std::vector<std::string> required = {
        "3d-buildings", "map-pois", "street-labels"};
    const std::vector<std::string> combined = {
        "3d-buildings", "contours", "map-pois", "street-labels"};
    if (manifest.poiProfileVersion != 1 ||
        manifest.poiIndexProfileVersion != 1 ||
        !requestedFeaturesValid ||
        (manifest.requestedFeatures != required &&
         manifest.requestedFeatures != combined) ||
        layers.empty() ||
        (contourLayer != "included" && contourLayer != "not-included") ||
        manifest.contoursIncluded !=
            (manifest.requestedFeatures == combined) ||
        poiSummary.empty() || !completePoiSummary ||
        poiTotal != manifest.poiRecordCount)
      return fail("manifest_pois", "manifest POI profile is invalid");
  } else if (manifest.poiProfileVersion != 0 ||
             manifest.poiIndexProfileVersion != 0 ||
             !manifest.requestedFeatures.empty() ||
             manifest.poiRecordCount != 0 || poiTotal != 0 ||
             !poiSummary.empty() || !layers.empty()) {
    return fail("manifest_pois", "legacy POI metadata");
  }
  const bool contourIntervalsValid =
      (manifest.contourMinorIntervalM == 20 &&
       manifest.contourIndexIntervalM == 100) ||
      (manifest.contourMinorIntervalM == 50 &&
       manifest.contourIndexIntervalM == 250);
  if (manifest.formatVersion == 4 ||
      (manifest.formatVersion == 5 && manifest.contoursIncluded)) {
    if (manifest.topographyProfileVersion != 1 ||
        !contourIntervalsValid ||
        (manifest.contourQualityMode != "standard-20m-v1" &&
         manifest.contourQualityMode != "coarse-50m-v1") ||
        manifest.contourNoDataMillionths > 1000000 ||
        !isHexSha256(manifest.topographySourcePolicySha256) ||
        !isHexSha256(manifest.topographyIntermediateSha256) ||
        !isHexSha256(manifest.topographyAttributionSha256))
      return fail("manifest_topography", "manifest topography profile is invalid");
  } else if (manifest.topographyProfileVersion != 0 ||
             !manifest.contourQualityMode.empty() ||
             !topographyText.empty()) {
    return fail("manifest_topography", "unexpected topography metadata");
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
      MapReadFile input(stagedPath);
      if (!input)
        return fail("file_sha256", "could not read staged map file: " +
                                       file.path);
      Sha256Hasher hasher;
      map_renderer_format::StreamValidator rendererValidator(file.path);
      std::array<uint8_t, 4096> buffer = {};
      while (input) {
        input.read(reinterpret_cast<char *>(buffer.data()), buffer.size());
        const size_t count = input.gcount();
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
  MapReadFile input(archivePath);
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
    input.seek(static_cast<off_t>(offset));
    input.read(reinterpret_cast<char *>(signatureBytes),
               sizeof(signatureBytes));
    if (input.gcount() != static_cast<size_t>(sizeof(signatureBytes)))
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
    if (input.gcount() != static_cast<size_t>(sizeof(header))) {
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
    input.read(path.data(), static_cast<size_t>(nameLength));
    if (input.gcount() != static_cast<size_t>(nameLength) ||
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
        (isMapBlockPath(path) ||
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
  MapWriteFile manifestOutput(manifestTemp);
  if (!manifestOutput)
    return fail("archive_write", "could not create extracted manifest");
  input.clear();
  input.seek(static_cast<off_t>(manifestOffset));
  std::array<uint8_t, 4096> buffer = {};
  uint64_t remaining = manifestBytes;
  while (remaining > 0) {
    const size_t count =
        static_cast<size_t>(std::min<uint64_t>(remaining, buffer.size()));
    input.read(reinterpret_cast<char *>(buffer.data()),
               static_cast<size_t>(count));
    if (input.gcount() != static_cast<size_t>(count)) {
      manifestOutput.close();
      removeTree(manifestTemp);
      return fail("archive_truncated", "map archive data is truncated");
    }
    manifestOutput.write(reinterpret_cast<const char *>(buffer.data()),
                         static_cast<size_t>(count));
    if (!manifestOutput) {
      manifestOutput.close();
      removeTree(manifestTemp);
      return fail("archive_write", "could not write extracted manifest");
    }
    remaining -= count;
  }
  manifestOutput.close();
  if (!manifestOutput.good() || !removeTree(manifestPath) ||
      renameStoragePath(manifestTemp.c_str(), manifestPath.c_str()) != 0) {
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
    input.seek(static_cast<off_t>(offset));
    input.read(reinterpret_cast<char *>(signatureBytes),
               sizeof(signatureBytes));
    if (input.gcount() != static_cast<size_t>(sizeof(signatureBytes)))
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
    if (input.gcount() != static_cast<size_t>(sizeof(header)))
      return fail("archive_truncated", "stored archive header is truncated");
    const uint64_t compressedSize = readLe32(header + 14);
    const uint16_t nameLength = readLe16(header + 22);
    const uint16_t extraLength = readLe16(header + 24);
    std::string path(nameLength, '\0');
    input.read(path.data(), static_cast<size_t>(nameLength));
    if (input.gcount() != static_cast<size_t>(nameLength))
      return fail("archive_path", "map archive contains an invalid path");
    const uint64_t dataOffset = offset + 30 + nameLength + extraLength;
    const bool isMapFile = startsWith(path, kVectMapPrefix) &&
                           safeRelativePath(path) &&
                           (isMapBlockPath(path) ||
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
      MapWriteFile output(tempDestination);
      if (!output)
        return fail("archive_write", "could not create extracted map file");
      input.seek(static_cast<off_t>(dataOffset));
      Sha256Hasher hasher;
      map_renderer_format::StreamValidator rendererValidator(path);
      remaining = compressedSize;
      while (remaining > 0) {
        const size_t count =
            static_cast<size_t>(std::min<uint64_t>(remaining, buffer.size()));
        input.read(reinterpret_cast<char *>(buffer.data()),
                   static_cast<size_t>(count));
        if (input.gcount() != static_cast<size_t>(count)) {
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
                     static_cast<size_t>(count));
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
          renameStoragePath(tempDestination.c_str(), destination.c_str()) != 0) {
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
  return readStreamMapMetadata(sessionId, ready, false);
}

InstallStatus MapTransferInstaller::readPreparedOperation(
    const std::string &sessionId, ReadyStreamMap &prepared) const {
  return readStreamMapMetadata(sessionId, prepared, true);
}

InstallStatus MapTransferInstaller::readStreamMapMetadata(
    const std::string &sessionId, ReadyStreamMap &ready, bool prepared,
    std::string *validatedMarker) const {
  ready = ReadyStreamMap();
  if (validatedMarker) validatedMarker->clear();
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
    candidate.operationID = jsonStringValue(marker, "operationID");
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
  std::string value, selectedMarker;
  bool markerFound = false;
  const bool operationReady = prepared || fileExists(joinPath(root, ".operation-ready")) ||
                              fileExists(joinPath(root, ".operation-ready.bak"));
  for (const std::string &path : candidates(joinPath(root, prepared ? ".operation-prepared" : (operationReady ? ".operation-ready" : kStreamReadyFile)))) {
    ReadyStreamMap candidate;
    if (readTextFile(path, value, 2048) && parseMarker(value, candidate) &&
        (!operationReady || (candidate.operationID.size() == 32 &&
          std::all_of(candidate.operationID.begin(), candidate.operationID.end(), [](char c) {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
          })))) {
      ready = std::move(candidate);
      if (validatedMarker) selectedMarker = value;
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
  if (validatedMarker) *validatedMarker = std::move(selectedMarker);
  return {true, "stream_ready", ""};
}

InstallStatus MapTransferInstaller::promotePreparedOperation(
    const std::string &sessionId, const std::string &operationID) const {
  ReadyStreamMap metadata;
  std::string marker;
  auto status = readStreamMapMetadata(sessionId, metadata, true, &marker);
  if (!status.ok) {
    // A prior promotion may have completed before its response was lost.
    status = readStreamMapMetadata(sessionId, metadata, false, &marker);
    if (!status.ok) return status;
  }
  if (metadata.operationID != operationID || operationID.empty() ||
      !acceptedMapOperation(storageRoot_, operationDeviceID_, operationID,
                            sessionId, metadata.manifestReceipt, metadata.signedManifestReceipt))
    return fail("operation_not_accepted", "prepared map has no matching accepted commit");
  const std::string root = joinPath(storageRoot_, metadata.root);
  // Publish the exact envelope that passed semantic and receipt validation.
  // A readable but torn primary must not replace its verified backup here.
  if (!writeTextFileAtomic(joinPath(root, ".operation-ready"), marker))
    return fail("operation_ready_write", "accepted map ready marker needs recovery");
  const std::string pending =
      "{\"manifestReceipt\":\"" + metadata.manifestReceipt + "\",\"mapId\":\"" +
      jsonEscape(metadata.mapId) + "\",\"root\":\"" + metadata.root +
      "\",\"sessionId\":\"" + jsonEscape(sessionId) + "\",\"signedManifestReceipt\":\"" +
      metadata.signedManifestReceipt + "\"}\n";
  if (!writeTextFileAtomic(joinPath(storageRoot_, kPendingStreamActivationFile), pending))
    return fail("operation_pending_write", "accepted map activation intent needs recovery");
  // Identical signed bytes may re-promote a completed library version. Keep
  // that completion evidence before the consumed state is reset, so a failed
  // reactivation restores the version instead of discarding it as staging.
  for (const auto &suffix : {"", ".bak"}) {
    std::string consumed;
    if (fileExists(joinPath(root, kLibraryRetainedFile)) ||
        !readTextFile(joinPath(root, kStreamConsumedFile) + suffix, consumed, 2048) ||
        jsonStringValue(consumed, "sessionId") != sessionId ||
        jsonStringValue(consumed, "mapId") != metadata.mapId ||
        jsonStringValue(consumed, "manifestReceipt") != metadata.manifestReceipt ||
        jsonStringValue(consumed, "signedManifestReceipt") != metadata.signedManifestReceipt)
      continue;
    if (!writeTextFileAtomic(joinPath(root, kLibraryRetainedFile), consumed))
      return fail("operation_library_retain", "completed library version evidence must retry");
  }
  if (!removeTree(joinPath(root,kStreamConsumedFile)) ||
      !removeTree(joinPath(root,kStreamConsumedFile)+".bak") ||
      !removeTree(joinPath(root,kStreamConsumedFile)+".tmp"))
    return fail("operation_consumed_reset","accepted operation consumed-state reset must retry");
  return {true, "operation_accepted", ""};
}

InstallStatus MapTransferInstaller::cancelOperationStaging(
    const std::string &sessionId, const std::string &operationID) const {
  if (!safeId(sessionId)) return fail("operation_identity","invalid cancellation identity");
  MapOperationStorage storage(storageRoot_); operation::Store store(storage,operationDeviceID_);
  if (store.restore()!=operation::Result::Ok) return fail("operation_storage","cancellation ledger unavailable");
  bool cancelled=false;
  for (const auto &record : store.records()) {
    if (record.identity.operation==operationID && record.identity.session==sessionId &&
        record.phase==operation::Phase::Cancelled) cancelled=true;
    if (record.identity.operation!=operationID && record.identity.session==sessionId &&
        (record.phase==operation::Phase::Receiving || record.phase==operation::Phase::Prepared || record.phase==operation::Phase::Accepted))
      return fail("operation_cleanup_conflict","another attempt uses the same content root");
  }
  if (!cancelled) return fail("operation_not_cancelled","cancellation must persist before staging cleanup");
  ReadyStreamMap prepared;
  const auto root=joinPath(storageRoot_,std::string("/VECTMAP/.maps/")+sessionId);
  const bool marker=fileExists(joinPath(root,".operation-prepared")) || fileExists(joinPath(root,".operation-prepared.bak"));
  if (marker && (!readPreparedOperation(sessionId,prepared).ok || prepared.operationID!=operationID))
    return fail("operation_cleanup_conflict","prepared metadata belongs to another attempt");
  ActiveMapSelection active; const auto selected=readActiveMap(active);
  const auto relative=std::string("/VECTMAP/.maps/")+sessionId;
  const bool completedLibraryMap = fileExists(joinPath(root, kStreamConsumedFile)) ||
      fileExists(joinPath(root, kStreamConsumedFile) + ".bak");
  if (completedLibraryMap || (selected.ok && (active.root==relative || active.previousRoot==relative))) {
    // Preparing/retransmitting identical bytes does not own the pre-existing
    // selected or rollback map. Cancel only this attempt's separate envelope.
    if (!marker || (removeTree(joinPath(root,".operation-prepared")) &&
                    removeTree(joinPath(root,".operation-prepared.bak")) &&
                    removeTree(joinPath(root,".operation-prepared.tmp"))))
      return {true,"operation_cancelled_staging",""};
    return fail("operation_cleanup","cancelled envelope cleanup must retry");
  }
  if (!selected.ok && selected.code!="active_missing") return selected;
  return discardUnselectedStreamMap(sessionId);
}

InstallStatus MapTransferInstaller::finalizeOperation(
    const std::string &sessionId, const std::string &operationID) const {
  if (!safeId(sessionId) || operationID.empty()) return fail("operation_identity","invalid terminal operation");
  struct Workspace : ActivationOperationWorkspace {
    ReadyStreamMap ready;
    ActiveMapSelection selected;
    std::array<std::string,3> damagedPaths, damagedBytes;
    using ActivationOperationWorkspace::ActivationOperationWorkspace;
  };
  const auto workspace = makeActivationWorkspace<Workspace>(storageRoot_, operationDeviceID_);
  auto &store = workspace->store;
  if (store.restore()!=operation::Result::Ok) return fail("operation_storage","terminal ledger unavailable");
  const operation::Record *record=nullptr;
  for (const auto &candidate : store.records())
    if (candidate.identity.operation==operationID && candidate.identity.session==sessionId) record=&candidate;
  if (!record || (record->phase!=operation::Phase::Installed && record->phase!=operation::Phase::Failed))
    return fail("operation_not_terminal","renderer result is not persisted");
  auto &ready = workspace->ready;
  auto &selected = workspace->selected;
  if (record->phase==operation::Phase::Installed &&
      (!readReadyStreamMap(sessionId,ready).ok || ready.operationID!=operationID ||
       ready.mapId!=record->identity.map || ready.manifestReceipt!=record->identity.manifest ||
       ready.signedManifestReceipt!=record->identity.signedManifest ||
       !readActiveMap(selected).ok || selected.root!=ready.root || selected.sessionId!=sessionId ||
       selected.mapId!=ready.mapId || selected.manifestReceipt!=ready.manifestReceipt ||
       selected.signedManifestReceipt!=ready.signedManifestReceipt))
    return fail("operation_cleanup_selection","terminal selection does not match persisted receipt");
  const auto transactionPath=joinPath(storageRoot_,kActivationTransactionFile);
  size_t damaged=0;
  for (const auto &path : {transactionPath,transactionPath+".bak",transactionPath+".tmp"}) {
    std::string transaction;
    if (!fileExists(path)) continue;
    if (!readTextFile(path,transaction,kActivationTransactionBytes))
      return fail("operation_cleanup_conflict","activation journal is unreadable");
    const auto owner=jsonStringValue(transaction,"operationID");
    const auto session=jsonStringValue(transaction,"sessionId");
    const auto protocol=jsonUintValue(transaction,"protocolVersion");
    const auto contradicts=[&](const char *key,const std::string &expected) {
      const auto value=jsonStringValue(transaction,key);
      return !value.empty() && value!=expected;
    };
    if ((!owner.empty() && owner!=operationID) || (!session.empty() && session!=sessionId) ||
        (protocol!=0 && protocol!=2) || contradicts("mapId",record->identity.map) ||
        contradicts("manifestReceipt",record->identity.manifest) ||
        contradicts("signedManifestReceipt",record->identity.signedManifest) ||
        contradicts("root",std::string("/VECTMAP/.maps/")+sessionId))
      return fail("operation_cleanup_conflict","another transaction owns recovery evidence");
    if (owner==operationID && session==sessionId && protocol==2 &&
        transaction.find('\0')==std::string::npos) continue;
    workspace->damagedPaths[damaged]=path;
    workspace->damagedBytes[damaged++]=std::move(transaction);
  }
  // Inventory primary, backup and temporary before mutating any. Never infer
  // Installed from a pointer, a damaged journal or a scan of ready roots.
  if (damaged!=0) {
    // Retirement rests on this operation's own verified payload. A legacy
    // archive predecessor has no signed receipt and is not touched here.
    selected.previousRoot.clear();
    if (record->phase!=operation::Phase::Installed ||
        std::any_of(store.records().begin(),store.records().end(),[&](const operation::Record &other) {
          return other.phase==operation::Phase::Accepted && other.identity.operation!=operationID;
        }) || !anchorSelectionVerified(selected))
      return fail("operation_cleanup_conflict","corrupt activation journal requires verified recovery");
    for (size_t index=0;index<damaged;++index)
      if (!quarantineTransaction(workspace->damagedPaths[index],workspace->damagedBytes[index],operationID))
        return fail("operation_cleanup_conflict","activation evidence quarantine must retry");
  }
  if (record->phase==operation::Phase::Installed) {
    const auto root=joinPath(storageRoot_,ready.root);
    if (!markStreamActivationConsumed(ready) || !clearPendingStreamActivation(sessionId) ||
        !removeTree(joinPath(root,kStreamCheckpointFile)) || !removeTree(joinPath(root,kStreamInstallingFile)) ||
        !removeTree(joinPath(root,".operation-prepared")) || !removeTree(joinPath(root,".operation-prepared.bak")) ||
        !removeTree(joinPath(root,kLibraryRetainedFile)))
      return fail("operation_cleanup","confirmed operation cleanup must retry");
  } else {
    std::string transaction;
    auto &selected = workspace->selected;
    const bool retained=readTextFile(transactionPath,transaction,kActivationTransactionBytes) &&
        jsonUintValue(transaction,"retainedSelection")==1 && readActiveMap(selected).ok &&
        selected.sessionId==sessionId && selected.manifestReceipt==record->identity.manifest &&
        selected.signedManifestReceipt==record->identity.signedManifest;
    if (retained) {
      const auto root=joinPath(storageRoot_,selected.root);
      auto &ready = workspace->ready;
      if (!readReadyStreamMap(sessionId,ready).ok || ready.operationID!=operationID ||
          !markStreamActivationConsumed(ready))
        return fail("operation_cleanup","failed retained selection disposition must retry");
      if (!clearPendingStreamActivation(sessionId) || !removeTree(joinPath(root,".operation-prepared")) ||
          !removeTree(joinPath(root,".operation-prepared.bak")) ||
          !removeTree(joinPath(root,kLibraryRetainedFile)))
        return fail("operation_cleanup","retained map cleanup must retry");
    } else {
      const auto discarded=discardUnselectedStreamMap(sessionId);
      if (!discarded.ok) return discarded;
    }
  }
  if (!removeTree(transactionPath+".tmp") || !removeTree(transactionPath+".bak") || !removeTree(transactionPath))
    return fail("operation_cleanup","terminal journal cleanup must retry");
  return {true,"operation_terminal_cleaned",""};
}

bool MapTransferInstaller::quarantineTransaction(const std::string &path,
    const std::string &bytes, const std::string &operationID) const {
  const auto destination=path+".corrupt-"+operationID;
  std::string preserved;
  if (fileExists(destination)) {
    // A previous interrupted recovery may already own this bounded slot.
    return readTextFile(destination,preserved,kActivationTransactionBytes) && preserved==bytes;
  }
  if (fileExists(destination+".bak") &&
      (!readTextFile(destination+".bak",preserved,kActivationTransactionBytes) || preserved!=bytes)) return false;
  const auto directory=joinPath(storageRoot_,"/VECTMAP");
  std::unique_ptr<DIR,DirectoryCloser> entries(::opendir(directory.c_str()));
  if (!entries) return false;
  size_t count=0;
  while (const auto *entry=::readdir(entries.get())) {
    const std::string name=entry->d_name;
    if (name==destination.substr(directory.size()+1)+".tmp" ||
        name==destination.substr(directory.size()+1)+".bak") continue;
    if (startsWith(name,".activation-transaction.json") && name.find(".corrupt-")!=std::string::npos)
      ++count;
  }
  entries.reset();
  // Preserve at most four 4-KiB journals; exhaustion requires explicit archive,
  // never silent deletion or replacement of earlier failure evidence.
  // Copy, sync and verify before retiring the original. A failed readback or
  // interruption must leave a discoverable obligation at its original path.
  if (count>=4 || !writeTextFileAtomic(destination,bytes)) return false;
  return readTextFile(destination,preserved,kActivationTransactionBytes) && preserved==bytes;
}

InstallStatus MapTransferInstaller::recoverTerminalSelection() const {
  struct Workspace { ActiveMapSelection selected; ReadyStreamMap ready; };
  const auto workspace=makeActivationWorkspace<Workspace>();
  auto &selected=workspace->selected;
  auto &ready=workspace->ready;
  const bool ledgerPresent=fileExists(joinPath(storageRoot_,"/VECTMAP/.operations-v1-0")) ||
      fileExists(joinPath(storageRoot_,"/VECTMAP/.operations-v1-1"));
  if (!readActiveMap(selected).ok && !ledgerPresent) {
    // Availability-only recovery of an exact verified predecessor. This never
    // creates an operation receipt or authorizes clearing durable evidence.
    const auto anchor=recoverSelectionAnchor();
    if (!anchor.ok || !readActiveMap(selected).ok)
      return fail("operation_recovery_unresolved","no verified recovery selection");
  }
  if (!readReadyStreamMap(selected.sessionId,ready).ok)
    return fail("operation_recovery_unresolved","ready identity requires reconciliation");
  if (ready.operationID.empty())
    return ledgerPresent ? fail("operation_recovery_unresolved","durable operation evidence requires reconciliation")
                         : InstallStatus{true,"operation_recovery_none",""};
  // finalizeOperation restores and validates the device ledger, including
  // acknowledged tombstones. Accepted/foreign/missing results stay unresolved.
  return finalizeOperation(selected.sessionId,ready.operationID);
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
      ready.signedManifestReceipt + "\",\"operationID\":\"" + ready.operationID + "\"}\n";
  return writeTextFileAtomic(
      joinPath(joinPath(storageRoot_, ready.root), kStreamConsumedFile),
      marker);
}

bool MapTransferInstaller::restoreRetainedLibraryVersion(
    const std::string &sessionId) const {
  if (!safeId(sessionId)) return false;
  const auto root = joinPath(storageRoot_, std::string("/VECTMAP/.maps/") + sessionId);
  std::string retained;
  ReadyStreamMap ready;
  if (!readTextFile(joinPath(root, kLibraryRetainedFile), retained, 2048) ||
      !readReadyStreamMap(sessionId, ready).ok ||
      jsonStringValue(retained, "sessionId") != sessionId ||
      jsonStringValue(retained, "mapId") != ready.mapId ||
      jsonStringValue(retained, "manifestReceipt") != ready.manifestReceipt ||
      jsonStringValue(retained, "signedManifestReceipt") != ready.signedManifestReceipt)
    return false;
  // The identical verified bytes regain completed authority under the current
  // ready marker; the failed attempt itself never becomes an Installed receipt.
  return markStreamActivationConsumed(ready) &&
         removeTree(joinPath(root, ".operation-prepared")) &&
         removeTree(joinPath(root, ".operation-prepared.bak")) &&
         removeTree(joinPath(root, kLibraryRetainedFile));
}

bool MapTransferInstaller::preparationBlocksActivation(const ReadyStreamMap &ready) const {
  const auto root=joinPath(storageRoot_,ready.root);
  if (!fileExists(joinPath(root,".operation-prepared")) &&
      !fileExists(joinPath(root,".operation-prepared.bak"))) return false;
  ReadyStreamMap prepared;
  // A new preparation must not inherit an older legacy or consumed operation's
  // ready authority merely because signed content reuses the same root/session.
  return !readPreparedOperation(ready.sessionId,prepared).ok ||
      ready.operationID.empty() || prepared.operationID!=ready.operationID;
}

InstallStatus MapTransferInstaller::recoverStreamSelection() const {
  if (!hasInterruptedActivation()) {
    ActiveMapSelection canonical;
    if (!readActiveMap(canonical).ok) {
      const auto anchored = recoverSelectionAnchor();
      if (!anchored.ok) return anchored;
    }
  }
  if (hasInterruptedActivation()) {
    InstallStatus recovered = recoverInterruptedActivation();
    if (!recovered.ok)
      return recovered;
  }
  return {true, "ok", ""};
}

InstallStatus MapTransferInstaller::activateReadyStreamMap(
    const std::string &sessionId,
    const ActivationProgressCallback &onProgress,
    ActivationRecoveryCallback onRecovery, void *recoveryContext) const {
  const auto recovered = recoverStreamSelection();
  if (!recovered.ok) return recovered;
  bool needsSelectionRecovery = false;
  const auto selected = selectReadyStreamMap(sessionId, onProgress,
                                            needsSelectionRecovery);
  if (needsSelectionRecovery) {
    if (onRecovery) onRecovery(recoveryContext, selected.code.c_str());
    // A failed canonical write can require a full predecessor rehash. The
    // selection phase must return before recovery reserves its own frame.
    const auto recovery = recoverInterruptedActivation();
    if (!recovery.ok) return recovery;
  }
  return selected;
}

InstallStatus MapTransferInstaller::selectReadyStreamMap(
    const std::string &sessionId,
    const ActivationProgressCallback &onProgress,
    bool &needsSelectionRecovery) const {
  struct Workspace {
    ReadyStreamMap ready;
    MapManifest manifest;
    MapTargetMetadata target;
    ActiveMapSelection previous, selected;
  };
  const auto workspace = makeActivationWorkspace<Workspace>();
  auto &ready = workspace->ready;
  InstallStatus readyStatus = readReadyStreamMap(sessionId, ready);
  if (!readyStatus.ok)
    return readyStatus;
  if (preparationBlocksActivation(ready))
    return fail("operation_prepared_uncommitted","prepared map requires its own explicit commit");
  if (!ready.operationID.empty() &&
      !acceptedMapOperation(storageRoot_, operationDeviceID_, ready.operationID,
                            ready.sessionId, ready.manifestReceipt, ready.signedManifestReceipt))
    return fail("operation_not_accepted", "map operation authorization requires reconciliation");
  auto &readyManifest = workspace->manifest;
  const InstallStatus manifestStatus =
      readInstalledManifest(ready.root, readyManifest);
  if (!manifestStatus.ok)
    return manifestStatus;
  if (readyManifest.mapId!=ready.mapId)
    return fail("stream_manifest_identity","ready metadata map ID does not match signed content");
  // The block cross-check fills the first third of the final step.
  const auto scanProgress = [&onProgress](const ActivationProgress &scan) {
    if (onProgress) onProgress({3, 3, scan.completed, scan.total * 3});
  };
  const InstallStatus labelStatus = validateLabelContracts(
      joinPath(storageRoot_, ready.root), readyManifest, false, scanProgress);
  if (!labelStatus.ok)
    return labelStatus;
  workspace->target = targetMetadata(readyManifest);
  const auto &selectedTarget = workspace->target;
  auto &previous = workspace->previous;
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
    if (!ready.operationID.empty()) {
      const std::string transaction = streamActivationTransaction(ready, selectedTarget, previous, "ready", true);
      if (!writeTextFileAtomic(joinPath(storageRoot_,kActivationTransactionFile),transaction))
        return fail("operation_transaction","could not retain renderer recovery evidence");
      return {true,"operation_selected_pending_renderer",""};
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
    return streamActivationTransaction(ready, selectedTarget, previous, phase);
  };
  if (!writeTextFileAtomic(transactionPath, transaction("ready")))
    return fail("stream_transaction_write",
                "could not start stream activation transaction");
  if (onProgress)
    onProgress({3, 3, 1, 3});
  auto &selected = workspace->selected;
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
    needsSelectionRecovery = true;
    return fail("stream_active_write", "could not select ready map");
  }
  if (onProgress)
    onProgress({3, 3, 2, 3});
  if (!ready.operationID.empty())
    return {true,"operation_selected_pending_renderer",""};
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
    const ActivationProgressCallback &onProgress,
    ActivationRecoveryCallback onRecovery, void *recoveryContext) const {
  const auto recovered = recoverStreamSelection();
  if (!recovered.ok) return recovered;
  std::string sessionId;
  const auto pending = resolvePendingStreamActivation(sessionId);
  if (!pending.ok || sessionId.empty()) return pending;
  return activateReadyStreamMap(sessionId, onProgress, onRecovery, recoveryContext);
}

InstallStatus MapTransferInstaller::settleSelectedStreamMap() const try {
  // An interrupted switch belongs to journal recovery. Operation-backed roots
  // keep their ready state until finalizeOperation persists the receipt.
  if (hasInterruptedActivation()) return {true, "stream_settle_deferred", ""};
  struct Workspace { ActiveMapSelection active; ReadyStreamMap ready; std::string pending; };
  const auto workspace = makeActivationWorkspace<Workspace>();
  auto &active = workspace->active;
  auto &ready = workspace->ready;
  if (!readActiveMap(active).ok || !safeId(active.sessionId) ||
      active.root != std::string("/VECTMAP/.maps/") + active.sessionId ||
      !readReadyStreamMap(active.sessionId, ready).ok || !ready.operationID.empty() ||
      ready.root != active.root || ready.mapId != active.mapId ||
      ready.manifestReceipt != active.manifestReceipt ||
      ready.signedManifestReceipt != active.signedManifestReceipt ||
      preparationBlocksActivation(ready))
    return {true, "stream_settle_none", ""};
  const std::string root = joinPath(storageRoot_, ready.root);
  const bool consumed = fileExists(joinPath(root, kStreamConsumedFile)) ||
                        fileExists(joinPath(root, kStreamConsumedFile) + ".bak");
  auto &pending = workspace->pending;
  const std::string pendingPath = joinPath(storageRoot_, kPendingStreamActivationFile);
  const bool pendingSelected =
      (readTextFile(pendingPath, pending, 2048) || readTextFile(pendingPath + ".bak", pending, 2048)) &&
      jsonStringValue(pending, "sessionId") == ready.sessionId;
  if (consumed && !pendingSelected) return {true, "stream_settle_none", ""};
  // The same cleanup as an activation of the already selected root.
  if ((!consumed && !markStreamActivationConsumed(ready)) ||
      (pendingSelected && !clearPendingStreamActivation(ready.sessionId)) ||
      !removeTree(joinPath(root, kStreamCheckpointFile)) ||
      !removeTree(joinPath(root, kStreamInstallingFile)))
    return fail("stream_settle_cleanup", "selected map cleanup will retry");
  return {true, "stream_installed", ""};
} catch (const std::bad_alloc &) {
  return {false, "out_of_memory", ""};
}

InstallStatus MapTransferInstaller::resolvePendingStreamActivation(
    std::string &sessionId) const {
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
      if (!readReadyStreamMap(name, ready).ok || preparationBlocksActivation(ready))
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
  sessionId = jsonStringValue(pending, "sessionId");
  if (!safeId(sessionId))
    return fail("stream_pending_invalid", "pending stream session is invalid");
  return {true, "ok", ""};
}

InstallStatus MapTransferInstaller::recoverStreamActivationTransaction(
    const std::string &transaction) const {
  struct Workspace {
    ReadyStreamMap ready;
    MapManifest manifest;
    ActiveMapSelection active, selected, rollback;
    std::string sessionId;
    std::string mapId;
    std::string root;
    std::string manifestReceipt;
    std::string signedManifestReceipt;
    std::string previousMapId;
    std::string previousSessionId;
    std::string previousRoot;
    std::string previousManifestReceipt;
    std::string previousSignedManifestReceipt;
    std::string phase;
    std::string transactionPath;
    std::string installedRoot;
    MapTargetMetadata transactionTarget;
    MapTargetMetadata previousTarget;
    MapTargetMetadata installedTarget;
  };
  const auto workspace = makeActivationWorkspace<Workspace>();
  workspace->sessionId = jsonStringValue(transaction, "sessionId");
  const auto &sessionId = workspace->sessionId;
  workspace->mapId = jsonStringValue(transaction, "mapId");
  const auto &mapId = workspace->mapId;
  workspace->root = jsonStringValue(transaction, "root");
  const auto &root = workspace->root;
  bool transactionTargetParsed = false;
  workspace->transactionTarget = targetMetadataFromJson(transaction, "", &transactionTargetParsed);
  const auto &transactionTarget = workspace->transactionTarget;
  workspace->manifestReceipt = jsonStringValue(transaction, "manifestReceipt");
  const auto &manifestReceipt = workspace->manifestReceipt;
  workspace->signedManifestReceipt = jsonStringValue(transaction, "signedManifestReceipt");
  const auto &signedManifestReceipt = workspace->signedManifestReceipt;
  workspace->previousMapId = jsonStringValue(transaction, "previousMapId");
  const auto &previousMapId = workspace->previousMapId;
  workspace->previousSessionId = jsonStringValue(transaction, "previousSessionId");
  const auto &previousSessionId = workspace->previousSessionId;
  workspace->previousRoot = jsonStringValue(transaction, "previousRoot");
  const auto &previousRoot = workspace->previousRoot;
  workspace->previousManifestReceipt = jsonStringValue(transaction, "previousManifestReceipt");
  const auto &previousManifestReceipt = workspace->previousManifestReceipt;
  workspace->previousSignedManifestReceipt = jsonStringValue(transaction, "previousSignedManifestReceipt");
  const auto &previousSignedManifestReceipt = workspace->previousSignedManifestReceipt;
  bool previousTargetParsed = false;
  workspace->previousTarget = targetMetadataFromJson(
      transaction, "previous", &previousTargetParsed);
  const auto &previousTarget = workspace->previousTarget;
  workspace->phase = jsonStringValue(transaction, "phase");
  const auto &phase = workspace->phase;
  workspace->transactionPath = joinPath(storageRoot_, kActivationTransactionFile);
  const auto &transactionPath = workspace->transactionPath;
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
  const auto transactionOperationID=jsonStringValue(transaction,"operationID");
  bool transactionFailed = false;
  if (!transactionOperationID.empty()) {
    const auto operationWorkspace = makeActivationWorkspace<ActivationOperationWorkspace>(
        storageRoot_, operationDeviceID_);
    auto &store = operationWorkspace->store;
    if (store.restore()!=operation::Result::Ok) return fail("operation_storage","operation recovery ledger unavailable");
    for (const auto &record : store.records())
      if (record.identity.operation==transactionOperationID && record.identity.session==sessionId && record.phase==operation::Phase::Failed)
        transactionFailed = true;
  }
  if (transactionFailed) return finalizeOperation(sessionId,transactionOperationID);
  auto &ready = workspace->ready;
  InstallStatus readyStatus = readReadyStreamMap(sessionId, ready);
  if (readyStatus.ok && preparationBlocksActivation(ready))
    return fail("operation_prepared_uncommitted","prepared map requires its own explicit commit");
  if (readyStatus.ok && !ready.operationID.empty() &&
      !acceptedMapOperation(storageRoot_, operationDeviceID_, ready.operationID,
                            ready.sessionId, ready.manifestReceipt, ready.signedManifestReceipt))
    return fail("operation_not_accepted", "map operation authorization requires reconciliation");
  auto &installedManifest = workspace->manifest;
  const InstallStatus installedStatus =
      readyStatus.ok ? readInstalledManifest(root, installedManifest)
                     : InstallStatus{};
  workspace->installedTarget = targetMetadata(installedManifest);
  const auto &installedTarget = workspace->installedTarget;
  if (!readyStatus.ok || !installedStatus.ok || ready.mapId != mapId ||
      ready.root != root || installedManifest.mapId != mapId ||
      ready.manifestReceipt != manifestReceipt ||
      ready.signedManifestReceipt != signedManifestReceipt ||
      (!targetMetadataEmpty(transactionTarget) &&
       !targetMetadataMatches(transactionTarget, installedTarget))) {
    auto &active = workspace->active;
    InstallStatus activeStatus = readActiveMap(active);
    if (!activeStatus.ok &&
        (activeStatus.code == "active_invalid" ||
         (activeStatus.code == "active_missing" && !previousRoot.empty()))) {
      if (previousRoot.empty() ||
          !rollbackRootMatches(previousRoot, previousMapId,
                               previousManifestReceipt,
                               previousSignedManifestReceipt))
        return fail("stream_transaction_recovery",
                    "invalid active pointer and no verified previous map");
      auto &rollback = workspace->rollback;
      rollback.mapId = previousMapId;
      rollback.sessionId = previousSessionId;
      rollback.root = previousRoot;
      rollback.target = previousTarget;
      rollback.manifestReceipt = previousManifestReceipt;
      rollback.signedManifestReceipt = previousSignedManifestReceipt;
      if (!writeActiveMap(rollback))
        return fail("stream_transaction_recovery",
                    "could not restore previous map after invalid ready state");
    }
    if (activeStatus.ok && active.root == root) {
      if (!previousRoot.empty() &&
          rollbackRootMatches(previousRoot, previousMapId,
                              previousManifestReceipt,
                              previousSignedManifestReceipt)) {
        auto &rollback = workspace->rollback;
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
    // A reactivation may have reused completed library bytes. Apply the same
    // protection/retention checks as runtime rollback, including fail-closed
    // handling when the retained completion evidence cannot be verified.
    const bool cleaned = discardUnselectedStreamMap(sessionId).ok &&
                         clearPendingStreamActivation(sessionId) &&
                         removeTree(transactionPath + ".tmp") &&
                         removeTree(transactionPath + ".bak") &&
                         removeTree(transactionPath);
    return cleaned ? InstallStatus{true, "recovered_rollback",
                                   "reconciled invalid ready stream map"}
                   : fail("stream_transaction_cleanup",
                          "could not clean invalid stream transaction");
  }
  auto &selected = workspace->selected;
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
  auto &active = workspace->active;
  InstallStatus activeStatus = readActiveMap(active);
  if (!activeStatus.ok &&
      (activeStatus.code == "active_invalid" ||
       (activeStatus.code == "active_missing" && !previousRoot.empty()))) {
    // A pointer that was accepted by the filesystem but cannot be read back
    // must not strand the previous, verified map. Keep the journal intact if
    // rollback cannot be proved or written, so a later recovery can retry.
    if (previousRoot.empty() ||
        !rollbackRootMatches(previousRoot, previousMapId,
                             previousManifestReceipt,
                             previousSignedManifestReceipt)) {
      return fail("stream_transaction_recovery",
                  "invalid active pointer and no verified previous map");
    }
    auto &rollback = workspace->rollback;
    rollback.mapId = previousMapId;
    rollback.sessionId = previousSessionId;
    rollback.root = previousRoot;
    rollback.target = previousTarget;
    rollback.manifestReceipt = previousManifestReceipt;
    rollback.signedManifestReceipt = previousSignedManifestReceipt;
    if (!writeActiveMap(rollback))
      return fail("stream_transaction_recovery",
                  "could not restore previous map after invalid pointer");
    // A reactivation may have reused completed library bytes. Apply the same
    // protection/retention checks as runtime rollback, including fail-closed
    // handling when the retained completion evidence cannot be verified.
    const bool cleaned = discardUnselectedStreamMap(sessionId).ok &&
                         clearPendingStreamActivation(sessionId) &&
                         removeTree(transactionPath + ".tmp") &&
                         removeTree(transactionPath + ".bak") &&
                         removeTree(transactionPath);
    return cleaned ? InstallStatus{true, "recovered_rollback",
                                   "restored previous map after invalid pointer"}
                   : fail("stream_transaction_cleanup",
                          "restored previous map but could not clean transaction");
  }
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
  if (!ready.operationID.empty()) {
    const auto cleaned=finalizeOperation(sessionId,ready.operationID);
    if (cleaned.ok) return cleaned;
    if (cleaned.code!="operation_not_terminal") return cleaned;
    return {true,"operation_selected_pending_renderer",""};
  }
  workspace->installedRoot = joinPath(storageRoot_, root);
  const auto &installedRoot = workspace->installedRoot;
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

InstallStatus MapTransferInstaller::recoverActiveSelection() const {
  const std::string activePath = joinPath(storageRoot_, kActiveMapFile);
  ActiveMapSelection selected;
  InstallStatus active = readActiveMap(selected);
  if (!active.ok && active.code == "active_missing") {
    const auto anchor = recoverSelectionAnchor();
    if (anchor.code != "selection_anchor_none") return anchor;
  }
  if (!active.ok || activeRootExists(selected.root)) {
    if (active.ok || active.code == "active_missing")
      return {true, "ok", ""};
    if (active.code == "active_invalid") {
      const std::string activeBackup = activePath + ".bak";
      removeTree(activePath);
      if (fileExists(activeBackup) &&
          renameStoragePath(activeBackup.c_str(), activePath.c_str()) == 0) {
        ActiveMapSelection backup;
        InstallStatus backupStatus = readActiveMap(backup);
        if (backupStatus.ok && activeRootExists(backup.root)) {
          removeTree(activePath + ".tmp");
          return {true, "recovered_rollback",
                  "restored valid active map metadata backup"};
        }
        removeTree(activePath);
      }
      const auto anchor = recoverSelectionAnchor();
      if (anchor.code != "selection_anchor_none") return anchor;
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

InstallStatus MapTransferInstaller::recoverInterruptedActivation() const {
  const std::string transactionPath =
      joinPath(storageRoot_, kActivationTransactionFile);
  std::string transaction;
  if (!readTextFile(transactionPath, transaction, kActivationTransactionBytes)) {
    const std::string backupPath = transactionPath + ".bak";
    if (fileExists(transactionPath))
      return fail("transaction_recovery","activation journal is unreadable");
    if (!fileExists(backupPath)) {
      // A temporary alone was never published: activation writes its journal
      // before any other mutation, and the pending intent resumes the work.
      removeTree(transactionPath + ".tmp");
      return recoverActiveSelection();
    }
    // Inspect the backup in place. Never replace unreadable/foreign evidence
    // merely to choose a parser; the actual recovery inventories all variants.
    if (!readTextFile(backupPath, transaction, kActivationTransactionBytes)) {
      return fail("transaction_recovery",
                  "could not recover map activation journal");
    }
  }

  return dispatchActivationRecovery(transaction);
}

InstallStatus MapTransferInstaller::dispatchActivationRecovery(const std::string &transaction) const {
  if (jsonUintValue(transaction, "protocolVersion") == 2) {
    const auto recovered=recoverStreamActivationTransaction(transaction);
    if (recovered.code!="stream_transaction_invalid") return recovered;
    const auto terminal=recoverTerminalSelection();
    return terminal.code=="operation_recovery_none" ? recovered : terminal;
  }

  if (jsonUintValue(transaction,"protocolVersion")>2)
    return fail("transaction_recovery","activation journal requires newer firmware");
  const bool ledger=fileExists(joinPath(storageRoot_,"/VECTMAP/.operations-v1-0")) ||
      fileExists(joinPath(storageRoot_,"/VECTMAP/.operations-v1-1"));
  // Only signed or durable evidence needs an owner. Other unreadable bytes keep
  // the legacy recovery, which verifies or rolls back the selection and clears
  // the journal instead of blocking every later activation. That recovery
  // deletes every journal version, so a damaged primary must not hide
  // evidence that only its backup or temporary still holds.
  if (ledger || journalNeedsOwner(transaction) || journalVersionsNeedOwner()) {
    const auto terminal=recoverTerminalSelection();
    if (terminal.code!="operation_recovery_none") return terminal;
    // A verified predecessor restores availability, not ownership of this
    // unknown journal. Preserve it rather than routing torn v2 bytes to legacy.
    return fail("transaction_recovery","activation journal has no verified recovery authority");
  }

  // Dispatch before reserving any legacy recovery locals on the v2 path.
  return recoverLegacyActivationTransaction(transaction);
}

bool MapTransferInstaller::journalNeedsOwner(const std::string &transaction) const {
  const auto root=jsonStringValue(transaction,"root");
  return jsonUintValue(transaction,"protocolVersion")>=2 ||
      !jsonStringValue(transaction,"manifestReceipt").empty() ||
      !jsonStringValue(transaction,"signedManifestReceipt").empty() ||
      !jsonStringValue(transaction,"operationID").empty() ||
      (safeActiveRoot(root) &&
       (fileExists(joinPath(joinPath(storageRoot_,root),".operation-ready")) ||
        fileExists(joinPath(joinPath(storageRoot_,root),".operation-prepared"))));
}

bool MapTransferInstaller::journalVersionsNeedOwner() const {
  const auto path=joinPath(storageRoot_,kActivationTransactionFile);
  const struct { std::string path; bool published; } versions[]={
      {path,true},{path+".bak",true},{path+".tmp",false}};
  std::string bytes;
  for (const auto &version:versions) {
    if (!fileExists(version.path)) continue;
    // A published version that cannot be read is ambiguous evidence. A
    // temporary was never published and carries no committed state.
    if (!readTextFile(version.path,bytes,kActivationTransactionBytes)) {
      if (version.published) return true;
    } else if (journalNeedsOwner(bytes)) {
      return true;
    }
  }
  return false;
}

InstallStatus MapTransferInstaller::recoverLegacyActivationTransaction(
    const std::string &transaction) const {
  const auto transactionPath = joinPath(storageRoot_, kActivationTransactionFile);
  const auto activePath = joinPath(storageRoot_, kActiveMapFile);

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
    InstallStatus recovered = recoverActiveSelection();
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
  std::string operationTransaction;
  if (readTextFile(joinPath(storageRoot_,kActivationTransactionFile),operationTransaction,kActivationTransactionBytes) &&
      jsonUintValue(operationTransaction,"retainedSelection")==1 &&
      jsonStringValue(operationTransaction,"sessionId")==sessionId &&
      jsonStringValue(operationTransaction,"root")==selected.root &&
      jsonStringValue(operationTransaction,"manifestReceipt")==selected.manifestReceipt &&
      jsonStringValue(operationTransaction,"signedManifestReceipt")==selected.signedManifestReceipt &&
      !jsonStringValue(operationTransaction,"operationID").empty()) {
    // This attempt reused verified bytes of the pre-existing selected map.
    // A failed reload must not delete or deselect that previous usable content.
    return {true,"active_retained","retained selection from before same-content attempt"};
  }
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
      (selected.root == relativeRoot || selected.previousRoot == relativeRoot ||
       selectionAnchorProtectsRoot(relativeRoot))) {
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
      (selected.root == relativeRoot || selected.previousRoot == relativeRoot ||
       selectionAnchorProtectsRoot(relativeRoot))) {
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
  const auto completedRoot = joinPath(storageRoot_, relativeRoot);
  if (fileExists(joinPath(completedRoot, kStreamConsumedFile)) ||
      fileExists(joinPath(completedRoot, kStreamConsumedFile) + ".bak")) {
    return clearPendingStreamActivation(sessionId)
        ? InstallStatus{true, "library_kept", ""}
        : fail("stream_discard_cleanup", "could not clear abandoned activation metadata");
  }
  // A failed same-content reactivation keeps the completed version it reused.
  if (fileExists(joinPath(completedRoot, kLibraryRetainedFile))) {
    if (!restoreRetainedLibraryVersion(sessionId))
      return fail("stream_discard_cleanup", "completed library version restoration must retry");
    return clearPendingStreamActivation(sessionId)
        ? InstallStatus{true, "library_kept", ""}
        : fail("stream_discard_cleanup", "could not clear abandoned activation metadata");
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
          relativeRoot == selected.previousRoot || selectionAnchorProtectsRoot(relativeRoot)) {
        continue;
      }
      const std::string root = joinPath(mapsRoot, sessionId);
      if (fileExists(joinPath(root, kStreamConsumedFile)) ||
          fileExists(joinPath(root, kStreamConsumedFile) + ".bak") ||
          fileExists(joinPath(root, kLibraryRetainedFile))) continue;
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
  if (!readTextFile(activePath, text, kActiveMapBytes))
    return fail("active_missing", "active map metadata is missing");
  return parseActiveMapText(text, selection);
}

InstallStatus MapTransferInstaller::parseActiveMapText(
    const std::string &text, ActiveMapSelection &selection) const {
  selection = ActiveMapSelection();
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

InstallStatus MapTransferInstaller::readActiveMapContentReceipt(
    ActiveMapSelection &selection, std::string &receipt) const {
  receipt.clear();
  const InstallStatus active = readActiveMap(selection);
  if (!active.ok)
    return active;
  if (!selection.manifestReceipt.empty()) {
    receipt = selection.manifestReceipt;
    return {true, "ok", ""};
  }

  if (!safeActiveRoot(selection.root) || !activeRootExists(selection.root))
    return fail("installed_root", "installed map root is missing");
  if (!readTextFile(joinPath(joinPath(storageRoot_, selection.root),
                             kInstalledReceiptFile),
                    receipt, 64) ||
      !isHexSha256(receipt)) {
    receipt.clear();
    return fail("installed_receipt",
                "installed map verification receipt is missing or invalid");
  }
  std::transform(receipt.begin(), receipt.end(), receipt.begin(), ::tolower);
  return {true, "ok", ""};
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
    if (selection.target.formatVersion == 5 &&
        !map_nearby_coverage::decodeManifest(
            manifestText, presentation.nearbyCoverageBlocks))
    return fail("installed_poi_coverage", "invalid installed coverage");
    return {true, "ok", ""};
  }
  MapManifest manifest;
  const InstallStatus status = validateManifestText(manifestText, manifest);
  if (!status.ok)
    return status;
  presentation.displayName = manifest.displayName;
  presentation.boundsE7 = manifest.boundsE7;
  presentation.hasBoundsE7 = manifest.hasBoundsE7;
  presentation.nearbyCoverageBlocks = manifest.nearbyCoverageBlocks;
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

bool InstalledMap::contains(int32_t latitudeE7, int32_t longitudeE7) const {
  const auto &b = presentation.boundsE7;
  return presentation.hasBoundsE7 && longitudeE7 >= b[0] &&
      latitudeE7 >= b[1] && longitudeE7 <= b[2] && latitudeE7 <= b[3];
}

const InstalledMap *coveringLibraryMap(const std::vector<InstalledMap> &maps,
    const std::string &currentRoot, int32_t latitudeE7, int32_t longitudeE7,
    const std::vector<std::string> &rejectedSessions) {
  const InstalledMap *best = nullptr;
  int64_t bestArea = INT64_MAX;
  for (const auto &map : maps) {
    if (!map.contains(latitudeE7, longitudeE7)) continue;
    if (map.root == currentRoot) return nullptr;
    if (std::find(rejectedSessions.begin(), rejectedSessions.end(), map.sessionId) != rejectedSessions.end()) continue;
    const auto &b = map.presentation.boundsE7;
    const int64_t area = (int64_t(b[2]) - b[0]) * (int64_t(b[3]) - b[1]);
    if (area < bestArea || (area == bestArea && best && map.sessionId < best->sessionId)) {
      bestArea = area; best = &map;
    }
  }
  return best;
}

InstallStatus MapTransferInstaller::readInstalledMap(
    const std::string &sessionId, InstalledMap &map, bool requirePayload) const {
  // Reset in place: an aggregate temporary consumes hundreds of stack bytes
  // with libstdc++ even when the metadata workspace itself lives in PSRAM.
  map.sessionId.clear(); map.mapId.clear(); map.root.clear();
  map.manifestReceipt.clear(); map.signedManifestReceipt.clear();
  map.presentation.displayName.clear(); map.presentation.boundsE7.fill(0);
  map.presentation.hasBoundsE7 = false; map.payloadBytes = 0; map.available = true;
  if (!safeId(sessionId)) return fail("library_identity", "invalid map session");
  const auto root = std::string("/VECTMAP/.maps/") + sessionId;
  const auto path = joinPath(storageRoot_, root);
  struct Workspace {
    struct stat entry{}; MapManifest manifest; ReadyStreamMap ready;
    std::string receipt, signedReceipt, marker;
  };
  const auto workspace = makeActivationWorkspace<Workspace>();
  auto &entry = workspace->entry;
#if defined(ARDUINO)
  // ESP-IDF's FAT VFS has no symlinks and does not provide lstat.
  const int inspected = ::stat(path.c_str(), &entry);
#else
  const int inspected = ::lstat(path.c_str(), &entry);
#endif
  if (inspected != 0 || !S_ISDIR(entry.st_mode))
    return fail("library_missing", "installed map is missing");
  // Prepared/uncommitted content must never become selectable through the
  // library, even if it shares a session with a previously consumed stream.
  if (fileExists(joinPath(path, ".operation-prepared")) ||
      fileExists(joinPath(path, ".operation-prepared.bak")))
    return fail("library_uncommitted", "map installation is not complete");
  auto &manifest = workspace->manifest;
  if (!readInstalledManifest(root, manifest).ok)
    return fail("library_manifest", "installed map metadata is invalid");
  const bool stream = fileExists(joinPath(path, kStreamReadyFile)) ||
      fileExists(joinPath(path, ".operation-ready")) ||
      fileExists(joinPath(path, kStreamReadyFile) + ".bak") ||
      fileExists(joinPath(path, ".operation-ready.bak"));
  auto &receipt = workspace->receipt; auto &signedReceipt = workspace->signedReceipt;
  if (stream) {
    auto &ready = workspace->ready;
    if (!readReadyStreamMap(sessionId, ready).ok || ready.mapId != manifest.mapId)
      return fail("library_receipt", "installed stream receipt is invalid");
    bool consumed = false;
    for (const auto &suffix : {"", ".bak"}) {
      auto &marker = workspace->marker; marker.clear();
      if (readTextFile(joinPath(path, kStreamConsumedFile) + suffix, marker, 2048) &&
          jsonStringValue(marker, "sessionId") == sessionId &&
          jsonStringValue(marker, "mapId") == ready.mapId &&
          jsonStringValue(marker, "manifestReceipt") == ready.manifestReceipt &&
          jsonStringValue(marker, "signedManifestReceipt") == ready.signedManifestReceipt &&
          jsonStringValue(marker, "operationID") == ready.operationID) consumed = true;
    }
    if (!consumed) return fail("library_uncommitted", "map has no completed installation");
    receipt = ready.manifestReceipt;
    signedReceipt = ready.signedManifestReceipt;
  } else {
    // Existing verified archive installations migrate in place, without a copy.
    receipt = manifestReceipt(manifest);
    auto &stored = workspace->marker;
    if (!readTextFile(joinPath(path, kInstalledReceiptFile), stored, 64) || stored != receipt)
      return fail("library_receipt", "installed archive receipt is invalid");
  }
  for (const auto &file : manifest.files) {
    uint64_t bytes = 0;
    if (!startsWith(file.publishPath, kVectMapPrefix) ||
        !fileSize(joinPath(path, file.publishPath.substr(std::strlen(kVectMapPrefix))), bytes) ||
        bytes != file.bytes) map.available = false;
    map.payloadBytes += file.bytes;
  }
  map.sessionId = sessionId; map.root = root; map.mapId = manifest.mapId;
  map.manifestReceipt = receipt; map.signedManifestReceipt = signedReceipt;
  map.presentation.displayName = manifest.displayName;
  map.presentation.boundsE7 = manifest.boundsE7;
  map.presentation.hasBoundsE7 = manifest.hasBoundsE7;
  if (requirePayload && !map.available) return fail("library_file", "installed map file is missing or truncated");
  return {true, "library_installed", ""};
}

InstallStatus MapTransferInstaller::readMapLibrary(std::vector<InstalledMap> &maps) const {
  maps.clear();
  const auto root = joinPath(storageRoot_, "/VECTMAP/.maps");
  const std::unique_ptr<DIR, DirectoryCloser> dir(::opendir(root.c_str()));
  if (!dir) return errno == ENOENT ? InstallStatus{true, "ok", ""}
                                 : fail("library_read", "could not read map library");
  while (const auto *entry = ::readdir(dir.get())) {
    InstalledMap map;
    if (safeId(entry->d_name) && readInstalledMap(entry->d_name, map, false).ok) {
      if (maps.size() == kMaximumLibraryMaps) {
        // Keep a bounded, removable page even after external SD changes.
        break;
      }
      maps.push_back(std::move(map));
    }
    if (storageProgressCallback_) storageProgressCallback_(storageProgressContext_);
  }
  std::sort(maps.begin(), maps.end(), [](const InstalledMap &a, const InstalledMap &b) {
    return a.sessionId < b.sessionId;
  });
  return {true, "ok", ""};
}

bool MapTransferInstaller::installedMapCovers(const InstalledMap &map,
    int32_t latitudeE7, int32_t longitudeE7) const {
  return map.available && map.contains(latitudeE7, longitudeE7) && mapRootHasBlock(map.root, latitudeE7, longitudeE7);
}

uint64_t libraryPositionBlockKey(int32_t latitudeE7, int32_t longitudeE7) {
  latitudeE7 = std::max<int32_t>(-850511287, std::min<int32_t>(850511287, latitudeE7));
  longitudeE7 = std::max<int32_t>(-1800000000, std::min<int32_t>(1800000000, longitudeE7));
  constexpr double radius = 6378137.0, radians = 0.017453292519943295;
  const auto x = static_cast<int32_t>((longitudeE7 / 10000000.0) * radians * radius);
  const auto y = static_cast<int32_t>(std::log(std::tan(
      (latitudeE7 / 10000000.0) * radians / 2.0 + 0.7853981633974483)) * radius);
  return (uint64_t(uint32_t(x >> 12)) << 32) | uint32_t(y >> 12);
}

bool MapTransferInstaller::mapRootHasBlock(const std::string &root,
    int32_t latitudeE7, int32_t longitudeE7) const {
  if (!safeActiveRoot(root) || latitudeE7 < -850511287 || latitudeE7 > 850511287 ||
      longitudeE7 < -1800000000 || longitudeE7 > 1800000000) return false;
  // Match the renderer's Web Mercator / 4096-meter block / 16-block folder
  // addressing. Bounds alone overstate coverage for route corridors and holes.
  constexpr double radius = 6378137.0, radians = 0.017453292519943295;
  const auto x = static_cast<int32_t>((longitudeE7 / 10000000.0) * radians * radius);
  const auto y = static_cast<int32_t>(std::log(std::tan(
      (latitudeE7 / 10000000.0) * radians / 2.0 + 0.7853981633974483)) * radius);
  char relative[64]{};
  std::snprintf(relative, sizeof(relative), "/%+04d%+04d/%d_%d",
      int(x >> 16), int(y >> 16), int((x >> 12) & 15), int((y >> 12) & 15));
  const auto base = joinPath(storageRoot_, root) + relative;
  return fileExists(base + ".fmb") || fileExists(base + ".fmp");
}

InstallStatus MapTransferInstaller::selectInstalledMap(
    const std::string &sessionId, const std::string &receipt) const {
  if (hasInterruptedActivation()) return fail("library_busy", "map activation needs recovery");
  struct Workspace { InstalledMap map; ActiveMapSelection previous, next, actual; MapManifest manifest; };
  const auto w = makeActivationWorkspace<Workspace>();
  auto status = readInstalledMap(sessionId, w->map);
  if (!status.ok) return status;
  if (receipt != w->map.manifestReceipt) return fail("library_identity", "map version changed");
  status = readActiveMap(w->previous);
  if (!status.ok && status.code != "active_missing") return status;
  if (w->previous.root == w->map.root) return {true, "selected", ""};
  status = readInstalledManifest(w->map.root, w->manifest);
  if (!status.ok) return status;
  // Size-only upload resume checks are not integrity evidence for reuse.
  for (const auto &file : w->manifest.files) {
    std::string actual;
    const auto path = joinPath(joinPath(storageRoot_, w->map.root),
        file.publishPath.substr(std::strlen(kVectMapPrefix)));
    if (!fileSha256Hex(path, actual) || actual != file.sha256)
      return fail("library_integrity", "installed map checksum does not match");
    if (storageProgressCallback_) storageProgressCallback_(storageProgressContext_);
  }
  status = validateLabelContracts(joinPath(storageRoot_, w->map.root), w->manifest, false);
  if (!status.ok) return status;
  auto &next = w->next;
  next.mapId = w->map.mapId; next.sessionId = sessionId; next.root = w->map.root;
  next.target = targetMetadata(w->manifest);
  if (!w->map.signedManifestReceipt.empty()) {
    next.manifestReceipt = receipt; next.signedManifestReceipt = w->map.signedManifestReceipt;
  }
  if (status.ok && !w->previous.root.empty()) {
    next.previousMapId = w->previous.mapId; next.previousSessionId = w->previous.sessionId;
    next.previousRoot = w->previous.root; next.previousTarget = w->previous.target;
    next.previousManifestReceipt = w->previous.manifestReceipt;
    next.previousSignedManifestReceipt = w->previous.signedManifestReceipt;
  }
  // Reuse the canonical selection's readback, atomic backup and predecessor
  // anchors. There is no file move and no new upload/installation receipt.
  if (writeActiveMap(next)) return {true, "selected", ""};
  // A failed readback is ambiguous: reconcile the canonical pointer before
  // reporting failure, so a completed write cannot strand the old renderer.
  const auto recovered = recoverActiveSelection();
  if (!recovered.ok) return recovered;
  auto &actual = w->actual;
  if (readActiveMap(actual).ok && actual.root == next.root && actual.mapId == next.mapId &&
      actual.manifestReceipt == next.manifestReceipt && actual.signedManifestReceipt == next.signedManifestReceipt)
    return {true, "selected", ""};
  return fail("library_selection", "map selection did not complete");
}

InstallStatus MapTransferInstaller::removeInstalledMap(
    const std::string &sessionId, const std::string &receipt) const {
  if (hasInterruptedActivation()) return fail("library_busy", "map activation needs recovery");
  InstalledMap map; auto status = readInstalledMap(sessionId, map, false);
  if (!status.ok) return status;
  if (receipt != map.manifestReceipt) return fail("library_identity", "map version changed");
  ActiveMapSelection selected; status = readActiveMap(selected);
  if (!status.ok && status.code != "active_missing") return status;
  if (map.root == selected.root || map.root == selected.previousRoot || selectionAnchorProtectsRoot(map.root))
    return fail("library_in_use", "map is selected or retained for recovery");
  const auto source = joinPath(storageRoot_, map.root);
  const auto tombstone = joinPath(storageRoot_, "/VECTMAP/.maps/.removing-" + sessionId);
  if (!removeTree(tombstone) || renameStoragePath(source.c_str(), tombstone.c_str()) != 0)
    return fail("library_remove", "could not stage installed map removal");
  // A power cut during recursive deletion leaves only a recognizable tombstone.
  // Boot/refresh pruning reclaims it, even after the manifest has been deleted.
  removeTree(tombstone);
  return {true, "library_removed", ""};
}

bool MapTransferInstaller::automaticMapSelection() const {
  std::string value;
  const auto path = joinPath(storageRoot_, "/VECTMAP/.library-automatic");
  if (!fileExists(path) && !fileExists(path + ".bak")) return true;
  return (readTextFile(path, value, 8) || readTextFile(path + ".bak", value, 8)) && value == "auto\n";
}

bool MapTransferInstaller::setAutomaticMapSelection(bool enabled) const {
  return mkdirs(joinPath(storageRoot_, "/VECTMAP")) &&
      writeTextFileAtomic(joinPath(storageRoot_, "/VECTMAP/.library-automatic"),
                             enabled ? "auto\n" : "manual\n");
}

bool MapTransferInstaller::writeManualSelectionIntent(const std::string &sessionId,
    const std::string &root, const std::string &receipt) const {
  if (!safeId(sessionId) || !safeActiveRoot(root) || !isHexSha256(receipt)) return false;
  return mkdirs(joinPath(storageRoot_, "/VECTMAP")) &&
      writeTextFileAtomic(joinPath(storageRoot_, kManualSelectionIntentFile),
          "{\"manifestReceipt\":\"" + receipt + "\",\"root\":\"" + root +
          "\",\"sessionId\":\"" + sessionId + "\"}\n");
}

bool MapTransferInstaller::manualSelectionIntentPending() const {
  const auto path = joinPath(storageRoot_, kManualSelectionIntentFile);
  return fileExists(path) || fileExists(path + ".bak");
}

bool MapTransferInstaller::discardManualSelectionIntent() const {
  const auto path = joinPath(storageRoot_, kManualSelectionIntentFile);
  return removeTree(path) && removeTree(path + ".bak") && removeTree(path + ".tmp");
}

InstallStatus MapTransferInstaller::reconcileManualSelectionIntent() const {
  const auto path = joinPath(storageRoot_, kManualSelectionIntentFile);
  if (!manualSelectionIntentPending()) return {true, "library_intent_none", ""};
  std::string intent;
  const bool readable = readTextFile(path, intent, 1024) ||
                        readTextFile(path + ".bak", intent, 1024);
  ActiveMapSelection active;
  const auto status = readActiveMap(active);
  // The canonical pointer is still under recovery: keep the journal so the
  // manual pin is neither lost nor applied to a pointer that may roll back.
  if (!status.ok && status.code != "active_missing") return status;
  // The pointer is the durable outcome of Use. Only the journaled exact target
  // pins manual selection; any other pointer means Use never took effect or
  // was rolled back, so the earlier automatic/manual policy stays unchanged.
  const bool selected = readable && status.ok &&
      active.sessionId == jsonStringValue(intent, "sessionId") &&
      active.root == jsonStringValue(intent, "root") &&
      (active.manifestReceipt.empty() ||
       active.manifestReceipt == jsonStringValue(intent, "manifestReceipt"));
  if (selected && !setAutomaticMapSelection(false))
    return fail("library_policy_write", "manual map selection must persist");
  if (!discardManualSelectionIntent())
    return fail("library_intent_cleanup", "manual selection journal cleanup must retry");
  return {true, selected ? "library_intent_manual" : "library_intent_discarded", ""};
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
                   transaction, kActivationTransactionBytes)) {
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
    if (startsWith(name, ".removing-") && safeId(name.substr(10))) {
      if (!removeTree(joinPath(root, name))) ok = false;
      continue;
    }
    const std::string candidate = std::string("/VECTMAP/.maps/") + name;
    const std::string candidatePath = joinPath(root, name);
    const bool consumed =
        fileExists(joinPath(candidatePath, kStreamConsumedFile)) ||
        fileExists(joinPath(candidatePath, kStreamConsumedFile) + ".bak");
    ReadyStreamMap recoverableReady;
    const bool freshReady =
        !consumed &&
        (fileExists(joinPath(candidatePath, kStreamReadyFile)) ||
         fileExists(joinPath(candidatePath, kStreamReadyFile) + ".bak") ||
         fileExists(joinPath(candidatePath, ".operation-ready")) ||
         fileExists(joinPath(candidatePath, ".operation-ready.bak"))) &&
        readReadyStreamMap(name, recoverableReady).ok;
    if (candidate == selected.root || candidate == selected.previousRoot ||
        candidate == pendingRoot || candidate == transactionRoot ||
        candidate == transactionPreviousRoot || selectionAnchorProtectsRoot(candidate) ||
        freshReady ||
        // Completed maps form the persistent SD library. Cleanup may reclaim
        // abandoned staging, never another city that the rider installed.
        consumed || fileExists(joinPath(candidatePath, kLibraryRetainedFile)) ||
        fileExists(joinPath(candidatePath, kInstalledReceiptFile)) ||
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
  // The original inline /VECTMAP layout is migration evidence, not staging.
  // Preserve it; library installation must never erase an older SD layout.
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

InstallStatus MapTransferInstaller::fail(const char *code,
                                         std::string message) const {
  return {false, code, std::move(message)};
}

InstallStatus MapTransferInstaller::fail(const char *code,
                                         const char *message) const {
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
  for (size_t start = 0; start < path.size();) {
    const size_t slash = path.find('/', start);
    const size_t end = slash == std::string::npos ? path.size() : slash;
    const size_t length = end - start;
    if (length == 0 || (length == 1 && path[start] == '.') ||
        (length == 2 && path[start] == '.' && path[start + 1] == '.'))
      return false;
    start = end + 1;
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
  FileHandle input(from.c_str(), O_RDONLY);
  if (!input) return false;
  FileHandle output(to.c_str(), O_WRONLY | O_CREAT | O_TRUNC);
  if (!output) return false;
  std::array<char, 4096> buffer = {};
  ssize_t count = 0;
  while ((count = descriptor_file::readSome(input.get(), buffer.data(), buffer.size())) > 0) {
    if (!descriptor_file::writeAll(output.get(), buffer.data(), static_cast<size_t>(count))) return false;
  }
  if (count < 0) return false;
  return output.close() == 0;
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
  if (renameStoragePath(from.c_str(), to.c_str()) == 0)
    return true;
  if (!copyTree(from, to))
    return false;
  return removeTree(from);
}

int MapTransferInstaller::renameStoragePath(const char *from, const char *to) const {
  storageMutationBoundary("rename", to, false);
  const int result = ::rename(from, to);
  storageMutationBoundary("rename", to, true);
  return result;
}

bool MapTransferInstaller::removeTree(const std::string &path) const {
  const std::string mapsPrefix = joinPath(storageRoot_, "/VECTMAP/.maps/");
  if (startsWith(path, mapsPrefix) && path.find('/', mapsPrefix.size()) == std::string::npos &&
      selectionAnchorProtectsRoot(path.substr(storageRoot_.size()))) return false;
  struct stat st;
  if (::stat(path.c_str(), &st) != 0)
    return true;
  if (!S_ISDIR(st.st_mode)) {
    storageMutationBoundary("unlink", path, false);
    const bool removed = ::unlink(path.c_str()) == 0;
    storageMutationBoundary("unlink", path, true);
    return removed;
  }
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
  storageMutationBoundary("rmdir", path, false);
  const bool removed = ::rmdir(path.c_str()) == 0;
  storageMutationBoundary("rmdir", path, true);
  return removed;
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

// Receipt fields are newline-terminated. In-place appends avoid one string
// temporary per operator+ without changing the hashed bytes.
static void appendReceiptLine(std::string &value, const char *text) {
  value += text;
  value += '\n';
}

static void appendReceiptLine(std::string &value, const std::string &text) {
  value += text;
  value += '\n';
}

static void appendReceiptNumber(std::string &value, uint64_t number) {
  value += std::to_string(number);
  value += '\n';
}

std::string
MapTransferInstaller::manifestReceipt(const MapManifest &manifest) const {
  std::string value;
  appendReceiptNumber(value, manifest.schemaVersion);
  appendReceiptLine(value, manifest.mapId);
  appendReceiptLine(value, manifest.renderer);
  appendReceiptNumber(value, manifest.formatVersion);
  appendReceiptNumber(value, manifest.labelProfileVersion);
  for (const std::string &language : manifest.labelLanguages)
    appendReceiptLine(value, language);
  appendReceiptLine(value, manifest.internationalFallback);
  appendReceiptNumber(value, manifest.buildingProfileVersion);
  appendReceiptNumber(value, manifest.buildingRecordCount);
  for (uint32_t count : manifest.buildingProvenanceCounts)
    appendReceiptNumber(value, count);
  if (manifest.formatVersion == 5) {
    appendReceiptNumber(value, manifest.poiProfileVersion);
    appendReceiptNumber(value, manifest.poiIndexProfileVersion);
    appendReceiptNumber(value, manifest.poiRecordCount);
    appendReceiptLine(value,
                      manifest.contoursIncluded ? "included" : "not-included");
    for (uint32_t count : manifest.poiCategoryCounts)
      appendReceiptNumber(value, count);
    for (const std::string &feature : manifest.requestedFeatures)
      appendReceiptLine(value, feature);
    for (const auto &block : manifest.nearbyCoverageBlocks) {
      value += std::to_string(block.x);
      value.push_back(',');
      value += std::to_string(block.y);
      value.push_back('\n');
    }
  }
  if (manifest.formatVersion == 4 ||
      (manifest.formatVersion == 5 && manifest.contoursIncluded)) {
    appendReceiptNumber(value, manifest.topographyProfileVersion);
    appendReceiptLine(value, manifest.contourQualityMode);
    appendReceiptNumber(value, manifest.contourRecordCount);
    appendReceiptNumber(value, manifest.contourPointCount);
    appendReceiptNumber(value, manifest.contourMinorIntervalM);
    appendReceiptNumber(value, manifest.contourIndexIntervalM);
    appendReceiptNumber(value, manifest.contourNoDataMillionths);
    appendReceiptLine(value, manifest.topographySourcePolicySha256);
    appendReceiptLine(value, manifest.topographyIntermediateSha256);
    appendReceiptLine(value, manifest.topographyAttributionSha256);
  }
  appendReceiptLine(value, manifest.minimumFirmwareVersion);
  for (const ManifestFile &file : manifest.files) {
    appendReceiptLine(value, file.path);
    appendReceiptLine(value, file.publishPath);
    appendReceiptNumber(value, file.bytes);
    appendReceiptLine(value, file.sha256);
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
    bool useManifestPaths, const ActivationProgressCallback &onProgress) const try {
  if (manifest.formatVersion != 2 && manifest.formatVersion != 3 &&
      manifest.formatVersion != 4 && manifest.formatVersion != 5)
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

  uint64_t buildingRecords = 0;
  std::array<uint64_t, 5> buildingProvenance = {};
#if MAP_POIS_RUNTIME_ENABLED
  uint64_t poiRecords = 0;
  std::array<uint64_t, 5> poiCategories = {};
#endif
  uint64_t contourRecords = 0;
  uint64_t contourPoints = 0;
#if MAP_POIS_RUNTIME_ENABLED
  std::vector<map_poi_index::Entry> expectedPoiIndex;
  const ManifestFile *poiIndexFile = nullptr;
#endif
  // This pass reads every block again, which takes minutes on a large map.
  // Report it, and feed the storage heartbeat that keeps an owner waiting.
  uint64_t blocks = 0, validated = 0, reportedPercent = 0;
  for (const ManifestFile &file : manifest.files)
    if (file.path.size() >= 4 && file.path.compare(file.path.size() - 4, 4, ".fmb") == 0)
      ++blocks;

  for (const ManifestFile &file : manifest.files) {
#if MAP_POIS_RUNTIME_ENABLED
    if (file.path == std::string(kVectMapPrefix) + manifest.mapId +
                         "/assets/nearby-pois.fpi") {
      if (poiIndexFile != nullptr)
        return fail("poi_index_contract", "duplicate POI index");
      poiIndexFile = &file;
    }
#endif
    if (file.path.size() < 4 ||
        file.path.compare(file.path.size() - 4, 4, ".fmb") != 0)
      continue;
    const std::string path = resolvedPath(file);
    if (path.empty())
      return fail("label_block_path", "label-aware block path is invalid");
    uint64_t size = 0;
    if (!fileSize(path, size) || size == 0 ||
        size > map_block_format::kMaximumBlockBytes)
      return fail("label_block_open", "could not read label-aware FMB block");
    FileHandle input(path.c_str(), O_RDONLY);
    if (!input)
      return fail("label_block_open", "could not read label-aware FMB block");
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    const bool readOk = descriptor_file::readExact(input.get(), bytes.data(), bytes.size());
    const uint8_t expectedBlockVersion =
        manifest.formatVersion == 5
            ? 6
            : (manifest.formatVersion == 4
            ? 5
            : (manifest.formatVersion == 3 ? 4 : 3));
    if (!readOk || bytes.size() < 4 || bytes[3] != expectedBlockVersion)
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
    if (manifest.formatVersion >= 3) {
      map_building_block::Block buildings;
      if (!map_building_block::decode(bytes.data(), bytes.size(), buildings,
                                      &error))
        return fail("building_block_contract", "FMB building section is invalid");
      buildingRecords += buildings.stats.records;
      for (size_t index = 0; index < buildingProvenance.size(); ++index)
        buildingProvenance[index] += buildings.stats.provenance[index];
    }
#if MAP_POIS_RUNTIME_ENABLED
    if (manifest.formatVersion == 5) {
      int32_t blockX = 0, blockY = 0;
      if (!map_poi_index::blockFromPath(manifest.mapId, file.path,
                                         blockX, blockY))
        return fail("poi_index_contract", "bad POI block path");
      map_poi_block::Block pois;
      if (!map_poi_block::decode(bytes.data(), bytes.size(), pois, &error))
        return fail("poi_block_contract", "invalid FMB POIs");
      poiRecords += pois.stats.records;
      for (size_t index = 0; index < poiCategories.size(); ++index)
        poiCategories[index] += pois.stats.categories[index];
      if (pois.stats.records != 0) {
        if (expectedPoiIndex.size() >= map_poi_index::kMaximumEntries)
          return fail("poi_index_contract", "index entry limit exceeded");
        map_poi_index::Entry entry;
        entry.blockX = blockX;
        entry.blockY = blockY;
        entry.sectionOffset = pois.stats.sectionOffset;
        entry.sectionBytes = pois.stats.sectionBytes;
        for (size_t category = 0; category < 5; ++category) {
          entry.categoryCounts[category] =
              static_cast<uint16_t>(pois.stats.categories[category]);
          if (entry.categoryCounts[category] != 0)
            entry.categoryMask |= 1U << category;
        }
        expectedPoiIndex.push_back(entry);
      }
    }
#endif
    if (manifest.formatVersion >= 4) {
      map_contour_block::Block contours;
      if (!map_contour_block::decode(bytes.data(), bytes.size(), contours))
        return fail("contour_block_contract", "FMB contour section is invalid");
      if (manifest.formatVersion == 5 && !manifest.contoursIncluded) {
        if (!contours.records.empty() || !contours.points.empty() ||
            contours.minorIntervalM != 20 || contours.indexIntervalM != 100)
          return fail("contour_block_contract", "map without elevation has contours");
      } else if (contours.minorIntervalM != manifest.contourMinorIntervalM ||
                 contours.indexIntervalM != manifest.contourIndexIntervalM) {
        return fail("contour_block_contract", "contour intervals do not match manifest");
      }
      contourRecords += contours.records.size();
      contourPoints += contours.points.size();
    }
    ++validated;
    if (storageProgressCallback_) storageProgressCallback_(storageProgressContext_);
    if (onProgress && validated * 100 / blocks != reportedPercent) {
      reportedPercent = validated * 100 / blocks;
      onProgress({1, 1, validated, blocks});
    }
  }
  if (manifest.formatVersion >= 3) {
    if (buildingRecords != manifest.buildingRecordCount)
      return fail("building_block_contract", "FMB building counts do not match manifest");
    for (size_t index = 0; index < buildingProvenance.size(); ++index)
      if (buildingProvenance[index] != manifest.buildingProvenanceCounts[index])
        return fail("building_block_contract", "FMB building counts do not match manifest");
  }
#if MAP_POIS_RUNTIME_ENABLED
  if (manifest.formatVersion == 5) {
    if (poiRecords != manifest.poiRecordCount)
      return fail("poi_block_contract", "POI counts mismatch");
    for (size_t index = 0; index < poiCategories.size(); ++index)
      if (poiCategories[index] != manifest.poiCategoryCounts[index])
        return fail("poi_block_contract", "POI counts mismatch");
    if (poiIndexFile == nullptr)
      return fail("poi_index_contract", "POI index missing");
    std::sort(expectedPoiIndex.begin(), expectedPoiIndex.end(),
              [](const auto &left, const auto &right) {
                return left.blockX < right.blockX ||
                       (left.blockX == right.blockX &&
                        left.blockY < right.blockY);
              });
    for (size_t index = 1; index < expectedPoiIndex.size(); ++index)
      if (expectedPoiIndex[index].blockX == expectedPoiIndex[index - 1].blockX &&
          expectedPoiIndex[index].blockY == expectedPoiIndex[index - 1].blockY)
        return fail("poi_index_contract", "duplicate POI blocks");
    const std::string indexPath = resolvedPath(*poiIndexFile);
    MapReadFile input(indexPath, true);
    if (!input || input.tell() < static_cast<long>(map_poi_index::kHeaderBytes) ||
        static_cast<uint64_t>(input.tell()) > map_poi_index::kMaximumBytes)
        return fail("poi_index_contract", "POI index unreadable");
    const size_t indexBytes = static_cast<size_t>(input.tell());
    input.seek(0);
    struct CompareContext {
      const std::vector<map_poi_index::Entry> *expected;
      size_t next = 0;
    } context{&expectedPoiIndex, 0};
    auto compare = [](const map_poi_index::Entry &actual,
                      void *opaque) -> bool {
      auto &state = *static_cast<CompareContext *>(opaque);
      if (state.next >= state.expected->size()) return false;
      const auto &expected = (*state.expected)[state.next++];
      return actual.blockX == expected.blockX &&
             actual.blockY == expected.blockY &&
             actual.categoryMask == expected.categoryMask &&
             actual.categoryCounts == expected.categoryCounts &&
             actual.sectionOffset == expected.sectionOffset &&
             actual.sectionBytes == expected.sectionBytes;
    };
    map_poi_index::StreamValidator validator(compare, &context);
    std::array<uint8_t, 4096> chunk{};
    for (size_t remaining = indexBytes; remaining != 0;) {
      const size_t size = std::min(remaining, chunk.size());
      input.read(reinterpret_cast<char *>(chunk.data()), size);
      if (!input || !validator.feed(chunk.data(), size))
        return fail("poi_index_contract", "index does not match blocks");
      remaining -= size;
    }
    if (!validator.finish() || context.next != expectedPoiIndex.size())
      return fail("poi_index_contract", "incomplete or corrupt index");
  }
#endif
  if ((manifest.formatVersion == 4 || manifest.contoursIncluded) &&
      (contourRecords != manifest.contourRecordCount ||
       contourPoints != manifest.contourPointCount))
    return fail("contour_block_contract", "contour counts do not match manifest");
  return {true, "ok", ""};
}
catch (const std::bad_alloc &) {
  return {false, "out_of_memory", ""};
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

bool MapTransferInstaller::anchorSelectionVerified(const ActiveMapSelection &selection) const {
  const auto verified = [&](const std::string &root, const std::string &mapId,
                            const std::string &receipt, const std::string &signedReceipt,
                            const MapTargetMetadata &target) {
    const std::string prefix="/VECTMAP/.maps/";
    if (!startsWith(root,prefix) || !isHexSha256(receipt) || !isHexSha256(signedReceipt)) return false;
    struct Workspace { ReadyStreamMap ready; MapManifest manifest; };
    const auto workspace = makeActivationWorkspace<Workspace>();
    auto &ready = workspace->ready;
    if (!readReadyStreamMap(root.substr(prefix.size()),ready).ok || ready.root!=root ||
        ready.mapId!=mapId || ready.manifestReceipt!=receipt || ready.signedManifestReceipt!=signedReceipt)
      return false;
    auto &manifest = workspace->manifest;
    if (!readInstalledManifest(root,manifest).ok || manifest.mapId!=mapId ||
        (!targetMetadataEmpty(target) && !targetMetadataMatches(target,targetMetadata(manifest)))) return false;
    for (const auto &file : manifest.files) {
      if (!startsWith(file.publishPath,kVectMapPrefix)) return false;
      const auto path=joinPath(joinPath(storageRoot_,root),file.publishPath.substr(std::strlen(kVectMapPrefix)));
      std::string digest; uint64_t bytes=0;
      if (!fileSize(path,bytes) || bytes!=file.bytes || !fileSha256Hex(path,digest) || digest!=file.sha256)
        return false;
    }
    return true;
  };
  return verified(selection.root,selection.mapId,selection.manifestReceipt,
                  selection.signedManifestReceipt,selection.target) &&
      (selection.previousRoot.empty() || verified(selection.previousRoot,selection.previousMapId,
           selection.previousManifestReceipt,selection.previousSignedManifestReceipt,selection.previousTarget));
}

bool MapTransferInstaller::selectionAnchorProtectsRoot(const std::string &root) const {
  for (unsigned slot=0;slot<2;++slot) {
    std::string bytes;
    const auto path=joinPath(storageRoot_,"/VECTMAP/.selection-anchor-"+std::to_string(slot));
    if (!readTextFile(path,bytes,selection_anchor::kMaximumBytes)) {
      if (fileExists(path)) return true; // Oversized/unreadable evidence is not disposable.
      continue;
    }
    selection_anchor::Record record;
    const auto decoded=selection_anchor::decode(bytes,record);
    if (decoded==selection_anchor::Decode::Unsupported) return true; // No destructive downgrade.
    ActiveMapSelection selection;
    if (decoded==selection_anchor::Decode::Valid && parseActiveMapText(record.selection,selection).ok &&
        (selection.root==root || selection.previousRoot==root)) return true;
  }
  return false;
}

bool MapTransferInstaller::persistPredecessorAnchor(const ActiveMapSelection &incoming) const {
  // Same-root refreshes and rollback writes cannot bless a provisional map as
  // a predecessor. Only preserve the canonical predecessor explicitly named
  // by a replacement transaction; never scan ready roots to manufacture one.
  uint64_t highest=0; unsigned newest=1;
  std::string latest;
  for(unsigned slot=0;slot<2;++slot) {
    std::string bytes;
    const auto path=joinPath(storageRoot_,"/VECTMAP/.selection-anchor-"+std::to_string(slot));
    if (!readTextFile(path,bytes,selection_anchor::kMaximumBytes)) {
      if (fileExists(path)) return false;
      continue;
    }
    selection_anchor::Record record;
    const auto decoded=selection_anchor::decode(bytes,record);
    if(decoded==selection_anchor::Decode::Unsupported) return false;
    if(decoded!=selection_anchor::Decode::Valid) continue;
    if(!record.device.empty() && record.device!=operationDeviceID_) return false;
    if(record.sequence==highest && record.selection!=latest) return false;
    if(record.sequence>highest) { highest=record.sequence; newest=slot; latest=record.selection; }
  }
  if (incoming.previousRoot.empty() || incoming.previousRoot==incoming.root) return true;
  struct Workspace { ActiveMapSelection prior; ReadyStreamMap ready; };
  const auto workspace = makeActivationWorkspace<Workspace>();
  auto &prior = workspace->prior;
  if (!readActiveMap(prior).ok || prior.root!=incoming.previousRoot ||
      prior.mapId!=incoming.previousMapId || prior.manifestReceipt!=incoming.previousManifestReceipt ||
      prior.signedManifestReceipt!=incoming.previousSignedManifestReceipt) return true;
  // Unsigned legacy /VECTMAP state is not invented into a verified anchor.
  if (!anchorSelectionVerified(prior)) return true;
  std::string selection;
  if (!readTextFile(joinPath(storageRoot_,kActiveMapFile),selection,kActiveMapBytes)) return false;
  // Anchors keep the size older firmware reads, or a downgrade would fail
  // every activation. A larger predecessor keeps journal and backup recovery.
  if (selection.size()>selection_anchor::kMaximumSelectionBytes) return true;
  if (highest!=0 && latest==selection) return true;
  if (highest==std::numeric_limits<uint64_t>::max()) return false;
  auto &ready = workspace->ready;
  if (!readReadyStreamMap(prior.sessionId,ready).ok) return false;
  selection_anchor::Record record{highest+1,operationDeviceID_,ready.operationID,selection};
  const auto bytes=selection_anchor::encode(record);
  const auto path=joinPath(storageRoot_,"/VECTMAP/.selection-anchor-"+std::to_string(newest^1U));
  // Write only the older/inactive slot. No rename/backup deletion can destroy
  // the other verified record. Readback proves consistency, NOT SD persistence.
  if(bytes.empty() || !writeTextFile(path,bytes)) return false;
  std::string readback;
  selection_anchor::Record decoded;
  return readTextFile(path,readback,selection_anchor::kMaximumBytes) && readback==bytes &&
      selection_anchor::decode(readback,decoded)==selection_anchor::Decode::Valid;
}

InstallStatus MapTransferInstaller::recoverSelectionAnchor() const {
  uint64_t highest=0, observedSequence=0;
  std::string selectedText, observedSelection;
  bool present=false;
  for(unsigned slot=0;slot<2;++slot) {
    const auto path=joinPath(storageRoot_,"/VECTMAP/.selection-anchor-"+std::to_string(slot));
    if(!fileExists(path)) continue;
    present=true;
    std::string bytes;
    if(!readTextFile(path,bytes,selection_anchor::kMaximumBytes))
      return fail("selection_anchor_read","selection anchor is oversized or unreadable");
    selection_anchor::Record record;
    const auto decoded=selection_anchor::decode(bytes,record);
    if(decoded==selection_anchor::Decode::Unsupported)
      return fail("selection_anchor_schema","selection anchor requires newer firmware");
    if(decoded!=selection_anchor::Decode::Valid) continue;
    if(!record.device.empty() && record.device!=operationDeviceID_)
      return fail("selection_anchor_device","selection anchor belongs to another device");
    if(record.sequence==observedSequence && record.selection!=observedSelection)
      return fail("selection_anchor_conflict","same-sequence selection anchors disagree");
    observedSequence=record.sequence; observedSelection=record.selection;
    ActiveMapSelection candidate;
    if(!parseActiveMapText(record.selection,candidate).ok || !anchorSelectionVerified(candidate)) continue;
    ReadyStreamMap ready;
    if(!readReadyStreamMap(candidate.sessionId,ready).ok || ready.operationID!=record.operation) continue;
    if(record.sequence==highest && record.selection!=selectedText)
      return fail("selection_anchor_conflict","same-sequence selection anchors disagree");
    if(record.sequence>highest) { highest=record.sequence; selectedText=record.selection; }
  }
  if(highest==0)
    return present ? fail("selection_anchor_invalid","no exact verified predecessor anchor remains")
                   : InstallStatus{true,"selection_anchor_none",""};
  const auto activePath=joinPath(storageRoot_,kActiveMapFile);
  if(!writeTextFileAtomic(activePath,selectedText))
    return fail("selection_anchor_write","predecessor selection recovery must retry");
  std::string readback;
  if(!readTextFile(activePath,readback,kActiveMapBytes) || readback!=selectedText)
    return fail("selection_anchor_readback","predecessor selection readback must retry");
  // This is availability recovery only. It issues no commit grant, renderer
  // acknowledgement, terminal receipt, or new-operation installed result.
  return {true,"recovered_anchor","restored exact verified predecessor selection"};
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
  // Predecessor validation/rehashing must finish before canonical serialization
  // and readback reserve their frames. The anchor still precedes pointer writes.
  if (!persistPredecessorAnchor(selection)) return false;
  return writeCanonicalActiveMap(selection);
}

bool MapTransferInstaller::writeCanonicalActiveMap(
    const ActiveMapSelection &selection) const {
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
  if (json.size() > kActiveMapBytes ||
      !writeTextFileAtomic(joinPath(storageRoot_, kActiveMapFile), json))
    return false;
  ActiveMapSelection readback;
  const InstallStatus status = readActiveMap(readback);
  return status.ok && readback.mapId == selection.mapId &&
         readback.sessionId == selection.sessionId &&
         readback.root == selection.root &&
         targetMetadataMatches(readback.target, selection.target) &&
         readback.previousMapId == selection.previousMapId &&
         readback.previousSessionId == selection.previousSessionId &&
         readback.previousRoot == selection.previousRoot &&
         targetMetadataMatches(readback.previousTarget,
                               selection.previousTarget) &&
         readback.manifestReceipt == selection.manifestReceipt &&
         readback.signedManifestReceipt == selection.signedManifestReceipt &&
         readback.previousManifestReceipt ==
             selection.previousManifestReceipt &&
         readback.previousSignedManifestReceipt ==
             selection.previousSignedManifestReceipt;
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
  const bool readyMarker = fileExists(joinPath(path, ".operation-ready")) ||
      fileExists(joinPath(path, ".operation-ready.bak")) ||
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
  struct Workspace {
    Sha256Hasher sha;
    std::array<uint8_t, 1024> buffer;
  };
  const auto workspace = makeActivationWorkspace<Workspace>();
  FileHandle input(path.c_str(), O_RDONLY);
  if (!input) return false;
  auto &sha = workspace->sha;
  auto &buffer = workspace->buffer;
  size_t progressBytes = 0;
  ssize_t count = 0;
  while ((count = descriptor_file::readSome(input.get(), buffer.data(), buffer.size())) > 0) {
    sha.update(buffer.data(), count);
    progressBytes += count;
    if (storageProgressCallback_ != nullptr && progressBytes >= 64U * 1024U) {
      storageProgressCallback_(storageProgressContext_);
      progressBytes = 0;
    }
  }
  if (count < 0) return false;
  if (storageProgressCallback_ != nullptr && progressBytes != 0)
    storageProgressCallback_(storageProgressContext_);
  hex = sha.finalHex();
  return true;
}

bool MapTransferInstaller::writeTextFile(const std::string &path,
                                         const std::string &text) const {
  if (!mkdirs(dirnameOf(path)))
    return false;
  storageMutationBoundary("open_truncate", path, false);
  FileHandle output(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC);
  storageMutationBoundary("open_truncate", path, true);
  if (!output) return false;
  storageMutationBoundary("write", path, false);
  const bool written = descriptor_file::writeAll(output.get(), text.data(), text.size());
  storageMutationBoundary("write", path, true);
  storageMutationBoundary("flush", path, false);
  // Raw writes have no userspace buffer; retain the mutation boundary
  // used by recovery fault tests, then require the explicit fsync below.
  const bool flushed = true;
  storageMutationBoundary("flush", path, true);
  if (!written || !flushed) return false;
  storageMutationBoundary("fsync", path, false);
  const bool synced = ::fsync(output.get()) == 0;
  storageMutationBoundary("fsync", path, true);
  if (!synced) return false;
  storageMutationBoundary("close", path, false);
  const bool closed = output.close() == 0;
  storageMutationBoundary("close", path, true);
  // SDK success alone is not enough to publish boot-eligible metadata. Detect
  // silent/partial writes (including a zeroed stdio-sized prefix) while the
  // previous primary/backup is still intact. This is not SD power-loss proof.
  std::string digest;
  return closed && fileSha256Hex(path,digest) &&
      digest==sha256Hex(reinterpret_cast<const uint8_t *>(text.data()),text.size());
}

bool MapTransferInstaller::writeTextFileAtomic(const std::string &path,
                                               const std::string &text) const {
  const std::string temporaryPath = path + ".tmp";
  const std::string backupPath = path + ".bak";
  removeTree(temporaryPath);
  if (!writeTextFile(temporaryPath, text)) {
    // Unpublished bytes never describe committed state; leave none behind.
    removeTree(temporaryPath);
    return false;
  }

  // Keep the old primary until the temporary bytes are synced and verified,
  // then keep its backup until publication is read back. This also works on
  // FAT implementations that cannot replace an existing destination.
  const auto expected=sha256Hex(reinterpret_cast<const uint8_t *>(text.data()),text.size());
  const bool hadPrevious = fileExists(path);
  bool preserveBackup=fileExists(backupPath);
  std::string digest;
  if (hadPrevious && preserveBackup && (!fileSha256Hex(backupPath,digest) || digest!=expected)) {
    // Both survive only after an interrupted publication, whose primary is the
    // newer version. Drop the stale backup; refusing here would fail every
    // later write of this file.
    if (!removeTree(backupPath)) {
      removeTree(temporaryPath);
      return false;
    }
    preserveBackup=false;
  }
  if (hadPrevious && (preserveBackup ? !removeTree(path) :
      renameStoragePath(path.c_str(), backupPath.c_str()) != 0)) {
    removeTree(temporaryPath);
    return false;
  }
  if (renameStoragePath(temporaryPath.c_str(), path.c_str()) != 0) {
    if (hadPrevious && !preserveBackup)
      renameStoragePath(backupPath.c_str(), path.c_str());
    removeTree(temporaryPath);
    return false;
  }
  if (!fileSha256Hex(path,digest) || digest!=expected) {
    // Put back the version this call replaced rather than leaving a corrupt
    // publication beside it. Without one, the file returns to absent.
    if (removeTree(path) && hadPrevious && fileExists(backupPath))
      renameStoragePath(backupPath.c_str(), path.c_str());
    return false;
  }
  return removeTree(backupPath);
}

bool MapTransferInstaller::readTextFile(const std::string &path,
                                        std::string &text,
                                        size_t maxBytes) const {
  uint64_t size = 0;
  if (!fileSize(path, size) || size > maxBytes)
    return false;
  MapReadFile input(path);
  if (!input)
    return false;
  return input.readAll(text, static_cast<size_t>(size));
}

} // namespace map_transfer
