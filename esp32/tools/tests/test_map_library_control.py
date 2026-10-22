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
        fixture = r'''
#include <algorithm>
#include <cassert>
#include <cmath>
#include <memory>
#include <new>
#include <string>
#include <vector>
#include "map_transfer.hpp"
#include "map_activation_workspace.hpp"
#include "durable_operation.hpp"
#include "map_selection_health.hpp"
constexpr int ESP_OK=0,ESP_ERR_TIMEOUT=1;
uint32_t clockMs=100;
uint32_t millis(){return clockMs;}
namespace ui_scheduler {enum class WakeReason{Transfer};void notify(WakeReason){}}
namespace map_transfer {
namespace operation = device_transfer::durable_operation;
struct MapOperationStorage:operation::Storage {
  static std::vector<uint8_t> slots[2];
  MapOperationStorage(const std::string&){}
  bool read(unsigned n,std::vector<uint8_t>&out)override{out=slots[n];return true;}
  bool writeDurable(unsigned n,const std::vector<uint8_t>&in)override{slots[n]=in;return true;}
};
std::vector<uint8_t> MapOperationStorage::slots[2];
struct Installer {
  bool automatic=true,currentCovers=false,candidateCovers=true,throwAfterSelect=false,policyWrite=true;
  int selected=0,scans=0,selectAttempts=0;bool throwRefresh=false;std::string selectionError;
  ActiveMapSelection active;
  bool automaticMapSelection(){return automatic;}
  bool setAutomaticMapSelection(bool value){if(policyWrite)automatic=value;return policyWrite;}
  InstallStatus readActiveMap(ActiveMapSelection&out){
    if(selected && throwAfterSelect){throwAfterSelect=false;throw std::bad_alloc();}
    out=active;return {true,"ok",""};
  }
  bool mapRootHasBlock(const std::string&,int32_t,int32_t){return currentCovers;}
  bool installedMapCovers(const InstalledMap&,int32_t,int32_t){return candidateCovers;}
  InstallStatus selectInstalledMap(const std::string&s,const std::string&){
    ++selectAttempts;
    if(!selectionError.empty())return {false,selectionError,""};
    ++selected;active.root="/VECTMAP/.maps/"+s;active.sessionId=s;active.mapId="city";
    return {true,"selected",""};
  }
  InstallStatus removeInstalledMap(const std::string&,const std::string&){return {true,"ok",""};}
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
struct Owner {bool issued=false;int result=ESP_ERR_TIMEOUT;
  int runMapActivation(void (*)(void*,const char*,bool),void*,const std::string&,bool,bool*out){*out=issued;return result;}
};
class MapTransferHttpServer {
public:
  struct StateGuard {StateGuard(const MapTransferHttpServer&){}};
  struct OperationStoreGuard {OperationStoreGuard(const MapTransferHttpServer&){}};
  enum class RollbackKind{None,Transfer};
  Server server;Server*transferServer_=&server;Installer installer_;Activation activationState_;
  Owner owner;Owner*operationOwner_=&owner;
  std::string storageRoot_="/sdcard",operationDeviceID_=std::string(32,'a');
  MapSelectionHealth selectionHealth_;
  std::vector<InstalledMap> libraryMaps_;
  std::string libraryAction_,librarySession_,libraryReceipt_,libraryRequestID_,libraryCommandID_,libraryCommandError_,libraryError_;
  std::vector<std::string> libraryRejectedSessions_;
  bool libraryKnown_=true,libraryAutomatic_=true,librarySubmitted_=false,librarySelectionStarted_=false;
  uint32_t libraryRevision_=0,libraryRetryAfterMs_=0;
  uint64_t libraryAutomaticBlock_=0,pendingCommitGrant_=0;
  bool libraryAutomaticBlockKnown_=false;
  size_t libraryPageOffset_=0;
  int32_t libraryLatitudeE7_=0,libraryLongitudeE7_=0;
  std::string pendingMapRoot_,pendingMapSessionId_,pendingMapId_,pendingMapOperationID_,pendingMapLibraryCommandID_;
  std::string terminalOperationID_,terminalSessionID_,terminalMapID_,rollbackOperationID_,rollbackSession_;
  bool terminalAutomaticExit_=false,terminalFailed_=false,rollbackAutomaticExit_=false,rollbackSubmitted_=false;
  bool pendingMapRootTaken_=false,pendingRendererAcknowledgement_=false,pendingRendererAutomaticExit_=false,operationStatusNotification_=false;
  RollbackKind rollbackKind_=RollbackKind::None;
  bool requestMapLibrary(const std::string&,const std::string&="",const std::string&="",const std::string&="");
  void considerAutomaticMap(int32_t,int32_t,bool);
  void lockState(){} void unlockState(){}
  void finishActivation(std::string a,std::string b,std::string c,std::string d){activationState_.finish(a,b,c,d);}
  void releaseCommitGrant(){} void requestAutomaticExit(){}
  void acknowledgeActivatedMapRoot(const std::string&,bool);
  void executeLibraryTask();
  void recoverLibraryTask(const char*);
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
        fixture += between(source, 'void MapTransferHttpServer::considerAutomaticMap(', 'void MapTransferHttpServer::submitLibraryTask(')
        fixture += between(source, 'void MapTransferHttpServer::libraryTask(', 'void MapTransferHttpServer::executeLibraryTask()')
        fixture += between(source, 'void MapTransferHttpServer::executeLibraryTask()', 'void MapTransferHttpServer::releaseCommitGrant(')
        fixture += between(source, 'void MapTransferHttpServer::acknowledgeActivatedMapRoot(', 'std::string MapTransferHttpServer::selectionOperationID(')
        fixture += r'''
InstalledMap city(){InstalledMap m;m.sessionId="city";m.mapId="city";m.root="/VECTMAP/.maps/city";m.manifestReceipt=std::string(64,'b');m.presentation.hasBoundsE7=true;m.presentation.boundsE7={-1000000,-1000000,1000000,1000000};return m;}
void reset(){for(auto&s:MapOperationStorage::slots)s.clear();clockMs=100;}
operation::Identity id(){return {std::string(32,'a'),std::string(32,'1'),std::string(64,'b'),std::string(64,'c'),std::string(64,'d'),100,"paused","map"};}
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
    assert(s.installer_.automatic==pending);
    assert(s.libraryCommandID_==std::string(32,'f'));
    assert((s.libraryCommandError_=="library_operation_pending")==pending);
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
  assert(s.installer_.automatic&&!s.pendingRendererAcknowledgement_);
  s.librarySubmitted_=true;assert(!s.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'f')));
  assert(s.libraryCommandID_==std::string(32,'f')&&s.libraryCommandError_=="library_busy");
  s.librarySubmitted_=false;s.installer_.selectionError.clear();s.installer_.policyWrite=false;
  assert(s.requestMapLibrary("select","city",std::string(64,'b'),std::string(32,'d')));s.executeLibraryTask();
  assert(s.pendingRendererAcknowledgement_&&s.libraryCommandError_=="library_policy_write");
  for(bool issued:{false,true}) {
    MapTransferHttpServer pending;pending.librarySubmitted_=true;pending.libraryAction_="select";pending.libraryRequestID_=std::string(32,'a');pending.owner.issued=issued;
    MapTransferHttpServer::libraryTask(&pending);
    assert(pending.librarySubmitted_==issued);
    if(!issued)assert(pending.libraryCommandError_=="library_owner"&&pending.libraryRevision_==1);
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
