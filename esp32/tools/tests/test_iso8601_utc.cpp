#include "../../lib/time_format/iso8601_utc.hpp"
#include <cassert>
#include <cstring>
#include <ctime>
#include <iostream>

// Differential test for the strftime replacement: the formatter must produce
// byte for byte what strftime("%Y-%m-%dT%H:%M:%SZ") produced at the firmware
// call sites it replaced (diagnostics timestamps, RTC logs, GPX waypoints).

namespace {

const char *const kFormat = "%Y-%m-%dT%H:%M:%SZ";

bool matches(time_t moment) {
  struct tm utc = {};
  if (gmtime_r(&moment, &utc) == nullptr) {
    std::cerr << "gmtime_r failed for " << static_cast<long long>(moment) << "\n";
    return false;
  }
  char expected[32] = {};
  char actual[32] = {};
  const size_t expectedLength =
      strftime(expected, sizeof(expected), kFormat, &utc);
  const bool formatted =
      time_format::formatUtcIso8601(actual, sizeof(actual), utc);
  if (expectedLength != 20 || !formatted ||
      std::strcmp(expected, actual) != 0) {
    std::cerr << "mismatch at " << static_cast<long long>(moment)
              << ": strftime='" << expected << "' formatter='" << actual
              << "'\n";
    return false;
  }
  return true;
}

}  // namespace

int main() {
  long long checked = 0;
  // Every 7919 s across the unsigned 32-bit range (1970-01-01 to 2106-02-07):
  // every field value, every month length, leap days and the 2038 roll-over.
  for (long long moment = 0; moment <= 4294967295LL; moment += 7919) {
    assert(matches(static_cast<time_t>(moment)));
    ++checked;
  }
  // Edges: the epoch, 2000-02-29, the signed 32-bit limit and the second after
  // it, 2099-12-31T23:59:59, 9999-12-31T23:59:59, and 1000-01-01, the lowest
  // year the formatter writes like strftime (shorter years are zero-padded by
  // the formatter only).
  for (long long moment : {0LL, 951782400LL, 2147483647LL, 2147483648LL,
                           4102444799LL, 253402300799LL, -30610224000LL}) {
    assert(matches(static_cast<time_t>(moment)));
    ++checked;
  }

  // Capacity: the 20 characters need 21 bytes. A smaller buffer fails the way
  // strftime does (it returns 0) and leaves an empty string behind.
  struct tm utc = {};
  time_t moment = 1700000000;
  gmtime_r(&moment, &utc);
  char exact[21];
  assert(time_format::formatUtcIso8601(exact, sizeof(exact), utc));
  assert(std::strlen(exact) == 20);
  char small[20];
  volatile size_t smallCapacity = sizeof(small);
  assert(!time_format::formatUtcIso8601(small, smallCapacity, utc));
  assert(small[0] == '\0');
  assert(strftime(small, sizeof(small), kFormat, &utc) == 0);
  assert(!time_format::formatUtcIso8601(nullptr, 0, utc));
  assert(!time_format::formatUtcIso8601(exact, 0, utc));

  std::cout << "iso8601 formatter matches strftime for " << checked
            << " timestamps\n";
  return 0;
}
