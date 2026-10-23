"""Execute the production map-library controller against a real durable ledger."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


class MapLibraryControlTests(unittest.TestCase):
    def test_library_selection_busy_coverage_and_allocation_recovery(self):
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        core = (ROOT / "lib/map_transfer/map_transfer.cpp").read_text()
        install = between(source, 'bool MapTransferHttpServer::handleInstallStream(',
                          'void MapTransferHttpServer::handleStatus(')
        failure = install[install.index('if (cancelled || !receiver->readyToFinish()) {'):]
        # The HTTP refusal path resolves this request's own operation before replying.
        self.assertLess(failure.index('resolveRejectedStreamOperation(request, receiver->snapshot())'),
                        failure.index('sendError(client, cancelled ? 409 : result.httpStatus'))
        self.assertIn('"\\"},\\"operation\\":" + resolved', failure)
        fixture = r'''
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <functional>
#include <memory>
#include <new>
#include <string>
#include <vector>
#include "map_transfer.hpp"
#include "map_activation_workspace.hpp"
#include "durable_operation.hpp"
#include "map_selection_health.hpp"
constexpr int ESP_OK=0,ESP_ERR_TIMEOUT=1,ESP_ERR_INVALID_STATE=5;
uint32_t clockMs=100;
uint32_t millis(){return clockMs;}
namespace ui_scheduler {enum class WakeReason{Transfer};void notify(WakeReason){}}
struct SerialPort {void println(const char*){} template<typename... T> void printf(const char*,T...){}} Serial;
namespace device_transfer {
struct HttpRequest {std::string mapOperationID,mapStreamSHA256;uint64_t contentLength=0;};
}
namespace map_transfer {
namespace operation = device_transfer::durable_operation;
// The fields of map_stream_install.hpp's snapshot that the resolver reads; the
// real header needs mbedTLS. The stream session's Failed snapshot itself is
// exercised in test_map_stream_install.cpp.
enum class MapStreamInstallState{Idle,Receiving,Failed};
struct MapStreamInstallSnapshot{
  MapStreamInstallState state=MapStreamInstallState::Idle;
  std::string sessionId,mapId,manifestReceipt,signedManifestReceipt,errorCode;
  uint64_t completedPayloadBytes=0,bytesWritten=0;uint32_t durableFilePrefix=0;
};
struct MapOperationStorage:operation::Storage {
  static std::vector<uint8_t> slots[2];
  MapOperationStorage(const std::string&){}
  bool read(unsigned n,std::vector<uint8_t>&out)override{out=slots[n];return true;}
  bool writeDurable(unsigned n,const std::vector<uint8_t>&in)override{slots[n]=in;return true;}
};
std::vector<uint8_t> MapOperationStorage::slots[2];
std::string operationReceiptJson(const operation::Record&r){
  return r.phase==operation::Phase::Failed?"failed":r.phase==operation::Phase::Receiving?"receiving":"other";
}
// Installer seam. The journal follows the production contract (exercised on a
// real filesystem in test_map_transfer.cpp): pin manual only for the exact
// surviving pointer, otherwise drop the journal and keep policy.
struct Installer {
  bool automatic=true,currentCovers=false,candidateCovers=true,throwAfterSelect=false,policyWrite=true;
  bool intentWrite=true,rollbackWorks=true;
  int selected=0,scans=0,selectAttempts=0,removed=0;bool throwRefresh=false;std::string selectionError,intentRoot;
  ActiveMapSelection active,previous;
  bool automaticMapSelection(){return automatic;}
  bool setAutomaticMapSelection(bool value){if(policyWrite){automatic=value;}return policyWrite;}
  bool writeManualSelectionIntent(const std::string&,const std::string&root,const std::string&){
    if(!intentWrite){return false;}
    intentRoot=root;return true;
  }
  bool manualSelectionIntentPending(){return !intentRoot.empty();}
  bool discardManualSelectionIntent(){intentRoot.clear();return true;}
  InstallStatus reconcileManualSelectionIntent(){
    if(intentRoot.empty())return {true,"library_intent_none",""};
    if(active.root==intentRoot&&!setAutomaticMapSelection(false))return {false,"library_policy_write",""};
    intentRoot.clear();return {true,"library_intent_settled",""};
  }
  InstallStatus readActiveMap(ActiveMapSelection&out){
    if(selected && throwAfterSelect){throwAfterSelect=false;throw std::bad_alloc();}
    out=active;return {true,"ok",""};
  }
  bool mapRootHasBlock(const std::string&,int32_t,int32_t){return currentCovers;}
  bool installedMapCovers(const InstalledMap&,int32_t,int32_t){return candidateCovers;}
  InstallStatus selectInstalledMap(const std::string&s,const std::string&){
    ++selectAttempts;
    if(!selectionError.empty())return {false,selectionError,""};
    ++selected;previous=active;active.root="/VECTMAP/.maps/"+s;active.sessionId=s;active.mapId="city";
    return {true,"selected",""};
  }
  InstallStatus rollbackActiveMap(const std::string&){
    if(!rollbackWorks)return {false,"active_rollback_unavailable",""};
    active=previous;return {true,"active_rolled_back",""};
  }
  InstallStatus removeInstalledMap(const std::string&s,const std::string&){
    // Production refuses the canonical selection and rollback roots.
    if(active.root=="/VECTMAP/.maps/"+s||previous.root=="/VECTMAP/.maps/"+s)return {false,"library_in_use",""};
    ++removed;return {true,"ok",""};
  }
  bool pruneObsoleteInstalledMaps(){return true;}
  InstallStatus readMapLibrary(std::vector<InstalledMap>&){++scans;if(throwRefresh){throwRefresh=false;throw std::bad_alloc();}return {true,"ok",""};}
};
struct Activation {
  bool running=false,throwBegin=false;
  bool acceptsUploads()const{return !running;}
  void finish(std::string,std::string,std::string,std::string){running=false;}
  void begin(const std::string&,int){running=true;if(throwBegin){throwBegin=false;throw std::bad_alloc();}}
};
struct Server {bool enabled=false;Server status(){return *this;}};
// Production dispatch runs the callback on the owner before returning ESP_OK.
struct Owner {bool issued=false;int result=ESP_ERR_TIMEOUT;int dispatches=0;
  int runMapActivation(void (*callback)(void*,const char*,bool),void*context,const std::string&,bool,bool*out){
    ++dispatches;*out=issued;
    if(result==ESP_OK){*out=true;callback(context,"library",false);}
    return result;
  }
};
struct Recovery {bool pending()const{return false;}};
class MapTransferHttpServer {
public:
  struct StateGuard {StateGuard(const MapTransferHttpServer&){}};
  struct OperationStoreGuard {OperationStoreGuard(const MapTransferHttpServer&){}};
  enum class RollbackKind{None,Transfer,Runtime};
  Server server;Server*transferServer_=&server;Installer installer_;Activation activationState_;
  Owner owner;Owner*operationOwner_=&owner;
  std::string storageRoot_="/sdcard",operationDeviceID_=std::string(32,'a');
  MapSelectionHealth selectionHealth_;
  std::vector<InstalledMap> libraryMaps_;
  std::string libraryAction_,librarySession_,libraryReceipt_,libraryRequestID_,libraryCommandID_,libraryCommandError_,libraryError_;
  std::vector<std::string> libraryRejectedSessions_;
  bool libraryKnown_=true,libraryAutomatic_=true,librarySubmitted_=false,librarySelectionStarted_=false;
  bool libraryManualPending_=false,pendingMapFromLibrary_=false,rollbackFromLibrary_=false;
  uint32_t libraryRevision_=0,libraryRetryAfterMs_=0;
  uint8_t libraryRetryStreak_=0;
  uint64_t libraryAutomaticBlock_=0,pendingCommitGrant_=0;
  bool libraryAutomaticBlockKnown_=false,streamStorageAvailable_=true,operationTaskSubmitted_=false;
  size_t libraryPageOffset_=0;
  int32_t libraryLatitudeE7_=0,libraryLongitudeE7_=0;
  std::string operationQuery_;Recovery commitRecovery_;
  std::function<bool(void(*)(void*),void*)> storageControlSubmit_;
  void(*queuedWork_)(void*)=nullptr;void*queuedContext_=nullptr;
  std::string pendingMapRoot_,pendingMapSessionId_,pendingMapId_,pendingMapOperationID_,pendingMapLibraryCommandID_;
  std::string terminalOperationID_,terminalSessionID_,terminalMapID_,rollbackOperationID_,rollbackSession_;
  bool terminalAutomaticExit_=false,terminalFailed_=false,rollbackAutomaticExit_=false,rollbackSubmitted_=false;
  bool rollbackSucceeded_=false,rollbackComplete_=false;ActiveMapSelection rollbackRestored_;
  bool pendingMapRootTaken_=false,pendingRendererAcknowledgement_=false,pendingRendererAutomaticExit_=false,operationStatusNotification_=false;
  RollbackKind rollbackKind_=RollbackKind::None;
  MapTransferHttpServer(){
    // Production storage control runs later on the render worker.
    storageControlSubmit_=[this](void(*work)(void*),void*context){queuedWork_=work;queuedContext_=context;return true;};
  }
  bool runQueued(){
    if(!queuedWork_){return false;}
    auto work=queuedWork_;queuedWork_=nullptr;work(queuedContext_);return true;
  }
  bool requestMapLibrary(const std::string&,const std::string&="",const std::string&="",const std::string&="");
  bool libraryRetryPending();
  void scheduleLibraryRetry(uint32_t);
  void considerAutomaticMap(int32_t,int32_t,bool);
  void submitLibraryTask();
  void lockState(){} void unlockState(){}
  void finishActivation(std::string a,std::string b,std::string c,std::string d){activationState_.finish(a,b,c,d);}
  void releaseCommitGrant(){} void requestAutomaticExit(){}
  std::string selectionOperationID(const ActiveMapSelection&){return "";}
  bool observeOperationRevision(uint64_t){return true;}
  void acknowledgeActivatedMapRoot(const std::string&,bool);
  void executeRollback();
  void executeLibraryTask();
  void recoverLibraryTask(const char*);
  std::string resolveRejectedStreamOperation(const device_transfer::HttpRequest&,const MapStreamInstallSnapshot&);
  static void libraryTask(void*);
  static void ownedLibraryTask(void*,const char*,bool);
  std::string mapLibraryJson(bool paged) const;
};
'''.replace('const std::string&=', 'const std::string & =')
        fixture += between(core, 'const InstalledMap *coveringLibraryMap(', 'InstallStatus MapTransferInstaller::readInstalledMap(')
        fixture += between(core, 'bool InstalledMap::contains(', 'const InstalledMap *coveringLibraryMap(').split('uint64_t libraryPositionBlockKey')[0] if 'bool InstalledMap::contains(' in core else ''
        fixture += between(core, 'uint64_t libraryPositionBlockKey(', 'bool MapTransferInstaller::mapRootHasBlock(')
        fixture += between(source, 'static std::string jsonEscape(', 'void MapTransferHttpServer::configure(').split('} // namespace')[0]
        fixture += between(source, 'std::string MapTransferHttpServer::mapLibraryJson(', 'void MapTransferHttpServer::considerAutomaticMap(')
        fixture += between(source, 'bool MapTransferHttpServer::requestMapLibrary(', 'bool MapTransferHttpServer::requestMapLibraryPage(')
        fixture += between(source, 'void MapTransferHttpServer::considerAutomaticMap(', 'void MapTransferHttpServer::libraryTask(')
        fixture += between(source, 'void MapTransferHttpServer::libraryTask(', 'void MapTransferHttpServer::executeLibraryTask()')
        fixture += between(source, 'void MapTransferHttpServer::executeLibraryTask()', 'void MapTransferHttpServer::releaseCommitGrant(')
        fixture += between(source, 'void MapTransferHttpServer::acknowledgeActivatedMapRoot(', 'std::string MapTransferHttpServer::selectionOperationID(')
        fixture += between(source, 'void MapTransferHttpServer::executeRollback() {', 'bool MapTransferHttpServer::takeAutomaticExitRequest(')
        fixture += between(source, 'std::string MapTransferHttpServer::resolveRejectedStreamOperation(', 'bool MapTransferHttpServer::handleOperationControl(')
        fixture += r'''
InstalledMap city(){InstalledMap m;m.sessionId="city";m.mapId="city";m.root="/VECTMAP/.maps/city";m.manifestReceipt=std::string(64,'b');m.presentation.hasBoundsE7=true;m.presentation.boundsE7={-1000000,-1000000,1000000,1000000};return m;}
InstalledMap home(){auto m=city();m.sessionId="home";m.mapId="home";m.root="/VECTMAP/.maps/home";return m;}
void reset(){for(auto&s:MapOperationStorage::slots)s.clear();clockMs=100;}
operation::Identity id(const std::string&session="paused",const std::string&operation=std::string(32,'1')){
  return {std::string(32,'a'),operation,std::string(64,'b'),std::string(64,'c'),std::string(64,'d'),100,session,"map"};
}
operation::Phase phaseOf(const operation::Identity&identity){
  MapOperationStorage disk("");operation::Store store(disk,std::string(32,'a'));operation::Record record;
  assert(store.restore()==operation::Result::Ok&&store.query(identity,record)==operation::Result::Ok);return record.phase;
}
void admitReceiving(const operation::Identity&identity){
  MapOperationStorage disk("");operation::Store store(disk,std::string(32,'a'));
  assert(store.restore()==operation::Result::Ok);
  if(store.admissionRevision()==0)assert(store.initializeAdmission(99)==operation::Result::Ok);
  assert(store.admit(identity,store.admissionRevision())==operation::Result::Ok);
}
// The live map is home, rendered and acknowledged; city is the switch target.
void liveHome(MapTransferHttpServer&s){
  s.libraryMaps_={city(),home()};s.installer_.active.root=home().root;s.installer_.active.sessionId="home";
  s.selectionHealth_.select(home().root,"","home","home",true);
}
void failRendererAndRollback(MapTransferHttpServer&s,const std::string&root){
  assert(s.pendingRendererAcknowledgement_&&s.pendingMapRoot_==root);
  s.pendingMapRootTaken_=true;s.acknowledgeActivatedMapRoot(root,false);
  assert(s.rollbackKind_==MapTransferHttpServer::RollbackKind::Transfer&&s.rollbackFromLibrary_);
  s.executeRollback();
}
}
int main(){using namespace map_transfer;
  for(int phase=0;phase<5;++phase){
    reset();MapOperationStorage disk("");operation::Store store(disk,std::string(32,'a'));
    assert(store.restore()==operation::Result::Ok);assert(store.initializeAdmission(99)==operation::Result::Ok);
    const auto identity=id();
    if(phase){assert(store.admit(identity,store.admissionRevision())==operation::Result::Ok);}
    if(phase>=2)assert(store.prepare(identity)==operation::Result::Ok);
    if(phase>=3)assert(store.accept(identity)==operation::Result::Ok);
    if(phase==4)assert(store.rendererAcknowledged(identity,identity.manifest,identity.signedManifest)==operation::Result::Ok);
    MapTransferHttpServer s;s.libraryMaps_={city()};
    assert(s.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'f')));s.executeLibraryTask();
    const bool pending=phase>0&&phase<4;
    assert((s.installer_.selected==0)==pending);
    assert(s.pendingRendererAcknowledgement_==!pending);
    // Use is journaled; the manual policy waits for the renderer ACK.
    assert(s.installer_.automatic&&s.libraryManualPending_==!pending);
    assert(s.libraryCommandID_==std::string(32,'f'));
    assert((s.libraryCommandError_=="library_operation_pending")==pending);
    if(!pending){
      assert(s.mapLibraryJson(true).find("\"automatic\":false")!=std::string::npos);
      s.pendingMapRootTaken_=true;s.acknowledgeActivatedMapRoot(city().root,true);
      assert(s.libraryAction_=="refresh");s.executeLibraryTask();
      assert(!s.installer_.automatic&&!s.libraryManualPending_&&s.libraryCommandError_.empty());
    }
    if(pending){
      MapTransferHttpServer covered;covered.libraryMaps_={city()};covered.installer_.currentCovers=true;
      covered.considerAutomaticMap(0,0,false);covered.executeLibraryTask();
      assert(covered.libraryAutomaticBlockKnown_&&covered.libraryError_.empty());
      clockMs+=30000;covered.considerAutomaticMap(0,0,false);assert(covered.libraryAction_.empty());
    }
  }
  reset();
  for(bool covers:{false,true}){
    MapTransferHttpServer s;s.libraryMaps_={city()};s.installer_.candidateCovers=false;s.installer_.currentCovers=covers;
    s.installer_.active.root="/VECTMAP";s.considerAutomaticMap(0,0,false);assert(!s.libraryAction_.empty());s.executeLibraryTask();
    assert(s.installer_.selected==0&&s.installer_.scans==0&&s.libraryRevision_==0);
    for(int tick=0;tick<100;++tick){clockMs+=5000;s.considerAutomaticMap(0,0,false);assert(s.libraryAction_.empty());}
    // The upload/renderer ACK path schedules refresh directly, without a BLE request.
    s.libraryAction_="refresh";s.executeLibraryTask();assert(!s.libraryAutomaticBlockKnown_);
  }
  for(bool throwInBegin:{false,true}){
    reset();MapTransferHttpServer s;s.libraryMaps_={city()};s.installer_.throwAfterSelect=!throwInBegin;s.activationState_.throwBegin=throwInBegin;
    s.considerAutomaticMap(0,0,false);s.executeLibraryTask();
    assert(s.libraryError_=="library_memory"&&s.librarySelectionStarted_&&!s.activationState_.running);
    assert(s.libraryRetryAfterMs_>clockMs);clockMs+=5000;s.executeLibraryTask();
    assert(s.pendingRendererAcknowledgement_&&s.pendingMapRoot_==city().root&&s.libraryAction_.empty());
  }
  reset();
  for(const std::string error:{"label_block_contract","label_font_missing","label_languages"}) {
    MapTransferHttpServer bad;bad.libraryMaps_={city()};bad.installer_.selectionError=error;
    bad.considerAutomaticMap(0,0,false);bad.executeLibraryTask();
    assert(bad.libraryRejectedSessions_.size()==1);
    for(int tick=0;tick<10;++tick){clockMs+=30000;bad.considerAutomaticMap(0,0,false);assert(bad.libraryAction_.empty());}
    assert(bad.installer_.selectAttempts==1);
  }
  MapTransferHttpServer fallback;auto second=city();second.sessionId="city-2";second.root+="-2";
  fallback.libraryMaps_={city(),second};fallback.libraryCommandID_=std::string(32,'a');
  fallback.considerAutomaticMap(0,0,false);fallback.executeLibraryTask();
  assert(fallback.libraryAutomaticBlockKnown_);
  fallback.pendingMapRootTaken_=true;fallback.acknowledgeActivatedMapRoot(city().root,false);
  assert(!fallback.libraryAutomaticBlockKnown_&&fallback.libraryCommandError_.empty());
  assert(fallback.libraryCommandID_==std::string(32,'a')); // Automatic failure cannot rewrite a client result.
  fallback.installer_.active={};fallback.rollbackKind_=MapTransferHttpServer::RollbackKind::None;fallback.activationState_.running=false;
  fallback.libraryAction_.clear();
  fallback.considerAutomaticMap(0,0,false);assert(fallback.librarySession_=="city-2");fallback.executeLibraryTask();
  assert(fallback.pendingRendererAcknowledgement_&&fallback.pendingMapRoot_==second.root);
  MapTransferHttpServer refresh;refresh.libraryAction_="remove";refresh.libraryRequestID_=std::string(32,'b');refresh.installer_.throwRefresh=true;
  refresh.executeLibraryTask();assert(!refresh.libraryKnown_&&refresh.libraryAction_=="refresh"&&refresh.libraryRequestID_.empty());
  assert(refresh.libraryCommandError_=="library_memory");clockMs+=5000;refresh.executeLibraryTask();assert(refresh.libraryKnown_);
  MapTransferHttpServer expired;expired.libraryMaps_={city()};expired.libraryRetryAfterMs_=clockMs-1;
  expired.considerAutomaticMap(0,0,false);assert(expired.libraryRetryAfterMs_==0);
  expired.libraryAction_.clear();expired.libraryRetryAfterMs_=100;clockMs=0x80000100U;
  expired.considerAutomaticMap(0,0,false);assert(expired.libraryRetryAfterMs_==0);
  reset();MapTransferHttpServer s;s.libraryMaps_={city()};s.installer_.selectionError="library_integrity";
  assert(s.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'e')));s.executeLibraryTask();
  assert(s.installer_.automatic&&!s.pendingRendererAcknowledgement_&&!s.libraryManualPending_);
  s.librarySubmitted_=true;assert(!s.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'f')));
  assert(s.libraryCommandID_==std::string(32,'f')&&s.libraryCommandError_=="library_busy");
  for(bool issued:{false,true}) {
    MapTransferHttpServer pending;pending.librarySubmitted_=true;pending.libraryAction_="select";pending.libraryRequestID_=std::string(32,'a');pending.owner.issued=issued;
    MapTransferHttpServer::libraryTask(&pending);
    assert(pending.librarySubmitted_==issued);
    if(!issued)assert(pending.libraryCommandError_=="library_owner"&&pending.libraryRevision_==1);
  }

  // N1: a full-card refusal before payload writes resolves only its own Receiving
  // operation, so removing a map (the remedy) is no longer blocked.
  reset();{
    const auto rejected=id("full-card",std::string(32,'2'));admitReceiving(rejected);
    const auto unrelated=id("paused-other",std::string(32,'3'));admitReceiving(unrelated);
    MapTransferHttpServer server;liveHome(server);
    device_transfer::HttpRequest request;request.mapOperationID=rejected.operation;
    request.mapStreamSHA256=rejected.stream;request.contentLength=rejected.streamBytes;
    MapStreamInstallSnapshot snapshot;snapshot.state=MapStreamInstallState::Failed;snapshot.errorCode="stream_sd_full";
    snapshot.sessionId=rejected.session;snapshot.mapId=rejected.map;
    snapshot.manifestReceipt=rejected.manifest;snapshot.signedManifestReceipt=rejected.signedManifest;
    assert(server.resolveRejectedStreamOperation(request,snapshot)=="failed");
    assert(phaseOf(rejected)==operation::Phase::Failed&&phaseOf(unrelated)==operation::Phase::Receiving);
    // A different paused upload no longer blocks removal of another map ...
    assert(server.requestMapLibrary("remove","city",std::string(64,'b'),std::string(32,'4')));server.executeLibraryTask();
    assert(server.libraryCommandError_.empty()&&server.installer_.removed==1);
    // ... but still blocks its own map, Use and policy changes.
    auto paused=city();paused.sessionId="paused-other";server.libraryMaps_.push_back(paused);
    assert(server.requestMapLibrary("remove","paused-other",std::string(64,'b'),std::string(32,'5')));server.executeLibraryTask();
    assert(server.libraryCommandError_=="library_operation_pending");
    assert(server.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'6')));server.executeLibraryTask();
    assert(server.libraryCommandError_=="library_operation_pending"&&server.installer_.selected==0&&!server.libraryManualPending_);
    // Interrupted uploads with durable progress stay resumable unless the card is full.
    request.mapOperationID=unrelated.operation;snapshot.sessionId=unrelated.session;
    snapshot.completedPayloadBytes=4096;snapshot.durableFilePrefix=1;snapshot.errorCode="stream_storage_unavailable";
    assert(server.resolveRejectedStreamOperation(request,snapshot).empty()&&phaseOf(unrelated)==operation::Phase::Receiving);
    snapshot.bytesWritten=1;snapshot.errorCode="stream_sd_full";
    assert(server.resolveRejectedStreamOperation(request,snapshot).empty()); // payload already written
    snapshot.bytesWritten=0;
    assert(server.resolveRejectedStreamOperation(request,snapshot)=="failed"&&phaseOf(unrelated)==operation::Phase::Failed);
    // Another request's identity can never resolve an operation it does not own.
    const auto foreign=id("foreign",std::string(32,'7'));admitReceiving(foreign);
    request.mapOperationID=std::string(32,'8');snapshot.sessionId="foreign";snapshot.completedPayloadBytes=0;snapshot.durableFilePrefix=0;
    assert(server.resolveRejectedStreamOperation(request,snapshot).empty()&&phaseOf(foreign)==operation::Phase::Receiving);
  }

  // N4: a refused owner dispatch backs off exponentially without revision churn,
  // then recovers once dispatch is available again.
  reset();{
    MapTransferHttpServer probe;probe.libraryMaps_={city()};probe.owner.result=ESP_ERR_INVALID_STATE;probe.owner.issued=false;
    std::vector<uint32_t> attempts;
    for(int tick=0;tick<240;++tick){ // 20 minutes of five-second GPS ticks
      clockMs+=5000;probe.considerAutomaticMap(0,0,false);probe.submitLibraryTask();
      if(probe.runQueued())attempts.push_back(clockMs);
    }
    assert(attempts.size()>=5&&attempts.size()<=9);
    for(size_t i=2;i<attempts.size();++i)assert(attempts[i]-attempts[i-1]>=attempts[i-1]-attempts[i-2]);
    assert(attempts.back()-attempts[attempts.size()-2]<=300000U+5000U);
    assert(probe.libraryRevision_==0&&probe.libraryError_.empty()&&!probe.operationStatusNotification_);
    probe.owner.result=ESP_OK;probe.installer_.currentCovers=true;
    bool recovered=false;
    for(int tick=0;tick<70&&!recovered;++tick){
      clockMs+=5000;probe.considerAutomaticMap(0,0,false);probe.submitLibraryTask();recovered=probe.runQueued();
    }
    assert(recovered&&probe.libraryAutomaticBlockKnown_&&probe.libraryRetryStreak_==0&&probe.libraryRetryAfterMs_==0);
    // A refused internal refresh stays queued for the later retry.
    MapTransferHttpServer refreshing;refreshing.libraryAction_="refresh";refreshing.owner.result=ESP_ERR_INVALID_STATE;
    refreshing.submitLibraryTask();assert(refreshing.runQueued());
    assert(refreshing.libraryAction_=="refresh"&&refreshing.libraryRetryPending()&&refreshing.libraryRevision_==1);
    refreshing.libraryRetryAfterMs_=0;refreshing.submitLibraryTask();assert(refreshing.runQueued());
    assert(refreshing.libraryRevision_==1); // identical owner failure: no repaging
  }

  // N5 and N6: failed manual/automatic switches keep the live renderer map as In
  // use, let the never-loaded version be removed, and keep the automatic policy.
  for(bool manual:{true,false}){
    reset();MapTransferHttpServer sw;liveHome(sw);
    if(manual){assert(sw.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'9')));}
    else{sw.considerAutomaticMap(0,0,false);assert(sw.libraryAction_=="automatic-select");}
    sw.executeLibraryTask();
    assert(sw.libraryManualPending_==manual);
    failRendererAndRollback(sw,city().root);
    assert(sw.rollbackSucceeded_&&sw.installer_.active.root==home().root);
    assert(sw.selectionHealth_.state=="ready"&&sw.selectionHealth_.root==home().root);
    assert(sw.mapLibraryJson(true).find("\"selectedSessionID\":\"home\"")!=std::string::npos);
    assert(manual?sw.libraryCommandError_=="library_renderer":sw.libraryCommandError_.empty());
    assert(sw.libraryAction_=="refresh");sw.executeLibraryTask();
    assert(sw.installer_.automatic&&!sw.libraryManualPending_); // failed Use keeps automatic mode
    assert(sw.requestMapLibrary("remove","city",std::string(64,'b'),std::string(32,'a')));sw.executeLibraryTask();
    assert(sw.libraryCommandError_.empty()&&sw.installer_.removed==1);
    assert(sw.requestMapLibrary("remove","home",std::string(64,'b'),std::string(32,'b')));sw.executeLibraryTask();
    assert(sw.libraryCommandError_=="library_in_use");
  }
  {
    // Rollback failure: pointer stays on the failed map while the renderer keeps
    // home. Health reports the divergence and neither root can be removed.
    reset();MapTransferHttpServer stuck;liveHome(stuck);stuck.installer_.rollbackWorks=false;
    assert(stuck.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'c')));stuck.executeLibraryTask();
    failRendererAndRollback(stuck,city().root);
    assert(!stuck.rollbackSucceeded_&&stuck.selectionHealth_.state=="rollback_failed"&&stuck.selectionHealth_.root==home().root);
    assert(stuck.mapLibraryJson(true).find("\"selectedSessionID\":\"\"")!=std::string::npos);
    stuck.executeLibraryTask(); // journal settles against the durable pointer
    for(const std::string session:{"city","home"}){
      assert(stuck.requestMapLibrary("remove",session,std::string(64,'b'),std::string(32,'d')));stuck.executeLibraryTask();
      assert(stuck.libraryCommandError_=="library_in_use");
    }
    // Unknown renderer state is not promoted by a failed switch.
    reset();MapTransferHttpServer unknown;liveHome(unknown);unknown.selectionHealth_.select(home().root,"","home","home",false);
    assert(unknown.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'e')));unknown.executeLibraryTask();
    failRendererAndRollback(unknown,city().root);
    assert(unknown.selectionHealth_.state=="unknown"&&unknown.selectionHealth_.root==home().root);
  }
  {
    // N6: a failed journal write selects nothing and keeps automatic mode.
    reset();MapTransferHttpServer journal;liveHome(journal);journal.installer_.intentWrite=false;
    assert(journal.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'f')));journal.executeLibraryTask();
    assert(journal.libraryCommandError_=="library_policy_write"&&journal.installer_.selected==0&&journal.installer_.automatic);
    // A policy-file failure after the ACK keeps the journal as the durable pin,
    // suppresses automatic switching and retries on the next library task.
    journal.installer_.intentWrite=true;journal.installer_.policyWrite=false;
    assert(journal.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'0')));journal.executeLibraryTask();
    journal.pendingMapRootTaken_=true;journal.acknowledgeActivatedMapRoot(city().root,true);journal.executeLibraryTask();
    assert(journal.libraryError_=="library_policy_write"&&journal.libraryManualPending_&&journal.libraryCommandError_.empty());
    assert(journal.mapLibraryJson(true).find("\"automatic\":false")!=std::string::npos);
    journal.libraryAutomaticBlockKnown_=false;journal.considerAutomaticMap(0,0,false);assert(journal.libraryAction_.empty());
    journal.installer_.policyWrite=true;journal.libraryAction_="refresh";journal.executeLibraryTask();
    assert(!journal.installer_.automatic&&!journal.libraryManualPending_&&journal.libraryError_.empty());
    // An explicit automatic toggle supersedes an unsettled journal.
    journal.installer_.intentRoot=city().root;journal.installer_.policyWrite=false;journal.libraryAction_="refresh";journal.executeLibraryTask();
    journal.installer_.policyWrite=true;
    assert(journal.requestMapLibrary("auto"));journal.executeLibraryTask();
    assert(journal.installer_.automatic&&!journal.libraryManualPending_&&journal.installer_.intentRoot.empty());
  }

  MapTransferHttpServer maximum;
  for(int index=0;index<32;++index){auto m=city();m.sessionId=std::string(77,'s')+std::to_string(index);m.mapId=std::string(64,'m');m.signedManifestReceipt=std::string(64,'c');m.presentation.displayName=std::string(240,'"');m.payloadBytes=512*1024*1024;maximum.libraryMaps_.push_back(m);}
  const auto paged=maximum.mapLibraryJson(true);
  assert(paged.size()+8192 < 255*128); // Conservative maximal ordinary MSTS envelope.
  assert(paged.find("\"offset\":0,\"total\":32")!=std::string::npos);
  assert(maximum.mapLibraryJson(false).size()>paged.size());
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'test.cpp'
            path.write_text(fixture)
            binary = Path(directory) / 'test'
            subprocess.run([shutil.which('g++'), '-std=c++17', '-O2', '-fstack-usage', '-Wall', '-Wextra', '-Werror',
                            '-I'+str(ROOT/'lib/map_transfer'), '-I'+str(ROOT/'lib/device_transfer'),
                            '-c', str(path), '-o', str(Path(directory) / 'controller.o')], check=True)
            subprocess.run([shutil.which('g++'), '-std=c++17', str(Path(directory) / 'controller.o'),
                            str(ROOT/'lib/device_transfer/durable_operation.cpp'), '-o', str(binary)], check=True)
            frames = []
            for usage in Path(directory).glob('*.su'):
                for line in usage.read_text().splitlines():
                    if 'executeLibraryTask' in line and all(marker not in line for marker in ('$_', 'lambda', 'clE', 'Workspace', '.cold')):
                        frames.append(int(line.split('\t')[-2]))
            self.assertEqual(len(frames), 1)
            self.assertLessEqual(frames[0], 2048)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
