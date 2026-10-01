#include "../../lib/ride_diagnostics/ride_diagnostics_health.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>

int main() {
  using namespace ride_diagnostics;
  char fields[320];
  const Stats stats{4, 3, 1, 0, 0, 4, true, true};
  assert(detail::formatHealthFields(stats, "ready", fields, sizeof(fields)));
  assert(std::strstr(fields, "\"recorderReady\":true"));
  assert(detail::validateFieldsJson(fields, std::strlen(fields)));
  assert(!detail::formatHealthFields(stats, "ready", fields, 8));
  assert(!detail::formatHealthFields(stats, "\"secret\"", fields, sizeof(fields)));
  assert(detail::formatHealthFields(stats, "ready", fields, sizeof(fields)));
  std::printf("{\"schema\":1,\"source\":\"firmware\",\"sequence\":0,"
              "\"level\":\"info\",\"category\":\"logger\",\"event\":\"health\","
              "\"uptimeMs\":1,\"fields\":%s}\n", fields);
}
