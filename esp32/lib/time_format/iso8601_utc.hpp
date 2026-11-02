#pragma once

#include <cstddef>
#include <cstdio>
#include <ctime>

namespace time_format {

// Writes `utc` as "YYYY-MM-DDTHH:MM:SSZ" (20 characters plus the terminator):
// exactly what strftime(out, capacity, "%Y-%m-%dT%H:%M:%SZ", &utc) wrote at the
// call sites this replaced, for the years 1000 to 9999. snprintf with integer
// conversions is already linked into every image, whereas strftime brought its
// own integer printf engine along (about 14 KB). Returns false and leaves an
// empty string when the result does not fit, like strftime returning 0.
inline bool formatUtcIso8601(char *out, std::size_t capacity, const tm &utc) {
  if (out == nullptr || capacity == 0) {
    return false;
  }
  const int written = std::snprintf(
      out, capacity, "%04d-%02d-%02dT%02d:%02d:%02dZ", utc.tm_year + 1900,
      utc.tm_mon + 1, utc.tm_mday, utc.tm_hour, utc.tm_min, utc.tm_sec);
  if (written < 0 || static_cast<std::size_t>(written) >= capacity) {
    out[0] = '\0';
    return false;
  }
  return true;
}

}  // namespace time_format
