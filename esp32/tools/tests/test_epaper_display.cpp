#define WAVESHARE_EPAPER_397 1
#include "../../include/board_traits.hpp"
#include "../../lib/epaper_display/epaper_raster.hpp"
#include "../../lib/epaper_display/epaper_policy.hpp"
#include "../../lib/epaper_display/frame_mailbox.hpp"
#include "../../lib/epaper_display/ssd1677.hpp"
#include "../../lib/board_input/button_policy.hpp"
#include "../../lib/ble_navigation/ownership_button_policy.hpp"
#include "../../lib/ble_navigation/device_capabilities_protocol.hpp"
#include "../../lib/gui/src/waitingScreenLayout.hpp"
#include "../../lib/gui/src/preConnectionPresentation.hpp"
#include "../../lib/ble_navigation/screen_configuration.hpp"
#include <cassert>
#include <vector>
#include <iostream>

struct FakeTransport {
  bool waveform = true;
  unsigned resets = 0, completedWaveforms = 0;
  uint8_t command = 0;
  std::vector<uint8_t> black, base;
  bool write(bool data, const uint8_t *bytes, size_t count) {
    if (!data) command = *bytes;
    else if (command == 0x24) black.insert(black.end(), bytes, bytes + count);
    else if (command == 0x26) base.insert(base.end(), bytes, bytes + count);
    return true;
  }
  void reset() { ++resets; }
  void yield() {}
  bool waitReady(uint32_t timeout) { assert(timeout == 10000); return true; }
  bool waitWaveform(uint32_t timeout) {
    assert(timeout == 10000);
    if (waveform) ++completedWaveforms;
    return waveform;
  }
};

int main() {
  using namespace epaper;
  static_assert(board_traits::epaper && !board_traits::touch &&
                !board_traits::brightness && !board_traits::qualifiedPowerControl);
  static_assert(board_traits::width == logicalWidth && board_traits::height == logicalHeight);
  static_assert(board_traits::sda == 41 && board_traits::scl == 42);
  static_assert(board_traits::sdClock == 16 && board_traits::sdCommand == 17 && board_traits::sdData == 15);
  static_assert(board_traits::epdClock == 11 && board_traits::epdMosi == 12 &&
                board_traits::epdCs == 10 && board_traits::epdDc == 9 &&
                board_traits::epdReset == 46 && board_traits::epdBusy == 3);
  static_assert(board_traits::up == 4 && board_traits::center == 5 && board_traits::down == 6);
  assert(std::strstr(pre_connection_presentation::content(
      pre_connection_presentation::Phase::PairingComparison).copy, "center key"));
  static_assert(frameBytes == 48000 && rgbBytes == 768000);
  static_assert(waiting_screen_layout::isValid(
      waiting_screen_layout::makeLayout(480, 800)));
  for (uint16_t y = 0; y < logicalHeight; ++y)
    for (uint16_t x = 0; x < logicalWidth; ++x) {
      const auto native = nativePoint(x, y);
      assert(native.x < width && native.y < height);
      const auto logical = logicalPoint(native.x, native.y);
      assert(logical.x == x && logical.y == y);
    }
  std::vector<uint16_t> rgb(logicalWidth * logicalHeight, 0xFFFF);
  std::vector<uint8_t> packed(frameBytes), shown(frameBytes, 0xFF);
  packPortrait(rgb.data(), packed.data());
  assert(dirtyWindow(packed.data(), shown.data()).empty());
  for (const auto point : {Point{0, 0}, Point{479, 0}, Point{0, 799}, Point{479, 799}})
    rgb[point.y * logicalWidth + point.x] = 0;
  packPortrait(rgb.data(), packed.data());
  assert(packed[0] == 0x7F && packed[stride - 1] == 0xFE);
  assert(packed[(height - 1) * stride] == 0x7F && packed.back() == 0xFE);
  auto window = dirtyWindow(packed.data(), shown.data());
  assert(window.x == 0 && window.y == 0 && window.right == 800 && window.bottom == 480);
  packed = shown;
  packed[100 * stride + 0] = 0xFE;
  packed[101 * stride + 1] = 0x7F;
  window = dirtyWindow(packed.data(), shown.data());
  assert(window.x == 0 && window.right == 16 && window.y == 100 && window.bottom == 102);
  FakeTransport io;
  Ssd1677<FakeTransport> panel(io);
  assert(panel.present(packed.data(), {0, 0, width, height}, true));
  assert(io.black == packed && io.base == packed && io.completedWaveforms == 1);
  io.black.clear(); io.base.clear();
  assert(panel.present(packed.data(), window, false));
  assert((io.black == std::vector<uint8_t>{0xFE, 0xFF, 0xFF, 0x7F}));
  assert(io.base.empty());
  io.waveform = false;
  assert(!panel.present(packed.data(), window, false));
  assert(io.completedWaveforms == 2);
  assert(!panel.present(packed.data(), {1, 0, 9, 1}, false));

  uint8_t a[8]{}, b[8]{}, c[8]{};
  FrameMailbox mailbox;
  mailbox.bind(a, b, c);
  assert(mailbox.beginWrite() == a);
  assert(!mailbox.claim().pixels); // Cannot observe incomplete conversion.
  assert(mailbox.publish(7, 1) == 1);
  const auto first = mailbox.claim();
  assert(first.pixels == a && first.pairing == 7 && first.context == 1);
  assert(mailbox.beginWrite() == b);
  assert(mailbox.publish(8) == 2);
  assert(mailbox.beginWrite() == b); // Latest frame replaces the pending one.
  assert(mailbox.publish(9, 2) == 3);
  assert(!mailbox.claim().pixels); // Only one immutable flight.
  mailbox.finish(true);
  assert(mailbox.shown() == a);
  const auto latest = mailbox.claim();
  assert(latest.pixels == b && latest.generation == 3 && latest.pairing == 9 && latest.context == 2);
  mailbox.finish(false);
  assert(mailbox.shown() == a); // Timeout never advances visible history.

  PresentationPolicy policy;
  assert(policy.fullRequired(0) && policy.ready(0, false));
  policy.start(); assert(!policy.ready(5000, true));
  policy.complete(100, true);
  assert(!policy.ready(349, true) && policy.ready(350, true));
  assert(!policy.ready(1099, false) && policy.ready(1100, false));
  for (unsigned i = 0; i < partialLimit; ++i) {
    assert(!policy.fullRequired(1100 + i * 1000));
    policy.start(); policy.complete(1100 + i * 1000, false);
  }
  assert(policy.fullRequired(22000));
  policy.complete(30000, true);
  assert(policy.fullRequired(90000));
  assert(policy.fail()); assert(!policy.fail() && policy.fault());
  assert(!policy.ready(99999, true));
  policy.wake(); assert(policy.fullRequired(0));
  policy.sleep(); assert(!policy.ready(0, true));

  ownership_button_policy::ComparisonRenderGate gate;
  gate.request(7); gate.request(8);
  gate.displayGenerationCompleted(7); assert(gate.renderedGeneration() == 0);
  gate.displayGenerationCompleted(8); assert(gate.renderedGeneration() == 8);
  gate.cancel(); gate.displayGenerationCompleted(8); assert(gate.renderedGeneration() == 0);

  using board_input::Event;
  board_input::Button button;
  assert(button.sample(true, 1) == Event::None);
  assert(button.sample(true, 1000) == Event::None); // Held through presentation.
  assert(button.sample(false, 1001) == Event::None);
  assert(button.sample(false, 1042) == Event::None);
  assert(button.sample(true, 1050) == Event::None);
  assert(button.sample(true, 1091) == Event::None);
  assert(button.sample(false, 1100) == Event::None);
  assert(button.sample(false, 1141) == Event::Press);
  button.sample(true, 1200); button.sample(true, 1241);
  assert(button.sample(true, 1941) == Event::Hold);
  button.sample(false, 1950);
  assert(button.sample(false, 1991) == Event::None); // A hold is not also a click.

  auto mapProfile = screen_configuration_protocol::defaultMapProfile(
      screen_configuration_protocol::ScreenType::MapNavigation);
  mapProfile.zoomLevel = 3;
  mapProfile.rotationMode = 1;
  mapProfile.birdsEyeEnabled = true;
  mapProfile.buildings3DEnabled = true;
  const auto effective = screen_configuration::effectiveMapProfile(mapProfile);
  assert(effective.rotationMode == 0 && !effective.birdsEyeEnabled &&
         !effective.buildings3DEnabled && effective.zoomLevel == 3);
  assert(mapProfile.rotationMode == 1); // Stored preferences are not mutated.

  using namespace device_capabilities_protocol;
  const uint8_t metadata[] = {1, 2, 1, 0xE0, 1, 0x20, 3, 0};
  const uint8_t power[] = {1, 2, 50};
  uint8_t response[CAP2_MAX_BYTES]{};
  assert(encodeCap2(0, power, true, response, sizeof(response)) == 14);
  assert(encodeCap2(0, power, true, response, sizeof(response), nullptr, 0, metadata) == 24);
  assert(response[14] == 3 && response[15] == 8 && response[19] == 0xE0);
  assert(encodeCap2(0, nullptr, false, response, 18, nullptr, 0, metadata) == 0);
  const uint8_t screens[SCREEN_CONFIGURATION_TLV_BYTES] = {2, 14, 1};
  static_assert(CAP2_MAX_BYTES == 40);
  static_assert(ride_ble_protocol_generated::BOARD_DISPLAY_METADATA_FEATURE == (1UL << 27));
  static_assert(ride_ble_protocol_generated::BOARD_DISPLAY_METADATA_MINIMUM_CLIENT_VERSION == 25);
  assert(encodeCap2(0, power, true, response, sizeof(response), screens, sizeof(screens), metadata) == 40);
  assert(std::memcmp(response + 14, screens, sizeof(screens)) == 0);
  assert(response[30] == 3 && response[31] == 8);
  assert(std::memcmp(response + 32, metadata, sizeof(metadata)) == 0);
  assert(encodeCap2(0, power, true, response, 39, screens, sizeof(screens), metadata) == 0);
  std::cout << "e-paper raster, transport, mailbox, recovery, input and capability tests passed\n";
}
