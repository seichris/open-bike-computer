#define main map_stream_install_fixture_main
#include "test_map_stream_install.cpp"
#undef main
#include "../../lib/map_transfer/map_selection_anchor.hpp"
#include <cstring>

#if defined(MAP_RECOVERY_INSTRUMENT_FUNCTIONS)
namespace {
void *recoveryEntry = nullptr;
bool observeRecovery = false;
unsigned recoveryDepth = 0;
unsigned maximumRecoveryDepth = 0;
}
extern "C" __attribute__((no_instrument_function))
void __cyg_profile_func_enter(void *function, void *) {
  if (observeRecovery && function == recoveryEntry) {
    ++recoveryDepth;
    if (recoveryDepth > maximumRecoveryDepth)
      maximumRecoveryDepth = recoveryDepth;
  }
}
extern "C" __attribute__((no_instrument_function))
void __cyg_profile_func_exit(void *function, void *) {
  if (observeRecovery && function == recoveryEntry)
    --recoveryDepth;
}
#endif

namespace {
namespace anchor = map_transfer::selection_anchor;
class TornSelectionWriteInstaller : public MapTransferInstaller {
public:
  explicit TornSelectionWriteInstaller(const std::string &root)
      : MapTransferInstaller(root), root_(root) {}
protected:
  bool writeTextFileAtomic(const std::string &path,
                           const std::string &text) const override {
    if (failNextSelection_ && path == root_ + "/VECTMAP/active-map.json") {
      failNextSelection_ = false;
      ::unlink(path.c_str());
      writeFile(root_ + "/VECTMAP/.activation-transaction.json", "{torn");
      return false;
    }
    return MapTransferInstaller::writeTextFileAtomic(path, text);
  }
private:
  std::string root_;
  mutable bool failNextSelection_ = true;
};

void testFailedCanonicalWriteRecoversVerifiedPredecessor() {
  const auto root = tempRoot();
  MapTransferInstaller initial(root);
  prepareReadyRoot(root, "previous");
  assert(initial.activateReadyStreamMap("previous").ok);
  prepareReadyRoot(root, "candidate");
  TornSelectionWriteInstaller installer(root);
#if defined(MAP_RECOVERY_INSTRUMENT_FUNCTIONS)
  const auto member = &MapTransferInstaller::recoverInterruptedActivation;
  std::memcpy(&recoveryEntry, &member, sizeof(recoveryEntry));
  recoveryDepth = maximumRecoveryDepth = 0;
  observeRecovery = true;
#endif
  std::string firstRecovery;
  const auto result = installer.recoverPendingStreamActivation({},
      [](void *context, const char *code) { *static_cast<std::string *>(context) = code; }, &firstRecovery);
  assert(firstRecovery == "stream_active_write");
#if defined(MAP_RECOVERY_INSTRUMENT_FUNCTIONS)
  observeRecovery = false;
  assert(recoveryDepth == 0 && maximumRecoveryDepth == 1);
#endif
  // Recovery restores availability, and cannot turn the failed replacement
  // into an installed result or destroy the still-verifiable candidate.
  assert(!result.ok && result.code == "stream_active_write");
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.sessionId == "previous");
  assert(readFile(root + selected.root + "/+0000+0000/0.fmb") == kPayload0);
  assert(exists(root + "/VECTMAP/.maps/candidate/.ready"));
  std::filesystem::remove_all(root);
}

void testInvalidJournalAndMissingSelectionRecoverWithoutRecursion() {
  const auto root = tempRoot();
  MapTransferInstaller installer(root);
  prepareReadyRoot(root, "previous");
  assert(installer.activateReadyStreamMap("previous").ok);
  prepareReadyRoot(root, "candidate");
  assert(installer.activateReadyStreamMap("candidate").ok);
  assert(::unlink((root + "/VECTMAP/active-map.json").c_str()) == 0);
  writeFile(root + "/VECTMAP/.activation-transaction.json", "{torn");

#if defined(MAP_RECOVERY_INSTRUMENT_FUNCTIONS)
  // Clang/GCC on the supported Darwin/Linux hosts use the Itanium member
  // pointer ABI: a nonvirtual entry address followed by a this adjustment.
  // Instrument the actual production call, rather than an imitation of it.
  const auto member = &MapTransferInstaller::recoverInterruptedActivation;
  static_assert(sizeof(member) == 2 * sizeof(void *));
  std::memcpy(&recoveryEntry, &member, sizeof(recoveryEntry));
  recoveryDepth = maximumRecoveryDepth = 0;
  observeRecovery = true;
#endif
  const auto result = installer.recoverInterruptedActivation();
#if defined(MAP_RECOVERY_INSTRUMENT_FUNCTIONS)
  observeRecovery = false;
  assert(recoveryDepth == 0);
  assert(maximumRecoveryDepth == 1);
#endif
  assert(result.ok);
  ActiveMapSelection selected;
  assert(installer.readActiveMap(selected).ok);
  assert(selected.sessionId == "previous");
  assert(selected.previousSessionId.empty());
  assert(readFile(root + selected.root + "/+0000+0000/0.fmb") == kPayload0);
  assert(!exists(root + "/VECTMAP/.activation-transaction.json"));
  std::filesystem::remove_all(root);
}
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
  testInvalidJournalAndMissingSelectionRecoverWithoutRecursion();
  testFailedCanonicalWriteRecoversVerifiedPredecessor();
  testAnchorEnvelopeRejectsCorruptionAndUnknownSchemas();
  testAnchorsRestoreOnlyExactVerifiedPredecessors();
  testAlternationRetainsFullRollbackRoots();
  testAlternatingSlotOverwriteCrashCuts();
  std::cout << "selection anchor validation/recovery tests passed\n";
}
