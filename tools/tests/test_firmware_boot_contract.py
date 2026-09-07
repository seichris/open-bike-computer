"""Compile the actual confirmation bodies and strong startup hook against faulting host APIs."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class FirmwareBootContractTests(unittest.TestCase):
    def test_upstream_hook_and_confirmation_failure_paths(self):
        source = (ROOT / "esp32/lib/firmware_update/firmware_update_http.cpp").read_text()
        bodies = source[source.index("bool FirmwareUpdateHttpServer::markRunningAppValid()"):
                        source.index("bool FirmwareUpdateHttpServer::handleRequest(")]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "sdkconfig.h").write_text("#define CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE 1\n#define CONFIG_APP_ROLLBACK_ENABLE 1\n")
            harness = r'''
#include <cassert>
using esp_err_t = int;
enum esp_ota_img_states_t { ESP_OTA_IMG_UNDEFINED, ESP_OTA_IMG_VALID, ESP_OTA_IMG_PENDING_VERIFY, ESP_OTA_IMG_INVALID };
struct esp_partition_t {};
constexpr int ESP_OK = 0, ESP_ERR_NOT_FOUND = 1;
esp_partition_t partition;
bool hasPartition = true;
int queryResult = ESP_OK, markResult = ESP_OK, marks = 0, rejects = 0, restarts = 0;
bool persist = true;
esp_ota_img_states_t state = ESP_OTA_IMG_PENDING_VERIFY;
const esp_partition_t *esp_ota_get_running_partition() { return hasPartition ? &partition : nullptr; }
int esp_ota_get_state_partition(const esp_partition_t *, esp_ota_img_states_t *out) { *out = state; return queryResult; }
int esp_ota_mark_app_valid_cancel_rollback() { ++marks; if (markResult == ESP_OK && persist) state = ESP_OTA_IMG_VALID; return markResult; }
int esp_ota_mark_app_invalid_rollback_and_reboot() { ++rejects; return -1; }
struct { void restart() { ++restarts; } } ESP;
class FirmwareUpdateHttpServer { public: bool markRunningAppValid(); void rejectRunningApp(); };
extern "C" bool verifyRollbackLater() __attribute__((weak));
extern "C" bool verifyRollbackLater() { return false; }
''' + bodies + r'''
int main() {
  FirmwareUpdateHttpServer app;
  // Pinned Arduino initArduino's first-boot decision, before setup executes.
  if (!verifyRollbackLater()) esp_ota_mark_app_valid_cancel_rollback();
  assert(marks == 0 && state == ESP_OTA_IMG_PENDING_VERIFY);
  markResult = -2;
  assert(!app.markRunningAppValid() && state == ESP_OTA_IMG_PENDING_VERIFY);
  app.rejectRunningApp(); assert(rejects == 1 && restarts == 1);
  markResult = ESP_OK; persist = false;
  assert(!app.markRunningAppValid()); // reported success without durable VALID
  persist = true;
  assert(app.markRunningAppValid() && state == ESP_OTA_IMG_VALID);
  int prior = marks; assert(app.markRunningAppValid() && marks == prior);
  app.rejectRunningApp(); assert(rejects == 1); // do not invalidate confirmed boots
  queryResult = -3; assert(!app.markRunningAppValid());
  queryResult = ESP_ERR_NOT_FOUND; assert(app.markRunningAppValid()); // USB first boot
  queryResult = ESP_OK; state = ESP_OTA_IMG_INVALID; assert(!app.markRunningAppValid());
  hasPartition = false; assert(!app.markRunningAppValid());
}
'''
            (path / "test.cpp").write_text(harness)
            for target in ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"):
                executable = path / target
                subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", f"-D{target}",
                                "-I", str(path), str(path / "test.cpp"), str(ROOT / "esp32/src/firmware_ota_boot.cpp"),
                                "-o", str(executable)], check=True)
                subprocess.run([str(executable)], check=True)
        main = (ROOT / "esp32/src/main.cpp").read_text()
        completion = main[main.index("  mapTransferHttp.resumePendingActivations();"):main.index("void loop()")]
        self.assertLess(completion.index("power_management::completeStartup()"), completion.index("markRunningAppValid()"))
        self.assertLess(completion.index("markRunningAppValid()"), completion.index("boot_diagnostics::markReady()"))
        self.assertLess(completion.index("boot_diagnostics::markReady()"), completion.index('"acceptance"'))

    def test_production_acceptance_payload_survives_diagnostics_filter(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "test.cpp").write_text(r'''
#include <cassert>
#include <iostream>
#include "esp32/lib/firmware_metadata/firmware_metadata.hpp"
#include "esp32/lib/ride_diagnostics/ride_diagnostics_format.hpp"
int main() {
  auto payload = firmware_metadata::bootAcceptanceJson(true, "valid");
  assert(payload.size() < 320);
  assert(ride_diagnostics::detail::validateFieldsJson(payload.c_str(), payload.size()));
  std::cout << payload;
}
''')
            for target in ("WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"):
                executable = path / target
                subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT),
                                f'-DFLAVOR="{target}"', f'-DBUILD_PROFILE="{target}_PRODUCTION"',
                                '-DVERSION="0.3.4"', '-DREVISION=94', '-DGIT_SHA="' + 'a'*40 + '"',
                                str(path / "test.cpp"), str(ROOT / "esp32/lib/firmware_metadata/firmware_metadata.cpp"),
                                "-o", str(executable)], check=True)
                fields = json.loads(subprocess.check_output([str(executable)]))
                self.assertEqual(fields["firmwareProfile"], target + "_PRODUCTION")
                self.assertEqual(fields["firmwareGitSha"], "a" * 40)
                self.assertTrue(fields["ready"])


if __name__ == "__main__":
    unittest.main()
