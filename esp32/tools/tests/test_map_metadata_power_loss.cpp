// Reuse real signed-stream fixture construction without duplicating its crypto
// or running the other suite's main. This translation unit owns only new tests.
#define main map_stream_install_fixture_main
#include "test_map_stream_install.cpp"
#undef main
#include "storage_power_shadow.hpp"
#include <numeric>

namespace {
namespace shadow = storage_power_shadow;
class ShadowInstaller final : public MapTransferInstaller {
public:
  ShadowInstaller(const std::string &root, bool fat)
      : MapTransferInstaller(root), state(shadow::readImage(root)), root_(root), fat_(fat) {}
  void observe(const std::string &name) const { state.observe(shadow::readImage(root_), name); }
  mutable shadow::Shadow state;
protected:
  void storageMutationBoundary(const char *operation, const std::string &path, bool after) const override {
    if (after) observe(std::string(operation) + ":" + path.substr(root_.size()));
  }
  int renameStoragePath(const char *from, const char *to) const override {
    if (fat_ && exists(to)) return -1;
    return MapTransferInstaller::renameStoragePath(from, to);
  }
private:
  std::string root_;
  bool fat_;
};

struct Counts { size_t schedules=0, unavailable=0, invalid=0, previousLost=0, recoveryCuts=0; };
bool payload(const std::string &path) {
  return path.size() >= 4 && (path.substr(path.size()-4)==".fmb" || path.substr(path.size()-4)==".fmp");
}

void recover(ShadowInstaller &installer) {
  (void)installer.recoverInterruptedActivation();
  (void)installer.recoverPendingStreamActivation();
}

void evaluate(const shadow::Image &crashImage, const shadow::Image &baseline,
              bool replacement, bool fat, const std::string &label, Counts &counts) {
  const auto root=tempRoot();
  shadow::restoreImage(root,crashImage);
  std::string recoverySchedule;
  // Recovery can lose its own metadata too. Three consecutive reboot passes
  // each lose one changed mutation, cycling the selected index deterministically.
  for(size_t pass=0;pass<3;++pass) {
    ShadowInstaller boot(root,fat); recover(boot);
    std::vector<size_t> order(boot.state.pending.size());
    std::iota(order.begin(),order.end(),0);
    if(!order.empty()) {
      const size_t lost=pass%order.size();
      recoverySchedule += " recovery["+std::to_string(pass)+"]lost["+std::to_string(lost)+"]="+boot.state.pending[lost].name;
      order.erase(order.begin()+lost); ++counts.recoveryCuts;
    }
    shadow::restoreImage(root,boot.state.crash(order));
  }
  ShadowInstaller stable(root,fat);
  for(unsigned pass=0;pass<3;++pass) recover(stable);
  ActiveMapSelection selected;
  const auto status=stable.readActiveMap(selected);
  std::string failure;
  if(replacement && !status.ok) { ++counts.unavailable; failure="selection_unavailable"; }
  if(status.ok) {
    bool valid=(selected.sessionId=="candidate" || (replacement && selected.sessionId=="previous")) &&
               selected.root=="/VECTMAP/.maps/"+selected.sessionId;
    size_t checkedPayloads=0;
    const auto receipt=baseline.find(selected.root.substr(1)+"/.verified.sha256");
    valid=valid && receipt!=baseline.end() && selected.manifestReceipt==receipt->second;
    const auto current=shadow::readImage(root);
    for(const auto &file:baseline) {
      if(payload(file.first) && file.first.find(selected.root.substr(1)+"/")==0) {
        ++checkedPayloads;
        auto found=current.find(file.first);
        valid=valid && found!=current.end() && found->second==file.second;
      }
    }
    valid=valid && checkedPayloads>0;
    if(!valid) { ++counts.invalid; failure="unverified_selection"; }
  }
  if(replacement) {
    const auto current=shadow::readImage(root);
    bool intact=true;
    for(const auto &file:baseline) if(payload(file.first) && file.first.find("VECTMAP/.maps/previous/")==0) {
      auto found=current.find(file.first);
      intact=intact && found!=current.end() && found->second==file.second;
    }
    if(!intact) { ++counts.previousLost; failure="previous_payload_lost"; }
  }
  ++counts.schedules;
  if(!failure.empty() && counts.unavailable+counts.invalid+counts.previousLost<=8)
    std::cout << "COUNTEREXAMPLE " << failure << " " << label << recoverySchedule << "\n";
  std::filesystem::remove_all(root);
}

void runMetadataWindows(Counts &counts) {
  for(bool fat:{false,true}) for(bool replacement:{false,true}) {
    const auto root=tempRoot();
    if(replacement) { prepareReadyRoot(root,"previous"); MapTransferInstaller old(root); assert(old.activateReadyStreamMap("previous").ok); }
    prepareReadyRoot(root,"candidate");
    const auto baseline=shadow::readImage(root);
    ShadowInstaller trace(root,fat); assert(trace.activateReadyStreamMap("candidate").ok);
    const auto &events=trace.state.pending;
    assert(!events.empty());
    const std::string scenario=std::string(fat?"fat":"posix")+(replacement?" replacement":" first");
    std::cout << "SHADOW_WINDOW " << scenario << " mutations=" << events.size() << " no_directory_fence\n";
    for(size_t index=0;index<events.size();++index)
      std::cout << "SHADOW_MUTATION " << scenario << " [" << index << "] " << events[index].name << "\n";
    // Every named effect boundary: all tail writes can be lost at this cut.
    for(size_t prefix=0;prefix<=events.size();++prefix) {
      std::vector<size_t> order(prefix); std::iota(order.begin(),order.end(),0);
      evaluate(trace.state.crash(order),baseline,replacement,fat,scenario+" prefix="+std::to_string(prefix),counts);
      for(size_t lost=0;lost<prefix;++lost) {
        auto missing=order; missing.erase(missing.begin()+lost);
        evaluate(trace.state.crash(missing),baseline,replacement,fat,scenario+" prefix="+std::to_string(prefix)+" lost["+std::to_string(lost)+"]="+events[lost].name,counts);
      }
      // Exhaust each one-adjacent-swap permutation within this unfenced window;
      // do not claim arbitrary permutations, sector tears, or controller models.
      for(size_t swapped=0;swapped+1<prefix;++swapped) {
        auto reordered=order; std::swap(reordered[swapped],reordered[swapped+1]);
        evaluate(trace.state.crash(reordered),baseline,replacement,fat,scenario+" prefix="+std::to_string(prefix)+" swap["+std::to_string(swapped)+"]="+events[swapped].name+"<->"+events[swapped+1].name,counts);
      }
    }
    std::filesystem::remove_all(root);
  }
}
}
int main(int argc,char **argv) {
  // Prove the shadow's control boundary, without assigning this hypothetical
  // fence to an ESP32/FAT flush/close or immediate read-back.
  shadow::Shadow control({{"record","old"}});
  control.observe({{"record","new"}},"write");
  assert(control.visible.at("record")=="new" && control.crash({}).at("record")=="old");
  control.provenFence(); assert(control.crash({}).at("record")=="new");
  Counts counts; runMetadataWindows(counts);
  std::cout << "SHADOW_RESULT schedules="<<counts.schedules<<" recovery_cuts="<<counts.recoveryCuts
            <<" unavailable="<<counts.unavailable<<" invalid="<<counts.invalid<<" previous_lost="<<counts.previousLost<<"\n";
  // Default is a qualification gate, not a success claim over counterexamples.
  // --observe permits collecting known limitations while leaving strict CI/
  // production qualification red until the violated storage assumptions close.
  const bool observe=argc==2 && std::string(argv[1])=="--observe";
  return !observe && (counts.unavailable || counts.invalid || counts.previousLost) ? 1 : 0;
}
