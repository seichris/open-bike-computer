"""Host OTA receipt adapter and ordering contracts; not physical NVS evidence."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FirmwareOperationReceipts(unittest.TestCase):
    def test_nvs_adapter_commit_and_read_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)
            (p / "nvs.h").write_text(r'''
#pragma once
#include <cstddef>
using esp_err_t=int; using nvs_handle_t=int;
constexpr int ESP_OK=0, ESP_ERR_NVS_NOT_FOUND=1, NVS_READONLY=0, NVS_READWRITE=1;
int nvs_open(const char*,int,nvs_handle_t*);
int nvs_get_blob(nvs_handle_t,const char*,void*,size_t*);
int nvs_set_blob(nvs_handle_t,const char*,const void*,size_t);
int nvs_commit(nvs_handle_t);
void nvs_close(nvs_handle_t);
''')
            (p / "test.cpp").write_text(r'''
#include "esp32/lib/firmware_update/firmware_operation_receipt.hpp"
#include <nvs.h>
#include <map>
#include <string>
#include <vector>
#include <cassert>
using namespace firmware_update::receipt;
std::map<std::string,std::vector<unsigned char>> saved,pending;
bool failOpen=false,failCommit=false,failRead=false; int commits=0;
int nvs_open(const char* name,int,nvs_handle_t*h) { assert(std::string(name)=="ota_receipt");*h=1;return failOpen?-2:0; }
int nvs_get_blob(int,const char* key,void* out,size_t* n) { if(failRead)return -2;auto it=saved.find(key);if(it==saved.end())return 1;if(*n<it->second.size())return -3;*n=it->second.size();std::memcpy(out,it->second.data(),*n);return 0; }
int nvs_set_blob(int,const char* key,const void* in,size_t n) { const auto *b=static_cast<const unsigned char*>(in);pending[key]={b,b+n};return 0; }
int nvs_commit(int) { ++commits;if(failCommit){pending.clear();return -2;}for(auto&p:pending)saved[p.first]=p.second;pending.clear();return 0; }
void nvs_close(int) {}
int main(){
 Record r{};assert(load(r)&&r.phase==Phase::Empty);
 std::memset(r.device,'a',32);std::memset(r.operation,'b',32);std::memset(r.image,'c',64);r.partitionAddress=0x10000;r.imageBytes=500;
 failCommit=true;assert(!accept(r));Record check;assert(load(check)&&check.phase==Phase::Empty);
 failCommit=false;assert(accept(r));assert(load(check)&&check.phase==Phase::Accepted);
 assert(finish(true));int count=commits;assert(load(check)&&check.phase==Phase::Installed);assert(finish(true)&&commits==count);assert(!finish(false));
 assert(acknowledge(r.device,r.operation,r.image));assert(load(check)&&check.phase==Phase::Acknowledged);
 failRead=true;assert(!load(check));failRead=false;failOpen=true;assert(!load(check));
}
''')
            for gate in (0, 1):
                binary = p / f"receipt-{gate}"
                subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    f"-DFIRMWARE_OPERATIONS_V1_ENABLED={gate}", "-I", str(p), "-I", str(ROOT),
                    str(p / "test.cpp"), str(ROOT / "esp32/lib/firmware_update/firmware_operation_receipt.cpp"),
                    "-o", str(binary)], check=True)
                subprocess.run([str(binary)], check=True)

    def test_accept_before_selection_and_no_poll_writes(self):
        source = (ROOT / "esp32/lib/firmware_update/firmware_update_http.cpp").read_text()
        finalize = source[source.index("void FirmwareUpdateHttpServer::handleFinalize("):source.index("void FirmwareUpdateHttpServer::handleCancel(")]
        self.assertLess(finalize.index("beginAuthorizedCommit("), finalize.index("acceptFirmwareOperation("))
        self.assertLess(finalize.index("acceptFirmwareOperation("), finalize.index("selectBootPartition("))
        self.assertIn('request, "firmware", request.path, expectedSha256', finalize)
        query = source[source.index("std::string FirmwareUpdateHttpServer::operationReceiptJson()"):source.index("bool FirmwareUpdateHttpServer::reconcileOperationReceipt(")]
        self.assertNotIn("receipt::finish", query)
        self.assertNotIn("receipt::accept", query)
        boot = source[source.index("bool FirmwareUpdateHttpServer::markRunningAppValid()"):source.index("void FirmwareUpdateHttpServer::rejectRunningApp()")]
        self.assertLess(boot.index("reconcileOperationReceipt(false)"), boot.index("esp_ota_mark_app_valid_cancel_rollback()"))
        self.assertIn("(void)reconcileOperationReceipt(true)", boot)
        self.assertIn('admissionEpoch != operationAdmissionEpoch_', source)
        ios = (ROOT / "ios-app/BikeComputer/BikeComputer/Managers/FirmwareUpdateManager.swift").read_text()
        self.assertLess(ios.index("finalized = true"), ios.index("try await client.finalize()"))
        self.assertIn("pending.requiresOperationReceipt == true", ios)
        self.assertIn("receipt.matches(operationID: pending.operationID, image: pending.imageSHA256)", ios)
