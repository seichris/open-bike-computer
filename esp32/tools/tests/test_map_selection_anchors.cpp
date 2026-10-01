#define main map_stream_install_fixture_main
#include "test_map_stream_install.cpp"
#undef main
#include "../../lib/map_transfer/map_selection_anchor.hpp"

namespace {
namespace anchor = map_transfer::selection_anchor;
void testAnchorEnvelopeRejectsCorruptionAndUnknownSchemas() {
  anchor::Record record{1,"device-a","operation-a","{\"mapId\":\"known\"}\n"}, restored;
  auto bytes=anchor::encode(record);
  assert(anchor::decode(bytes,restored)==anchor::Decode::Valid);
  assert(restored.sequence==1 && restored.selection==record.selection);
  for(size_t i=0;i<bytes.size();++i) {
    auto damaged=bytes; damaged[i]^=1;
    assert(anchor::decode(damaged,restored)!=anchor::Decode::Valid);
  }
  auto future=bytes; future[future.find("/1")+1]='2';
  assert(anchor::decode(future,restored)==anchor::Decode::Unsupported);
  record.sequence=UINT64_MAX; assert(anchor::decode(anchor::encode(record),restored)==anchor::Decode::Valid);
  record.device="bad\nheader"; assert(anchor::encode(record).empty());
}

void testAnchorsRestoreOnlyExactVerifiedPredecessors() {
  const auto root=tempRoot();
  const auto active=root+"/VECTMAP/active-map.json";
  const auto slot0=root+"/VECTMAP/.selection-anchor-0";
  const auto slot1=root+"/VECTMAP/.selection-anchor-1";
  prepareReadyRoot(root,"previous"); MapTransferInstaller installer(root);
  size_t progress=0;
  installer.setStorageProgressCallback([](void *context) { ++*static_cast<size_t*>(context); }, &progress);
  assert(installer.activateReadyStreamMap("previous").ok);
  const auto previousJson=readFile(active);
  prepareReadyRoot(root,"candidate"); assert(installer.activateReadyStreamMap("candidate").ok);
  const auto candidateJson=readFile(active);
  assert(progress>0); // Actual hash IO, not request/status polling, reports progress.
  anchor::Record first;
  assert(anchor::decode(readFile(slot0),first)==anchor::Decode::Valid);
  assert(first.sequence==1 && first.selection==previousJson);
  assert(!exists(slot1));
  assert(::unlink(active.c_str())==0);
  for(unsigned pass=0;pass<3;++pass) assert(installer.recoverInterruptedActivation().ok);
  assert(readFile(active)==previousJson); // Full canonical bytes, including all previous/target fields.

  // One corrupt slot can never hide the independently valid alternate.
  anchor::Record second=first; second.sequence=2;
  writeFile(slot1,anchor::encode(second)); writeFile(slot0,"torn");
  assert(::unlink(active.c_str())==0);
  assert(installer.recoverInterruptedActivation().ok && readFile(active)==previousJson);

  // Unknown schema rejects recovery even beside a valid old slot; preserve evidence.
  auto future=anchor::encode(first); future[future.find("/1")+1]='2'; writeFile(slot0,future);
  assert(::unlink(active.c_str())==0);
  assert(installer.recoverInterruptedActivation().code=="selection_anchor_schema");
  assert(installer.recoverPendingStreamActivation().code=="selection_anchor_schema");
  assert(!exists(active) && readFile(slot0)==future);

  // A future oversized slot cannot be silently ignored beside a valid slot.
  writeFile(slot0,std::string(anchor::kMaximumBytes+1,'x'));
  assert(installer.recoverInterruptedActivation().code=="selection_anchor_read");
  assert(!exists(active));

  // Conflicting same-sequence records are not an invitation to choose a root.
  first.sequence=second.sequence;
  writeFile(slot0,anchor::encode(first)); second.selection=candidateJson;
  writeFile(slot1,anchor::encode(second));
  assert(installer.recoverInterruptedActivation().code=="selection_anchor_conflict");
  assert(!exists(active));

  // A moved card cannot supply another device's recovery authority.
  second=first; second.device="different-device";
  writeFile(slot1,anchor::encode(second));
  assert(installer.recoverInterruptedActivation().code=="selection_anchor_device");
  assert(!exists(active));

  // A checksum authenticates metadata consistency, not map bytes. Rehash the
  // exact referenced payload; never restore a corrupt root just because the
  // marker/receipt files and unrelated ready candidates look plausible.
  writeFile(slot1,anchor::encode(first));
  writeFile(root+"/VECTMAP/.maps/previous/+0000+0000/0.fmb","damaged");
  assert(installer.recoverInterruptedActivation().code=="selection_anchor_invalid");
  assert(!exists(active));
  std::filesystem::remove_all(root);
}

void testAlternationRetainsFullRollbackRoots() {
  const auto root=tempRoot(); MapTransferInstaller installer(root);
  for(const auto *session:{"one","two","three","four"}) {
    prepareReadyRoot(root,session); assert(installer.activateReadyStreamMap(session).ok);
    assert(installer.pruneObsoleteInstalledMaps());
  }
  anchor::Record a,b;
  assert(anchor::decode(readFile(root+"/VECTMAP/.selection-anchor-0"),a)==anchor::Decode::Valid);
  assert(anchor::decode(readFile(root+"/VECTMAP/.selection-anchor-1"),b)==anchor::Decode::Valid);
  assert(a.sequence==3 && b.sequence==2);
  assert(a.selection.find("\"sessionId\":\"three\"")!=std::string::npos);
  assert(a.selection.find("\"previousSessionId\":\"two\"")!=std::string::npos);
  assert(exists(root+"/VECTMAP/.maps/one/+0000+0000/0.fmb"));
  assert(::unlink((root+"/VECTMAP/active-map.json").c_str())==0);
  assert(installer.recoverInterruptedActivation().ok);
  ActiveMapSelection selected; assert(installer.readActiveMap(selected).ok);
  assert(selected.sessionId=="three" && selected.previousSessionId=="two");
  std::filesystem::remove_all(root);
}
void testAlternatingSlotOverwriteCrashCuts() {
  const auto baseline=tempRoot(); MapTransferInstaller initial(baseline);
  for(const auto *session:{"one","two","three"}) {
    prepareReadyRoot(baseline,session); assert(initial.activateReadyStreamMap(session).ok);
  }
  prepareReadyRoot(baseline,"four");
  const auto clone=[&]() {
    const auto root=tempRoot();
    std::filesystem::copy(baseline,root,std::filesystem::copy_options::recursive |
                          std::filesystem::copy_options::overwrite_existing);
    return root;
  };
  const auto probeRoot=clone(); MutationCrashInstaller probe(probeRoot);
  assert(probe.activateReadyStreamMap("four").ok);
  for(size_t cut=0;cut<probe.mutations;++cut) {
    const auto root=clone(); MutationCrashInstaller interrupted(root,cut);
    bool reached=false;
    try { (void)interrupted.activateReadyStreamMap("four"); }
    catch(const SimulatedInstallerPowerCut &) { interrupted.restoreCutImage(); reached=true; }
    assert(reached);
    for(size_t pass=0;pass<3;++pass) {
      MutationCrashInstaller recovery(root,pass);
      try { (void)recovery.recoverInterruptedActivation(); }
      catch(const SimulatedInstallerPowerCut &) { recovery.restoreCutImage(); }
    }
    MapTransferInstaller recovery(root);
    for(unsigned pass=0;pass<3;++pass) (void)recovery.recoverInterruptedActivation();
    ActiveMapSelection active; assert(recovery.readActiveMap(active).ok);
    assert(active.sessionId=="three" || active.sessionId=="four");
    assert(readFile(root+active.root+"/+0000+0000/0.fmb")==kPayload0);
    std::filesystem::remove_all(root);
  }
  std::cout << "anchor alternating-slot overwrite cuts=" << probe.mutations << "\n";
  std::filesystem::remove_all(probeRoot); std::filesystem::remove_all(baseline);
}

}
int main() {
  testAnchorEnvelopeRejectsCorruptionAndUnknownSchemas();
  testAnchorsRestoreOnlyExactVerifiedPredecessors();
  testAlternationRetainsFullRollbackRoots();
  testAlternatingSlotOverwriteCrashCuts();
  std::cout << "selection anchor validation/recovery tests passed\n";
}
