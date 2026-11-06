"""Portable sleep-audit policy, runtime, bus and export-contract tests.

Discovered by the existing root tools/tests firmware-host CI step. Hardware
stubs exercise the actual C++ sources; they are not electrical qualification.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
POWER = ROOT / "esp32/lib/power"


class SleepAuditTests(unittest.TestCase):
    def compile_run(self, source: Path, includes: Path | None = None,
                    defines: tuple[str, ...] = ()) -> str:
        with tempfile.TemporaryDirectory() as build:
            executable = Path(build) / "test"
            command = ["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                       *[f"-D{define}" for define in defines]]
            if includes is not None:
                command += ["-I", str(includes)]
            compiled = subprocess.run([*command, str(source), "-o", str(executable)],
                                      capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            return subprocess.run([str(executable)], check=True,
                                  capture_output=True, text=True).stdout

    def test_portable_policy(self):
        self.assertIn("passed", self.compile_run(
            ROOT / "esp32/tools/tests/test_sleep_audit.cpp"))

    def test_shutdown_barrier_fault_sequences(self):
        self.assertIn("passed", self.compile_run(
            ROOT / "esp32/tools/tests/test_shutdown_barrier.cpp"))

    def test_passive_bus_read_both_boards(self):
        source = (ROOT / "esp32/lib/waveshare_board/i2c_bus.cpp").read_text()
        start = source.index("bool readRegisterBlock8Once(")
        end = source.index("bool readRegister16(", start)
        function = source[start:end]
        # The real board file supplies board::i2c::stopBetweenWriteAndRead.
        prefix = f'#include "{ROOT}/esp32/lib/board/board.hpp"\n' + r'''
#include <cassert>
#include <cstdint>
#include <cstring>
namespace power_management {
enum class LockDomain { I2c };
struct ScopedLock { explicit ScopedLock(LockDomain) {} };
}
bool busConfigured = true, canLock = true;
struct BusLock { bool ok() { return canLock; } };
void delay(int) {}
struct WireMock {
  int calls = 0, count = 3, offset = 0, failAt = -1;
  bool nack = false, stop = true;
  void beginTransmission(uint8_t) { ++calls; }
  void write(uint8_t) { ++calls; }
  int endTransmission(bool stopBit = true) { stop = stopBit; return nack ? 1 : 0; }
  int requestFrom(uint8_t, uint8_t, uint8_t) { return count; }
  int read() { return offset++ == failAt ? -1 : offset; }
} Wire;
'''
        suffix = r'''
int main() {
  uint8_t data[3] = {9,9,9};
  assert(!readRegisterBlock8Once(0x34, 0, nullptr, 3));
  assert(!readRegisterBlock8Once(0x34, 0, data, 0));
  assert(!readRegisterBlock8Once(0x34, 0, data, 17));
  assert(!readRegisterBlock8Once(0x34, 255, data, 3));
  busConfigured = false;
  assert(!readRegisterBlock8Once(0x34, 0, data, 3));
  busConfigured = true; canLock = false;
  assert(!readRegisterBlock8Once(0x34, 0, data, 3));
  assert(Wire.calls == 0);
  canLock = true; Wire.nack = true;
  assert(!readRegisterBlock8Once(0x34, 0, data, 3));
  assert(Wire.calls == 2 && data[0] == 9);
  Wire = {}; Wire.count = 2;
  assert(!readRegisterBlock8Once(0x34, 0, data, 3));
  assert(data[0] == 9 && data[1] == 9 && data[2] == 9);
  Wire = {}; Wire.failAt = 1;
  assert(!readRegisterBlock8Once(0x34, 0, data, 3));
  assert(data[0] == 9 && data[1] == 9 && data[2] == 9);
  Wire = {};
  assert(readRegisterBlock8Once(0x34, 0, data, 3));
  assert(data[0] == 1 && data[1] == 2 && data[2] == 3);
#ifdef WAVESHARE_AMOLED_175
  assert(Wire.stop);
#else
  assert(!Wire.stop);
#endif
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bus.cpp"
            path.write_text(prefix + function + suffix)
            for board in ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"):
                with self.subTest(board=board):
                    self.compile_run(path, defines=(board,))

    def test_transactions_reinitialize_an_unconfigured_bus_without_deadlock(self):
        # The pinned TwoWire frees its buffers when begin() fails and
        # endTransmission() then returns before releasing the bus mutex, so a
        # transaction on a bus whose driver install failed leaves the mutex
        # taken and the next begin()/end() waits forever. The helpers must
        # reinstall the driver before any transaction and keep retries bounded.
        source = (ROOT / "esp32/lib/waveshare_board/i2c_bus.cpp").read_text()
        def function(signature):
            start = source.index(signature)
            return source[start:source.index("\n}\n", start) + 3]
        production = "".join(function(signature) for signature in (
            "void beginBus() {",
            "[[maybe_unused]] void recoverAfterFailure() {",
            "bool ensureBusConfigured() {",
            "template <typename Fn>\nbool withRetries(",
            "void configureBus(uint32_t clockHz) {",
            "bool probe(uint8_t address, const char *label, uint8_t attempts) {",
        ))
        harness = (f'#include "{ROOT}/esp32/lib/board/board.hpp"\n'
                   f'#include "{ROOT}/esp32/lib/waveshare_board/i2c_transaction_trace.hpp"\n') + r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
using waveshare_board::i2c::TransactionPhase;
using waveshare_board::i2c::TransactionTrace;
namespace power_management {
enum class LockDomain { I2c };
struct ScopedLock { explicit ScopedLock(LockDomain) {} };
}
namespace waveshare_board { int recoveries = 0; void recoverI2CBus() { ++recoveries; } }
#define I2C_SDA_PIN 15
#define I2C_SCL_PIN 14
constexpr uint16_t DEFAULT_TIMEOUT_MS = 50;
struct { uint32_t recoveryAttempts = 0, failedTransactions = 0, recoveredTransactions = 0, missingDevices = 0; } i2cStats;
bool busConfigured = false;
uint32_t activeClockHz = 0;
void ensureMutex() {}
struct BusLock { bool ok() { return true; } };
uint32_t millis() { return 0; }
uint32_t retryStartTime() { return 0; }
void delay(int) {}
void logRetryResult(uint8_t, uint16_t, const char *, uint8_t, bool, uint32_t) {}
void logFailure(const char *, const char *, uint8_t) {}
struct SerialMock { template <typename... A> int printf(const char *, A...) { return 0; } } Serial;
// Models the pinned TwoWire: begin() creates and takes a non-recursive mutex and
// frees the buffers on failure; beginTransmission() takes the mutex;
// endTransmission() returns 4 on a missing buffer without releasing it. A take
// while the mutex is held is the deadlock the production code must avoid.
struct WireMock {
  bool lockCreated = false, taken = false, hasBuffer = false, ack = true;
  int failNextBegins = 0, begins = 0, ends = 0, transactions = 0, deadlocks = 0, clocks = 0, timeouts = 0;
  bool begin(int, int) {
    lockCreated = true;
    if (taken) { ++deadlocks; return false; }
    taken = true;
    ++begins;
    const bool ok = failNextBegins == 0;
    if (!ok) --failNextBegins;
    hasBuffer = ok;
    taken = false;
    return ok;
  }
  bool end() {
    if (lockCreated) {
      if (taken) { ++deadlocks; return false; }
      taken = true; hasBuffer = false; taken = false;
    }
    ++ends;
    return true;
  }
  void beginTransmission(uint8_t) {
    ++transactions;
    if (!lockCreated) return;
    if (taken) { ++deadlocks; return; }
    taken = true;
  }
  int endTransmission(bool stop = true) {
    if (!hasBuffer) return 4;  // the mutex stays taken
    if (stop) { taken = false; return ack ? 0 : 2; }
    return 0;
  }
  void setClock(uint32_t) { ++clocks; }
  void setTimeOut(uint16_t) { ++timeouts; }
} Wire;
''' + production + r'''
void reset() { Wire = {}; i2cStats = {}; busConfigured = false; waveshare_board::recoveries = 0; }
int main() {
  constexpr bool recovers = board::i2c::recoverOnFailure;
  // The mock reproduces the hazard: a bufferless transaction leaves the
  // mutex taken and the next begin() deadlocks.
  Wire.lockCreated = true;
  Wire.beginTransmission(0x34);
  assert(Wire.endTransmission() == 4 && Wire.taken);
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  assert(Wire.deadlocks == 1);
  // First driver install fails, the retry during the probe succeeds: the probe
  // reinstalls the driver before its first transaction and succeeds.
  reset();
  Wire.failNextBegins = 1;
  configureBus(100000);
  assert(!busConfigured && Wire.begins == 1 && Wire.transactions == 0 && Wire.clocks == 0);
  assert(probe(0x34, "AXP2101", 3));
  assert(Wire.deadlocks == 0 && busConfigured && Wire.transactions == 1);
  assert(Wire.begins == 2 && Wire.ends == 0 && Wire.clocks == 1 && Wire.timeouts == 1);
  assert(i2cStats.failedTransactions == 0 && i2cStats.missingDevices == 0);
  assert(waveshare_board::recoveries == (recovers ? 1 : 0));
  assert(i2cStats.recoveryAttempts == (recovers ? 1u : 0u));
  // The driver install keeps failing: no transaction is ever issued, the
  // retries stay bounded and the device counts as missing.
  reset();
  Wire.failNextBegins = 100;
  configureBus(100000);
  assert(!probe(0x34, "AXP2101", 3));
  assert(Wire.deadlocks == 0 && Wire.transactions == 0 && !busConfigured);
  assert(Wire.begins == 4 && Wire.ends == 0);
  assert(i2cStats.failedTransactions == 3 && i2cStats.missingDevices == 1);
  assert(i2cStats.recoveryAttempts == (recovers ? 3u : 0u));
  // A live bus with a silent device: every attempt is a real transaction and
  // only a recovering board ends and reinstalls the driver in between.
  reset();
  configureBus(100000);
  Wire.ack = false;
  assert(!probe(0x34, "AXP2101", 2));
  assert(Wire.deadlocks == 0 && Wire.transactions == 2 && busConfigured);
  assert(i2cStats.failedTransactions == 2 && i2cStats.missingDevices == 1);
  assert(Wire.ends == (recovers ? 2 : 0) && Wire.begins == (recovers ? 3 : 1));
  assert(waveshare_board::recoveries == (recovers ? 2 : 0));
  puts("passed");
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bus_init.cpp"
            path.write_text(harness)
            for board in ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"):
                with self.subTest(board=board):
                    self.assertIn("passed", self.compile_run(path, defines=(board,)))

    def test_runtime_and_export(self):
        stubs = {
            "Arduino.h": "#pragma once\n#include <cstdint>\n#include <cstdio>\ninline uint32_t millis() { return 2000; }\n",
            "esp_attr.h": "#define RTC_NOINIT_ATTR\n",
            "esp_system.h": "#pragma once\n#include <cstdint>\ninline uint32_t esp_random() { static uint32_t n=100; return ++n; }\n",
            "esp_sleep.h": "#pragma once\n#include <cstdint>\nconstexpr int ESP_SLEEP_WAKEUP_EXT1=3;\ninline int esp_sleep_get_wakeup_cause() {return 3;}\ninline uint64_t esp_sleep_get_ext1_wakeup_status() {return 1;}\n",
            "sys/time.h": "#pragma once\n#include_next <sys/time.h>\ninline long fakeSeconds=1800000000;\ninline int fake_gettimeofday(timeval* out, void*) {out->tv_sec=fakeSeconds; out->tv_usec=0; return 0;}\n#define gettimeofday fake_gettimeofday\n",
            "lib/boot_diagnostics/boot_diagnostics.hpp": r'''
#pragma once
#include <cstdint>
namespace boot_diagnostics {
enum class Stage { I2cBus, Ready };
struct Snapshot { uint32_t bootSequence=5, firmwareFingerprint=123, resetReason=8; };
using StageCompletionObserver = void (*)(Stage);
inline StageCompletionObserver observer=nullptr;
inline Snapshot snapshot() { return {}; }
inline void setStageCompletionObserver(StageCompletionObserver fn) { observer=fn; }
}
''',
            "lib/ride_diagnostics/ride_diagnostics.hpp": r'''
#pragma once
#include <string>
#include <vector>
namespace ride_diagnostics {
enum class Level { Info };
struct Stats { bool storageAvailable=true; };
inline Stats stats() { return {}; }
inline bool accept=true;
inline std::vector<std::string> records;
inline bool record(Level, const char *category, const char *event, const char *fields) {
  if (std::string(category)!="power" || std::string(event)!="sleep_audit") return false;
  if (accept) records.emplace_back(fields);
  return accept;
}
}
''',
            "lib/waveshare_board/i2c_bus.hpp": r'''
#pragma once
#include <cstdint>
namespace waveshare_board::i2c {
inline unsigned reads=0;
inline bool readRegisterBlock8Once(uint8_t address, uint8_t reg, uint8_t* out, uint8_t len) {
  if (address != 0x34) return false;
  ++reads;
  for (uint8_t i=0; i<len; ++i) {
    switch (reg+i) {
      case 0: out[i]=0x08; break;
      case 1: out[i]=0x40; break;
      case 0x18: out[i]=0x08; break;
      case 0x30: out[i]=1; break;
      case 0x34: out[i]=15; break;
      case 0x35: out[i]=160; break;
      case 0xA4: out[i]=72; break;
      default: out[i]=0; break;
    }
  }
  return true;
}
}
''',
        }
        harness = r'''
#include <cassert>
#include "lib/power/sleep_audit.cpp"
int main() {
  using namespace sleep_audit;
  begin(); begin();
  assert(boot_diagnostics::observer != nullptr);
  boot_diagnostics::observer(boot_diagnostics::Stage::I2cBus);
  boot_diagnostics::observer(boot_diagnostics::Stage::I2cBus);
  assert(waveshare_board::i2c::reads == 8);
  boot_diagnostics::observer(boot_diagnostics::Stage::Ready);
  const auto earlyCount=ride_diagnostics::records.size();
  boot_diagnostics::observer(boot_diagnostics::Stage::Ready);
  assert(earlyCount == ride_diagnostics::records.size());
  RequestContext context{};
  context.configuredTimeoutSeconds=UINT32_MAX;
  context.displayState=2;
  requested(context);
  assert(policy::valid(retained) && retained.acceptedRequestRecords == 15);
  const auto recordsBefore=ride_diagnostics::records.size();
  recorderSealed(true); panelRequested(false); peripheralsReturned();
  entering(0, 0, policy::kNotAttempted, 0, 1, 1);
  assert(policy::valid(retained));
  assert(ride_diagnostics::records.size() == recordsBefore);
  assert(waveshare_board::i2c::reads == 16); // no post-seal reads
  fakeSeconds += 48*3600;
  initialized=false; sampledEarly=false; publishedBoot=false;
  begin();
  assert(resume.confirmedDeepSleep && resume.intervalValid);
  assert(resume.intervalMs == 48ULL*3600*1000);
  boot_diagnostics::observer(boot_diagnostics::Stage::I2cBus);
  boot_diagnostics::observer(boot_diagnostics::Stage::Ready);
  for (const auto& record : ride_diagnostics::records) std::puts(record.c_str());
  ride_diagnostics::accept=false;
  requested(context);
  assert(policy::valid(retained) && retained.acceptedRequestRecords == 0);
  recorderSealed(false);
  assert(policy::valid(retained) && retained.recorderSealed == 0);
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, contents in stubs.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            (root / "lib/power").mkdir()
            for name in ("sleep_audit.cpp", "sleep_audit.hpp", "sleep_audit_policy.hpp"):
                shutil.copyfile(POWER / name, root / "lib/power" / name)
            harness_path = root / "test.cpp"
            harness_path.write_text(harness)
            for board in ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"):
                with self.subTest(board=board):
                    output = self.compile_run(harness_path, root,
                        (board, "CONFIG_NEWLIB_TIME_SYSCALL_USE_RTC_HRT=1"))
                    records = [json.loads(line) for line in output.splitlines()]
                    self.assertTrue(any("confirmed_deep_sleep" in x["state"] for x in records))
                    self.assertTrue(any("interval_ms=172800000" in x["state"] for x in records))
                    self.assertTrue(any("interval_ms=unknown" in x["state"] for x in records))
                    self.assertTrue(any("voltage_mV=4000" in x["state"] for x in records))
                    for record in records:
                        self.assertLessEqual(len(record["state"]), 256)
                        self.assertEqual(set(record), {"schemaVersion", "phase", "domain",
                                                       "attemptId", "state", "available"})
                        self.assertIs(type(record["schemaVersion"]), int)
                        self.assertIs(type(record["available"]), bool)
                        for key in ("phase", "domain", "attemptId", "state"):
                            self.assertIsInstance(record[key], str)

    def test_existing_closed_field_vocabulary(self):
        # Full repository CI checks all three existing ingestion policies; no
        # new field or relaxed validation is required on older iPhone builds.
        sources = [
            (ROOT / "esp32/lib/ride_diagnostics/ride_diagnostics_format.hpp",
             ("kAllowedFieldKeys", "kNumberKeys", "kBooleanKeys")),
            (ROOT / "tools/ride_diagnostics.py",
             ("ALLOWED_FIELD_KEYS", "FIRMWARE_NUMBER_FIELD_KEYS", "FIRMWARE_BOOLEAN_FIELD_KEYS")),
            (ROOT / "ios-app/BikeComputer/BikeComputer/Utilities/RideDiagnostics.swift",
             ("static let allowedKeys", "static let firmwareNumberKeys", "static let firmwareBooleanKeys")),
        ]
        for path, markers in sources:
            text = path.read_text()
            sets = []
            for marker in markers:
                body = text.split(marker, 1)[1].split("=", 1)[1].lstrip()
                end = "}" if body[0] == "{" else "]"
                sets.append(set(re.findall(r'"([^"\n]+)"', body.split(end, 1)[0])))
            allowed, numbers, booleans = sets
            keys = {"schemaVersion", "phase", "domain", "attemptId", "state", "available"}
            self.assertTrue(keys <= allowed, str(path))
            self.assertEqual(keys & numbers, {"schemaVersion"}, str(path))
            self.assertEqual(keys & booleans, {"available"}, str(path))

    def test_shutdown_order_and_passive_final_checkpoint(self):
        power = (POWER / "power.cpp").read_text()
        request = power.split("void Power::deviceShutdown()", 1)[1].split(
            "void Power::deviceRestart()", 1)[0]
        self.assertIn("shutdownRequested_.store(true", request)
        self.assertNotIn("powerDeepSleep", request)
        shutdown = power[power.index("bool Power::processShutdown()") :]
        self.assertIn("if (shutdownBarrier_.permit())", shutdown)
        self.assertIn("Stage::Deferred", shutdown)
        self.assertLess(shutdown.index("sleep_audit::requested("),
                        shutdown.index("ride_diagnostics::pollShutdownQuiescence("))
        self.assertLess(shutdown.index("sleep_audit::recorderSealed("),
                        shutdown.index("powerOffPeripherals();"))
        sleep = power[power.index("void Power::powerDeepSleep()") : power.index("void Power::powerLightSleepTimer")]
        self.assertLess(sleep.index("if (!shutdownBarrier_.permit()) return;"),
                        sleep.index("esp_bt_controller_disable()"))
        self.assertNotIn("esp_wifi_stop()", sleep)
        self.assertLess(sleep.index("sleep_audit::entering("),
                        sleep.index("esp_deep_sleep_start();"))
        runtime = (POWER / "sleep_audit.cpp").read_text()
        final = runtime[runtime.index("void entering("):]
        for forbidden in ("samplePmic(", "observe(", "Serial.", "Wire.",
                          "esp_sleep_enable_", "prepareForShutdown("):
            self.assertNotIn(forbidden, final)
        self.assertNotIn("esp_sleep_enable_timer_wakeup", runtime)
        self.assertNotIn("writeRegister", runtime)


if __name__ == "__main__":
    unittest.main()
