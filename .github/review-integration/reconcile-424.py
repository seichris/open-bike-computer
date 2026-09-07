from pathlib import Path

p = Path('esp32/src/main.cpp')
s = p.read_text()
a = s.index('<<<<<<< HEAD\n')
b = s.index('>>>>>>> review-main\n', a) + len('>>>>>>> review-main\n')
s = s[:a] + s[b:]
needle = '  log_i("Setup Complete");\n'
assert s.count(needle) == 1
s = s.replace(needle, needle + '  Serial.printf("RIDE_DIAGNOSTICS: recorder_ready=%u ui_ready=1\\n",\n                ride_diagnostics::recorderReady() ? 1U : 0U);\n')
p.write_text(s)
p = Path('esp32/tools/tests/test_runtime_ownership_contract.py')
s = p.read_text()
needle = '    def test_recorder_reports_degraded_startup(self):\n'
assert s.count(needle) == 1
s = s.replace(needle, '''    def test_ready_reporting_follows_boot_confirmation(self):
        main = source("src/main.cpp")
        setup = main[main.index("void setup()") : main.index("void loop()")]
        # Keep current-main's fail-closed confirmation: no early acceptance
        # or duplicate ready records while integrating recorder observability.
        confirmation = setup.index("!firmwareUpdateHttp.markRunningAppValid()")
        ready = setup.index("boot_diagnostics::markReady()")
        recorder = setup.index("recorder_ready=%u ui_ready=1")
        self.assertEqual(setup.count("markRunningAppValid()"), 1)
        self.assertEqual(setup.count('log_i("Setup Complete")'), 1)
        self.assertLess(setup.index("power_management::completeStartup()"), confirmation)
        self.assertLess(confirmation, ready)
        self.assertLess(ready, recorder)
        self.assertLess(setup.index("firmwareUpdateHttp.rejectRunningApp()"), ready)

''' + needle)
p.write_text(s)
p = Path('docs/reviews/firmware-runtime-fixes-2026-09-07.md')
s = p.read_text()
s += '''

## Current-main integration review — 2026-09-08

Integrated main `89d3c98f3a5d4e7fdfd37bc996113ccf0c61f7bd` into the
existing implementation, retaining the newer #422 fail-closed boot-confirmation
sequence. The only merge conflict is `esp32/src/main.cpp`: recorder readiness
must be reported after startup completion, running-image confirmation and boot
readiness, never by restoring the older early confirmation block. A regression
in `test_runtime_ownership_contract.py` checks this ordering and rejects duplicate
confirmation/ready calls.

The earlier PR comment attributing CI failure to `test_vector_runtime.cpp` and
13 `CHECK` macro errors is withdrawn: that file is absent from this pinned
repository tree. It is not a verified defect in this PR. Integration decisions
use the checksum-verified Git bundle and actual source/tests instead.

Local integration evidence (Linux host, not an ESP32 or Apple build):

- The real threaded ownership/allocation C++ executable passed with
  `-std=c++17 -Wall -Wextra -Werror -pthread`.
- All 8 runtime ownership source-contract tests passed, including the new
  startup/confirmation regression.
- Root tooling: 97 tests passed. Workflow tooling: 78 tests passed.
- Full firmware Python discovery ran 455 tests but is **not green** locally:
  the pre-connection asset module cannot import the unavailable `zxingcpp`
  dependency. No assertion failures were reported. CI must install the pinned
  asset requirements and execute the complete suite.
- Generated BLE contract verification and whitespace checks passed.

Exact published-head CI must be recorded separately after the branch update.
No native iOS/Watch builds, firmware compilation, device access, flashing, OTA,
release, deployment or physical qualification occurred in this integration.
The original implementation's historical results above are not fresh evidence.

**Merge qualification remains open:** these changes affect production-enabled
hardware paths. Per AGENTS.md, merge requires separate 1.75-inch and 2.06-inch
qualification or explicit, recorded maintainer acceptance of the residual risk.
No such hardware-risk exception is inferred from a general request to merge.
'''
p.write_text(s)
