#include "../../lib/device_debug/renderer_diagnostics_request.hpp"

#include <cassert>
#include <iostream>

int main() {
  using namespace device_debug;
  static_assert(kRendererWindowBodyMaximumBytes == 1024);
  assert(validRendererIdentityText("shanghai-fmb-v4", 48));
  assert(validRendererIdentityText("run:20260812_001", 48));
  assert(!validRendererIdentityText("", 48));
  assert(!validRendererIdentityText("route with spaces", 48));
  assert(!validRendererIdentityText("route/escape", 48));
  assert(!validRendererIdentityText("12345", 4));
  assert(validLowercaseSha256(
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
  assert(!validLowercaseSha256(
      "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"));
  assert(!validLowercaseSha256("abc"));
  assert(validRendererRouteMode("ios-fixture-1hz"));
  assert(validRendererRouteMode("ordinary-ble-1hz"));
  assert(!validRendererRouteMode("fresh-mapkit-route"));
  std::cout << "renderer diagnostics request tests passed\n";
  return 0;
}
