#!/usr/bin/env python3
"""The TCA9554 helper serializes each shadow update with its register write.

The touch controller is reset from the UI task and the GNSS receiver from its
reader task, both through waveshare_board::tca9554 on one shared register
image. This compiles the real helper against a fake bus whose register write
yields in the middle of the transaction, drives two pins from two threads, and
requires the expander's registers to end with both pins' last states. Without
the lock the last write often carries an image that lacks the other pin.
"""

import pathlib
import shutil
import subprocess
import tempfile
import unittest

ESP32 = pathlib.Path(__file__).resolve().parents[2]
HELPER = ESP32 / "lib" / "waveshare_board"

FAKE_I2C = r"""
#pragma once
#include <atomic>
#include <chrono>
#include <cstdint>
#include <thread>
namespace waveshare_board::i2c {
inline std::atomic<uint8_t> outputRegister{0xFF};
inline std::atomic<uint8_t> configRegister{0xFF};
inline bool probe(uint8_t, const char * = nullptr, uint8_t = 2) { return true; }
inline bool writeRegister8(uint8_t, uint8_t reg, uint8_t value,
                           const char * = nullptr, uint8_t = 2) {
  // A bus transaction takes a while; yield so another task can run its own
  // read-modify-write in between.
  std::this_thread::sleep_for(std::chrono::microseconds(20));
  (reg == 0x01 ? outputRegister : configRegister).store(value);
  return true;
}
}  // namespace waveshare_board::i2c
"""

FAKE_BOARD = r"""
#pragma once
#include <cstdint>
namespace waveshare_board {
constexpr uint8_t TCA9554_ADDR = 0x20;
}
"""

HARNESS = r"""
#include <cstdio>
#include <thread>
#include "i2c_bus.hpp"
#include "tca9554.hpp"
using namespace waveshare_board;
int main() {
  constexpr int kRounds = 3000;
  // Both tasks configure their pin and then toggle it, ending on a known
  // level: the touch reset released low-then-high ends high here, the GNSS
  // reset ends low, so the final image is exactly predictable.
  std::thread touch([] {
    tca9554::configureOutput(0);
    for (int i = 0; i < kRounds; ++i) tca9554::setPin(0, i % 2 == 0);
    tca9554::setPin(0, true);
  });
  std::thread gnss([] {
    tca9554::configureOutput(7);
    for (int i = 0; i < kRounds; ++i) tca9554::setPin(7, i % 2 != 0);
    tca9554::setPin(7, false);
  });
  touch.join();
  gnss.join();
  const unsigned output = i2c::outputRegister.load();
  const unsigned config = i2c::configRegister.load();
  if (output != 0x7Fu || config != 0x7Eu) {
    std::printf("expander output 0x%02X config 0x%02X, expected 0x7F 0x7E\n",
                output, config);
    return 1;
  }
  std::puts("tca9554 shadow lock passed");
  return 0;
}
"""


class Tca9554ShadowLockTests(unittest.TestCase):
    def test_concurrent_pin_updates_keep_both_pins(self):
        compiler = shutil.which("c++") or shutil.which("g++")
        self.assertIsNotNone(compiler, "a C++ compiler is required")
        with tempfile.TemporaryDirectory() as temporary:
            work = pathlib.Path(temporary)
            for name in ("tca9554.hpp", "tca9554.cpp"):
                shutil.copyfile(HELPER / name, work / name)
            (work / "i2c_bus.hpp").write_text(FAKE_I2C)
            (work / "waveshare_board.hpp").write_text(FAKE_BOARD)
            (work / "harness.cpp").write_text(HARNESS)
            binary = work / "harness"
            compiled = subprocess.run(
                [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-pthread",
                 "-I", str(work), str(work / "tca9554.cpp"), str(work / "harness.cpp"),
                 "-o", str(binary)],
                capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            for _ in range(5):
                ran = subprocess.run([str(binary)], capture_output=True, text=True)
                self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)


if __name__ == "__main__":
    unittest.main()
