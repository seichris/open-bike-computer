#include "../../lib/bicino_style/bicino_visual_style.hpp"
#include "../../lib/gui/src/preConnectionPresentation.hpp"

#include <cassert>
#include <cstring>
#include <initializer_list>

using pre_connection_presentation::Phase;
using pre_connection_presentation::Snapshot;

int main() {
  static_assert(bicino_visual_style::NAVIGATION_BLUE_RGB888 == 0x0088FF);
  static_assert(bicino_visual_style::NAVIGATION_BLUE_RGB565 == 0x045F);

  static_assert(pre_connection_presentation::resolve({}) == Phase::Welcome);
  static_assert(pre_connection_presentation::resolve(
                    {false, true, false, false, false, 0}) ==
                Phase::Connecting);
  static_assert(pre_connection_presentation::resolve(
                    {false, true, false, true, false, 123456}) ==
                Phase::PairingComparison);
  static_assert(pre_connection_presentation::resolve(
                    {false, true, false, true, true, 123456}) ==
                Phase::PairingConfirmed);
  static_assert(pre_connection_presentation::resolve(
                    {true, false, false, false, false, 0}) ==
                Phase::WaitingForIPhone);
  static_assert(pre_connection_presentation::resolve(
                    {true, true, false, false, false, 0}) ==
                Phase::Connecting);
  static_assert(pre_connection_presentation::resolve(
                    {true, true, true, false, false, 0}) ==
                Phase::GettingLocation);
  static_assert(pre_connection_presentation::resolve(
                    {true, true, true, true, false, 123456}) ==
                Phase::PairingComparison);
  static_assert(pre_connection_presentation::resolve(
                    {true, false, true, false, false, 0}) ==
                Phase::WaitingForIPhone);
  static_assert(pre_connection_presentation::resolve(
                    {false, false, false, true, false, 123456}) ==
                Phase::Welcome);

  struct CodeCase {
    uint32_t code;
    const char *expected;
  };
  for (const CodeCase test : {
           CodeCase{0, "000 000"},
           CodeCase{42, "000 042"},
           CodeCase{123456, "123 456"},
           CodeCase{999999, "999 999"},
       }) {
    char text[8];
    pre_connection_presentation::formatPairingCode(test.code, text);
    assert(std::strcmp(text, test.expected) == 0);
  }
  return 0;
}
