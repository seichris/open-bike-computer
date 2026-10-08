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
            (path / "esp_memory_utils.h").write_text("#pragma once\nbool esp_ptr_internal(const void *);\n")
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
bool internalContext=true;
int opens=0;
bool esp_ptr_internal(const void *) { return internalContext; }
uint32_t value=0, staged=0; int writes=0;
int nvs_open(const char *name,int mode,nvs_handle_t *h) {
  assert(internalContext); ++opens;
  assert(!std::strcmp(name,"map_meta_floor")); *h=1;
  if(readFail) return -1;
  return mode==NVS_READONLY && !present ? ESP_ERR_NVS_NOT_FOUND : ESP_OK;
}
int nvs_get_u32(nvs_handle_t,const char *,uint32_t *out) { *out=value; return present?ESP_OK:ESP_ERR_NVS_NOT_FOUND; }
int nvs_set_u32(nvs_handle_t,const char *,uint32_t v) { staged=v; ++writes; return ESP_OK; }
int nvs_commit(nvs_handle_t) { if(!writeFail || ambiguous) {value=staged;present=true;} return writeFail?-1:ESP_OK; }
void nvs_close(nvs_handle_t) {}
int main(int argc,char **) {
  internalContext=false;
  assert(!policy::allowsReader(99) && !policy::floorAlreadyProtected(0));
  assert(opens==0); internalContext=true;
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
  internalContext=false;
  const int previousOpens=opens;
  assert(!policy::allowsReader(99) && !policy::floorAlreadyProtected(1));
  assert(!policy::requireReader(1) && opens==previousOpens && writes==before);
  internalContext=true;
  assert(!policy::allowsReader(99)); // unsafe retry remains ambiguous
  assert(policy::requireReader(1) && writes==before);
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

    def test_actual_receipt_nvs_adapter_rejects_external_stacks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path / "esp_memory_utils.h").write_text("#pragma once\nbool esp_ptr_internal(const void *);\n")
            (path / "nvs.h").write_text('''#pragma once
#include <cstddef>
using nvs_handle_t=int;
using esp_err_t=int;
constexpr int ESP_OK=0, ESP_ERR_NVS_NOT_FOUND=1, NVS_READONLY=0, NVS_READWRITE=1;
int nvs_open(const char *,int,nvs_handle_t *);
int nvs_get_blob(nvs_handle_t,const char *,void *,size_t *);
int nvs_set_blob(nvs_handle_t,const char *,const void *,size_t);
int nvs_commit(nvs_handle_t);
void nvs_close(nvs_handle_t);
''')
            (path / "test.cpp").write_text('''#include <cassert>
#include <array>
#include <cstring>
#include "nvs.h"
#include "firmware_operation_receipt.hpp"
namespace policy=firmware_update::receipt;
bool internalContext=true;
int calls=0, writes=0;
std::array<policy::Record,2> slots{};
std::array<bool,2> present{};
bool esp_ptr_internal(const void *) { return internalContext; }
int nvs_open(const char *name,int,nvs_handle_t *h) {
  assert(internalContext); ++calls; assert(!std::strcmp(name,"ota_receipt")); *h=1; return ESP_OK;
}
int nvs_get_blob(nvs_handle_t,const char *key,void *out,size_t *bytes) {
  assert(internalContext); ++calls; unsigned slot=key[7]-'0'; assert(slot<2);
  if(!present[slot]) return ESP_ERR_NVS_NOT_FOUND;
  assert(*bytes>=sizeof(policy::Record)); *bytes=sizeof(policy::Record);
  std::memcpy(out,&slots[slot],*bytes); return ESP_OK;
}
int nvs_set_blob(nvs_handle_t,const char *key,const void *data,size_t bytes) {
  assert(internalContext); ++calls; ++writes; unsigned slot=key[7]-'0'; assert(slot<2);
  assert(bytes==sizeof(policy::Record)); std::memcpy(&slots[slot],data,bytes); present[slot]=true; return ESP_OK;
}
int nvs_commit(nvs_handle_t) { assert(internalContext); ++calls; return ESP_OK; }
void nvs_close(nvs_handle_t) { assert(internalContext); ++calls; }
int main() {
  policy::Record record{}, input{};
  std::memset(input.device,'1',32); std::memset(input.operation,'a',32); std::memset(input.image,'b',64);
  input.partitionAddress=0x310000; input.imageBytes=1800000;
  internalContext=false; assert(!policy::load(record) && !policy::accept(input) && calls==0);
  internalContext=true; assert(policy::accept(input) && writes==1);
  assert(policy::load(record) && record.phase==policy::Phase::Accepted && record.revision==1);
  internalContext=false; const int before=calls;
  assert(!policy::load(record) && !policy::finish(true) && calls==before && writes==1);
  internalContext=true; assert(policy::finish(true) && writes==2);
  assert(policy::load(record) && record.phase==policy::Phase::Installed && record.revision==2);
  slots[0].checksum^=1; assert(!policy::load(record)); // no older cached success after corruption
}
''')
            executable = path / "test"
            subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(path), "-I", str(ROOT / "esp32/lib/firmware_update"),
                            str(path / "test.cpp"), str(ROOT / "esp32/lib/firmware_update/firmware_operation_receipt.cpp"),
                            "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_floor_precedes_new_metadata_and_boot_selection(self):
        source = (ROOT / "esp32/lib/map_transfer_http/map_transfer_http.cpp").read_text()
        upload = source[source.index("bool MapTransferHttpServer::handleInstallStream("):]
        self.assertLess(upload.index("protectMetadataReaderFloor(1)"), upload.index("new (std::nothrow) MapStreamReceiver"))
        control = source[source.index("bool MapTransferHttpServer::handleOperationControl("):]
        self.assertLess(control.index("protectMetadataReaderFloor(1)"), control.index("store.accept(record.identity)"))
        firmware = (ROOT / "esp32/lib/firmware_update/firmware_update_http.cpp").read_text()
        begin = firmware[firmware.index("void FirmwareUpdateHttpServer::handleBegin("):]
        self.assertLess(begin.index("verifyManifestSignature(signedPayload"), begin.index("operationOwner_.allowsMetadataReader(mapMetadataReaderVersion)"))
        self.assertLess(begin.index("operationOwner_.allowsMetadataReader(mapMetadataReaderVersion)"), begin.index("operationOwner_.begin("))
        finalize = firmware[firmware.index("void FirmwareUpdateHttpServer::handleFinalize("):]
        self.assertLess(finalize.index("operationOwner_.allowsMetadataReader(pendingMapMetadataReader_)"), finalize.index("operationOwner_.selectBootPartition("))
        self.assertNotIn("metadata_compatibility::allowsReader(", firmware)
        self.assertNotIn("receipt::load(", firmware)
        self.assertIn("operationOwner_.readFirmwareOperationReceipt(record)", firmware)
        self.assertIn('manifestPayload(2, target, version, build, gitSha, size, sha256,', begin)

if __name__ == "__main__":
    unittest.main()
