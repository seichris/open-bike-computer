"""Execute the SD-independent metadata floor and verify its signed wire binding."""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class MetadataCompatibilityTests(unittest.TestCase):
    def test_actual_nvs_floor_adapter_fails_closed_without_sd(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path / "nvs.h").write_text('''#pragma once
#include <cstdint>
using nvs_handle_t = int;
using esp_err_t = int;
constexpr int ESP_OK=0, ESP_ERR_NVS_NOT_FOUND=1, NVS_READONLY=0, NVS_READWRITE=1;
int nvs_open(const char *, int, nvs_handle_t *);
int nvs_get_u32(nvs_handle_t, const char *, uint32_t *);
int nvs_set_u32(nvs_handle_t, const char *, uint32_t);
int nvs_commit(nvs_handle_t);
void nvs_close(nvs_handle_t);
''')
            (path / "test.cpp").write_text('''#include <cassert>
#include <cstring>
#include "nvs.h"
#include "firmware_metadata_compatibility.hpp"
namespace policy = firmware_update::metadata_compatibility;
bool present=false, readFail=false, writeFail=false, ambiguous=false;
uint32_t value=0, staged=0; int writes=0;
int nvs_open(const char *name,int mode,nvs_handle_t *h) {
  assert(!std::strcmp(name,"map_meta_floor")); *h=1;
  if(readFail) return -1;
  return mode==NVS_READONLY && !present ? ESP_ERR_NVS_NOT_FOUND : ESP_OK;
}
int nvs_get_u32(nvs_handle_t,const char *,uint32_t *out) { *out=value; return present?ESP_OK:ESP_ERR_NVS_NOT_FOUND; }
int nvs_set_u32(nvs_handle_t,const char *,uint32_t v) { staged=v; ++writes; return ESP_OK; }
int nvs_commit(nvs_handle_t) { if(!writeFail || ambiguous) {value=staged;present=true;} return writeFail?-1:ESP_OK; }
void nvs_close(nvs_handle_t) {}
int main(int argc,char **) {
  assert(policy::allowsReader(0)); // clean device requires no SD or NVS write
  assert(writes==0);
  if(argc>1) {
    writeFail=true; ambiguous=argc>2;
    assert(!policy::requireReader(1));
    assert(!policy::allowsReader(99)); // ambiguous persistence poisons admission
    writeFail=false;
  }
  assert(policy::requireReader(1));
  const int before=writes;
  assert(policy::requireReader(1) && writes==before); // no per-boot wear
  assert(!policy::allowsReader(0) && policy::allowsReader(1));
  readFail=true; assert(!policy::allowsReader(99)); readFail=false;
  present=false; value=0; // same-boot namespace regression cannot reset floor
  assert(!policy::allowsReader(0) && !policy::allowsReader(99));
}
''')
            executable = path / "test"
            subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(path), "-I", str(ROOT / "esp32/lib/firmware_update"),
                            str(path / "test.cpp"), str(ROOT / "esp32/lib/firmware_update/firmware_metadata_compatibility.cpp"),
                            "-o", str(executable)], check=True)
            for arguments in ([], ["fail-before"], ["fail-after", "committed"]):
                subprocess.run([str(executable), *arguments], check=True)

    def test_floor_precedes_new_metadata_and_boot_selection(self):
        source = (ROOT / "esp32/lib/map_transfer_http/map_transfer_http.cpp").read_text()
        upload = source[source.index("bool MapTransferHttpServer::handleInstallStream("):]
        self.assertLess(upload.index("protectMetadataReaderFloor(1)"), upload.index("new (std::nothrow) MapStreamReceiver"))
        control = source[source.index("bool MapTransferHttpServer::handleOperationControl("):]
        self.assertLess(control.index("protectMetadataReaderFloor(1)"), control.index("store.accept(record.identity)"))
        firmware = (ROOT / "esp32/lib/firmware_update/firmware_update_http.cpp").read_text()
        begin = firmware[firmware.index("void FirmwareUpdateHttpServer::handleBegin("):]
        self.assertLess(begin.index("verifyManifestSignature(signedPayload"), begin.index("allowsReader(mapMetadataReaderVersion)"))
        self.assertLess(begin.index("allowsReader(mapMetadataReaderVersion)"), begin.index("operationOwner_.begin("))
        finalize = firmware[firmware.index("void FirmwareUpdateHttpServer::handleFinalize("):]
        self.assertLess(finalize.index("allowsReader(pendingMapMetadataReader_)"), finalize.index("operationOwner_.selectBootPartition("))
        self.assertIn('manifestPayload(2, target, version, build, gitSha, size, sha256,', begin)

if __name__ == "__main__":
    unittest.main()
