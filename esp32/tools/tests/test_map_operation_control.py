"""Execute the production explicit map commit/cancel handler with its real ledger."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def method(source, name):
    start = source.index('bool MapTransferHttpServer::' + name + '(')
    opening = source.index('{', start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError('Unclosed production method')


class ExplicitMapOperationControlTests(unittest.TestCase):
    def test_real_handler_orders_grant_cancel_and_durable_intent(self):
        source = (ROOT / 'lib/map_transfer_http/map_transfer_http.cpp').read_text()
        shared = (ROOT / 'lib/device_transfer/device_transfer_http.cpp').read_text()
        grant = shared[shared.index('HttpTransferServer::CommitGrant HttpTransferServer::beginAuthorizedCommit('):]
        grant = grant[:grant.index('bool HttpTransferServer::endAuthorizedCommit(')]
        self.assertIn('request.path == operation', grant)
        self.assertIn('request.method == "PUT" || request.method == "POST"', grant)
        fixture = r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <functional>
#include <string>
#include <utility>
#include <vector>
#include "durable_operation.hpp"
#include "operation_admission_policy.hpp"
#include "commit_boundary_policy.hpp"
namespace operation = device_transfer::durable_operation;
constexpr int ESP_OK = 0;
namespace firmware_update { namespace metadata_compatibility { void noteUncertain() {} } }
namespace device_transfer {
struct HttpRequest {
  std::string method="POST", path, mapOperationID, mapStreamSHA256;
  std::string mapOperationAdmissionEpoch, mapStreamBytes, mapManifestReceipt;
  std::string mapSignedManifestReceipt, mapContentSession, mapLogicalID;
  bool hasContentLength=true, hasMapOperationAdmissionRevision=true;
  uint64_t contentLength=0, mapOperationAdmissionRevision=0;
  uint32_t transferGeneration=1; uint64_t requestSequence=7;
};
struct TransferClient { bool closed=false; void requestHttpResponseClose(){closed=true;} };
bool parseHttpUint64(const std::string&s,uint64_t&v) {
  if(s.empty()||!std::all_of(s.begin(),s.end(),[](char c){return c>='0'&&c<='9';}))return false;
  try {v=std::stoull(s);return true;}catch(...){return false;}
}
}
bool startsWith(const std::string &s,const std::string &p){return s.rfind(p,0)==0;}
struct MapOperationStorage:operation::Storage {
  static std::vector<uint8_t> slots[2]; static bool failWrite;
  MapOperationStorage(const std::string&){}
  bool read(unsigned n,std::vector<uint8_t>&out)override{out=slots[n];return true;}
  bool writeDurable(unsigned n,const std::vector<uint8_t>&in)override{
    if(failWrite)return false;
    slots[n]=in;return true;
  }
};
std::vector<uint8_t> MapOperationStorage::slots[2]; bool MapOperationStorage::failWrite=false;
struct Status { bool ok=true; std::string code="io",message="io"; };
struct ReadyStreamMap {std::string operationID,mapId,manifestReceipt,signedManifestReceipt;};
struct MapStreamInstallSnapshot{};
struct Installer {
  bool ready=true,promote=true,discarded=false,promoted=false; ReadyStreamMap marker;
  bool hasInterruptedActivation()const{return false;}
  Status readPreparedOperation(const std::string&,ReadyStreamMap&out){out=marker;return {ready,"io","io"};}
  Status discardUnselectedStreamMap(const std::string&){discarded=true;return {};}
  Status cancelOperationStaging(const std::string&,const std::string&){discarded=true;return {};}
  Status promotePreparedOperation(const std::string&,const std::string&){promoted=promote;return {promote,"io","io"};}
};
std::string operationReceiptJson(const operation::Record&r){return std::to_string(int(r.phase));}
struct TransferServer {
  bool authorized=true,closeAfterGrant=false;
  device_transfer::commit_boundary_policy::Boundary boundary;
  uint64_t beginAuthorizedCommit(const device_transfer::HttpRequest&request,const std::string&mode,const std::string&id,const std::string&artifact){
    auto grant=boundary.begin(authorized,mode=="map",request.path==id&&(request.method=="PUT"||request.method=="POST"),id,artifact);if(grant&&closeAfterGrant)authorized=false;return grant;
  }
};
struct Owner{bool allowed=true;int protectMetadataReaderFloor(int){return allowed?ESP_OK:-1;}};
class MapTransferHttpServer {
public:
  struct StateGuard{StateGuard(MapTransferHttpServer&){}};
  struct OperationStoreGuard{OperationStoreGuard(MapTransferHttpServer&){}};
  struct Response{uint32_t generation=0;std::string method,path;uint64_t sequence=0;};
  struct CommitRecovery{operation::Identity identity;Response response;bool pending()const{return !identity.operation.empty();}};
  enum class RollbackKind{None,Stream};
  struct Activation{bool acceptsUploads()const{return true;}};
  std::string storageRoot_="/sdcard",operationDeviceID_=std::string(32,'a');
  operation::AdmissionFence fence{std::string(32,'f')};
  Installer installer_;TransferServer server;TransferServer*transferServer_=&server;
  Owner owner;Owner*operationOwner_=&owner;Activation activationState_;
  CommitRecovery commitRecovery_;uint64_t pendingCommitGrant_=0;std::string terminalOperationID_;
  RollbackKind rollbackKind_=RollbackKind::None;
  bool supported=true,storageReady=true,deferred=false,deferAllowed=true;
  int response=0;std::string body;
  bool operationsSupported()const{return supported;}
  bool refreshStreamStorageCapability(bool){return storageReady;}
  bool observeOperationRevision(uint64_t n){return fence.observe(n);}
  bool permitsOperationAdmission(const std::string&e,uint64_t n){return fence.permits(e,n);}
  void sendError(device_transfer::TransferClient&,int code,const std::string&,const std::string&){response=code;}
  void sendJson(device_transfer::TransferClient&,int code,const std::string&value){response=code;body=value;}
  void updateStreamInstallState(MapStreamInstallSnapshot,bool){}
  std::string readOperationStatus(const std::string&id){
    MapOperationStorage disk("");operation::Store store(disk,operationDeviceID_);operation::Record r;
    return store.restore()==operation::Result::Ok&&store.queryID(id,r)==operation::Result::Ok?operationReceiptJson(r):"unavailable";
  }
  bool deferActivationUntilResponse(const device_transfer::HttpRequest&,const std::string&){deferred=deferAllowed;return deferAllowed;}
  bool handleOperationControl(const device_transfer::HttpRequest&,device_transfer::TransferClient&);
};
'''
        fixture += method(source, 'handleOperationControl')
        fixture += r'''
int main(){
 const operation::Identity id{std::string(32,'a'),std::string(32,'b'),std::string(64,'c'),std::string(64,'d'),std::string(64,'e'),100,"session","map"};
 for(int scenario=0;scenario<23;++scenario){
  for(auto &slot:MapOperationStorage::slots)slot.clear();
  MapOperationStorage::failWrite=false;
  MapOperationStorage disk("");operation::Store ledger(disk,id.device);
  assert(ledger.restore()==operation::Result::Ok);assert(ledger.initializeAdmission(99)==operation::Result::Ok);
  const bool absent=scenario==8||scenario==9||scenario==10||scenario==21;
  if(!absent){assert(ledger.admit(id,ledger.admissionRevision())==operation::Result::Ok);assert(ledger.prepare(id)==operation::Result::Ok);}
  MapTransferHttpServer handler;assert(handler.fence.observe(ledger.admissionRevision()));
  handler.installer_.marker={id.operation,id.map,id.manifest,id.signedManifest};
  device_transfer::HttpRequest request;request.path="/map-transfer/operations/"+id.operation+"/commit";
  request.mapOperationID=id.operation;request.mapStreamSHA256=id.stream;request.mapOperationAdmissionEpoch=std::string(32,'f');
  request.mapOperationAdmissionRevision=ledger.admissionRevision();request.mapStreamBytes="100";
  request.mapManifestReceipt=id.manifest;request.mapSignedManifestReceipt=id.signedManifest;request.mapContentSession=id.session;request.mapLogicalID=id.map;
  device_transfer::TransferClient client;
  if(scenario==1||scenario==8||scenario==9||scenario==10||scenario==18||scenario==19||scenario==21)request.path.replace(request.path.size()-6,6,"cancel");
  if(scenario==2)handler.server.authorized=false;
  if(scenario==3)handler.server.closeAfterGrant=true;
  if(scenario==4)request.mapStreamSHA256=std::string(64,'9');
  if(scenario==5)handler.installer_.ready=false;
  if(scenario==6)handler.owner.allowed=false;
  if(scenario==7)handler.installer_.promote=false;
  if(scenario==9)request.mapOperationAdmissionEpoch=std::string(32,'0');
  if(scenario==10)request.mapManifestReceipt="bad";
  if(scenario==11)handler.server.boundary.closeAdmission(true);
  if(scenario==12)request.contentLength=1;
  if(scenario==13)request.mapOperationID=std::string(32,'0');
  if(scenario==14)handler.deferAllowed=false;
  if(scenario==15)MapOperationStorage::failWrite=true;
  if(scenario==16)handler.supported=false;
  if(scenario==17)handler.storageReady=false;
  if(scenario==18){assert(ledger.accept(id)==operation::Result::Ok);assert(ledger.rendererAcknowledged(id,id.manifest,id.signedManifest)==operation::Result::Ok);}
  if(scenario==19)assert(ledger.cancel(id)==operation::Result::Ok);
  if(scenario==20)handler.operationDeviceID_=std::string(32,'9');
  if(scenario==21)--request.mapOperationAdmissionRevision;
  if(scenario==22){request.path="/map-transfer/operations/"+std::string(32,'z')+"/commit";request.mapOperationID=std::string(32,'z');}
  assert(handler.handleOperationControl(request,client));
  MapOperationStorage::failWrite=false;assert(ledger.restore()==operation::Result::Ok);operation::Record record;auto result=ledger.query(id,record);
  if(scenario==0||scenario==3){
   assert(handler.response==200&&handler.deferred&&handler.installer_.promoted&&client.closed);
   assert(result==operation::Result::Ok&&record.phase==operation::Phase::Accepted);
   assert(handler.pendingCommitGrant_!=0);
   // Grant won: cancellation cannot undo acceptance, including revoked socket authority.
   request.path.replace(request.path.size()-6,6,"cancel");handler.handleOperationControl(request,client);
   assert(handler.response==409);assert(ledger.restore()==operation::Result::Ok);assert(ledger.query(id,record)==operation::Result::Ok&&record.phase==operation::Phase::Accepted);
   // Exact commit replay returns the accepted receipt without new promotion/grant.
   request.path.replace(request.path.size()-6,6,"commit");auto grant=handler.pendingCommitGrant_;handler.handleOperationControl(request,client);
   assert(handler.response==200&&handler.pendingCommitGrant_==grant);
  }else if(scenario==1||scenario==8){
   assert(handler.response==200&&result==operation::Result::Ok&&record.phase==operation::Phase::Cancelled);
   assert(!handler.installer_.promoted&&handler.pendingCommitGrant_==0);
   request.path.replace(request.path.size()-6,6,"commit");handler.handleOperationControl(request,client);
   assert(handler.response==409&&!handler.installer_.promoted);
  }else if(scenario==7||scenario==14){
   assert(handler.response==503&&client.closed&&handler.commitRecovery_.pending()&&handler.pendingCommitGrant_!=0);
   assert(result==operation::Result::Ok&&record.phase==operation::Phase::Accepted);
  }else if(scenario==18||scenario==19){
   assert(result==operation::Result::Ok&&record.phase==(scenario==18?operation::Phase::Installed:operation::Phase::Cancelled));
   assert(handler.response==(scenario==18?409:200)&&handler.pendingCommitGrant_==0&&!handler.installer_.promoted);
  }else if(scenario==15){
   assert(handler.response==503&&client.closed&&handler.commitRecovery_.pending()&&handler.pendingCommitGrant_!=0);
  }else{
   assert(handler.response>=400&&!handler.installer_.promoted&&handler.pendingCommitGrant_==0);
   if(absent)assert(result==operation::Result::Unavailable);else assert(result==operation::Result::Ok&&record.phase==operation::Phase::Prepared);
  }
 }
}
'''
        with tempfile.TemporaryDirectory(prefix='map-operation-control-') as temporary:
            path = Path(temporary)
            (path / 'test.cpp').write_text(fixture)
            subprocess.run([shutil.which('c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-I' + str(ROOT / 'lib/device_transfer'), str(path / 'test.cpp'),
                            str(ROOT / 'lib/device_transfer/durable_operation.cpp'), '-o', str(path / 'test')], check=True)
            subprocess.run([str(path / 'test')], check=True)


if __name__ == '__main__':
    unittest.main()
