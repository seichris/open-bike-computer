// Characterization of the map-root marker readers.
//
// Each lambda named `original*` is a reader's marker decision copied from the
// code before the shared classifier (map_transfer.cpp / map_stream_install.cpp
// at 9ae799e6), with fileExists/joinPath bound to a fake card. Every predicate
// of root_state::Markers must agree with it over every combination of the
// primary, ".bak" and ".tmp" copies of the markers that reader looks at.

#include "../../lib/map_transfer/map_root_state.hpp"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <set>
#include <string>
#include <vector>

using map_transfer::root_state::JournalPhase;
using map_transfer::root_state::Marker;

namespace {

constexpr const char *kStreamReadyFile = ".ready";
constexpr const char *kStreamConsumedFile = ".activation-consumed";
constexpr const char *kStreamInstallingFile = ".installing";
constexpr const char *kLibraryRetainedFile = ".library-retained";
constexpr const char *kReadyFile = kStreamReadyFile;
constexpr const char *kConsumedFile = kStreamConsumedFile;
constexpr const char *kInstallingFile = kStreamInstallingFile;

// map_transfer.cpp's joinPath, which every reader used to build marker paths.
std::string joinPath(const std::string &a, std::string b) {
  if (a.empty())
    return b;
  if (b.empty())
    return a;
  std::string result = a;
  if (result.back() != '/')
    result.push_back('/');
  if (b.front() == '/')
    b.erase(0, 1);
  result += b;
  return result;
}

struct Card {
  std::set<std::string> files;
  mutable unsigned checks = 0;
  bool exists(const std::string &path) const {
    ++checks;
    return files.count(path) != 0;
  }
};

const std::vector<Marker> kAllMarkers = {
    Marker::Installing,     Marker::Ready,    Marker::OperationPrepared,
    Marker::OperationReady, Marker::Consumed, Marker::LibraryRetained};

// Calls visit(card) for every combination of primary/.bak/.tmp copies of the
// given markers under root.
void forEachCard(const std::string &root, const std::vector<Marker> &markers,
                 const std::function<void(const Card &)> &visit) {
  std::vector<std::string> paths;
  for (const auto marker : markers) {
    const std::string path = joinPath(root, map_transfer::root_state::fileName(marker));
    paths.push_back(path);
    paths.push_back(path + ".bak");
    paths.push_back(path + ".tmp");
  }
  const std::size_t combinations = std::size_t{1} << paths.size();
  for (std::size_t mask = 0; mask < combinations; ++mask) {
    Card card;
    for (std::size_t bit = 0; bit < paths.size(); ++bit)
      if ((mask >> bit) & 1U)
        card.files.insert(paths[bit]);
    visit(card);
  }
}

auto existsOn(const Card &card) {
  return [&card](const std::string &path) { return card.exists(path); };
}

void testMarkerPathMatchesJoinPath() {
  for (const std::string root : {"", "R", "R/", "/VECTMAP/.maps/abc",
                                  "/sdcard/VECTMAP/.maps/abc/"}) {
    for (const auto marker : kAllMarkers) {
      assert(map_transfer::root_state::markerPath(root, marker) ==
             joinPath(root, map_transfer::root_state::fileName(marker)));
    }
  }
}

void testSingleMarkerRule() {
  const std::string root = "/VECTMAP/.maps/s";
  for (const auto marker : kAllMarkers) {
    const std::string name = map_transfer::root_state::fileName(marker);
    forEachCard(root, {marker}, [&](const Card &card) {
      const auto fileExists = existsOn(card);
      // Every reader checked the file and its ".bak"; `.library-retained`
      // only ever the file. No reader counted a ".tmp" copy.
      const bool original =
          marker == Marker::LibraryRetained
              ? fileExists(joinPath(root, name))
              : fileExists(joinPath(root, name)) ||
                    fileExists(joinPath(root, name) + ".bak");
      assert(map_transfer::root_state::present(fileExists, root, marker) == original);
      auto view = map_transfer::root_state::markers(fileExists, root);
      assert(view.has(marker) == original);
    });
  }
}

void testEachMarkerIsCheckedAtMostOnce() {
  const std::string root = "R";
  Card card;
  card.files.insert(joinPath(root, ".ready.bak"));
  auto view = map_transfer::root_state::markers(existsOn(card), root);
  assert(view.has(Marker::Ready));
  const unsigned afterFirst = card.checks;
  assert(afterFirst == 2); // the file, then its ".bak"
  // uploadFinished asks Ready first, which is already known: no new checks.
  assert(view.has(Marker::Ready) && view.uploadFinished());
  assert(card.checks == afterFirst);
  assert(!view.has(Marker::LibraryRetained));
  assert(card.checks == afterFirst + 1); // no ".bak" for .library-retained
  assert(!view.has(Marker::LibraryRetained));
  assert(card.checks == afterFirst + 1);
}

void testStreamRecoveryCandidate() {
  const std::string root = "/sd/VECTMAP/.maps/s";
  forEachCard(root,
              {Marker::OperationReady, Marker::OperationPrepared, Marker::Ready,
               Marker::Consumed, Marker::Installing},
              [&](const Card &card) {
    const auto regularFileExists = existsOn(card);
    // map_stream_install.cpp, boot recovery scan.
    const bool operationReady = regularFileExists(joinPath(root, ".operation-ready")) ||
                                regularFileExists(joinPath(root, ".operation-ready.bak"));
    const bool operationPrepared = regularFileExists(joinPath(root, ".operation-prepared")) ||
        regularFileExists(joinPath(root, ".operation-prepared.bak"));
    const bool ready = operationReady || regularFileExists(joinPath(root, kReadyFile)) ||
                       regularFileExists(joinPath(root, kReadyFile) + ".bak");
    const bool consumed =
        regularFileExists(joinPath(root, kConsumedFile)) ||
        regularFileExists(joinPath(root, kConsumedFile) + ".bak");
    const bool installing =
        regularFileExists(joinPath(root, kInstallingFile)) ||
        regularFileExists(joinPath(root, kInstallingFile) + ".bak");
    const bool skipped = (!ready || consumed) && !installing && !operationPrepared;

    auto view = map_transfer::root_state::markers(regularFileExists, root);
    assert(view.streamRecoveryCandidate() == !skipped);
    // The scan then picks the marker to read from these three values.
    assert(view.has(Marker::OperationPrepared) == operationPrepared);
    assert(view.has(Marker::OperationReady) == operationReady);
    assert(view.uploadFinished() == ready);
  });
}

void testActiveRootExists() {
  const std::string path = "/sd/VECTMAP/.maps/s";
  forEachCard(path, {Marker::Installing, Marker::OperationReady, Marker::Ready},
              [&](const Card &card) {
    const auto fileExists = existsOn(card);
    // map_transfer.cpp, activeRootExists.
    const bool installing =
        fileExists(joinPath(path, kStreamInstallingFile)) ||
        fileExists(joinPath(path, kStreamInstallingFile) + ".bak");
    const bool readyMarker = fileExists(joinPath(path, ".operation-ready")) ||
        fileExists(joinPath(path, ".operation-ready.bak")) ||
        fileExists(joinPath(path, kStreamReadyFile)) ||
        fileExists(joinPath(path, kStreamReadyFile) + ".bak");

    auto view = map_transfer::root_state::markers(fileExists, path);
    assert(view.unusableActiveRoot() == (installing && !readyMarker));
    assert(view.uploadFinished() == readyMarker);
  });
}

void testReadInstalledMap() {
  const std::string path = "/sd/VECTMAP/.maps/s";
  forEachCard(path, {Marker::OperationPrepared, Marker::Ready, Marker::OperationReady},
              [&](const Card &card) {
    const auto fileExists = existsOn(card);
    // map_transfer.cpp, readInstalledMap.
    const bool uncommitted = fileExists(joinPath(path, ".operation-prepared")) ||
                             fileExists(joinPath(path, ".operation-prepared.bak"));
    const bool stream = fileExists(joinPath(path, kStreamReadyFile)) ||
        fileExists(joinPath(path, ".operation-ready")) ||
        fileExists(joinPath(path, kStreamReadyFile) + ".bak") ||
        fileExists(joinPath(path, ".operation-ready.bak"));

    auto view = map_transfer::root_state::markers(fileExists, path);
    assert(view.has(Marker::OperationPrepared) == uncommitted);
    assert(view.uploadFinished() == stream);
  });
}

void testPruneObsoleteInstalledMaps() {
  const std::string candidatePath = "/sd/VECTMAP/.maps/s";
  forEachCard(candidatePath,
              {Marker::Consumed, Marker::Ready, Marker::OperationReady,
               Marker::LibraryRetained, Marker::Installing},
              [&](const Card &card) {
    const auto fileExists = existsOn(card);
    for (const bool keepInstalling : {false, true}) {
      // map_transfer.cpp, pruneObsoleteInstalledMaps (marker terms only; the
      // ready metadata read and the installed receipt are unchanged code).
      const bool consumed =
          fileExists(joinPath(candidatePath, kStreamConsumedFile)) ||
          fileExists(joinPath(candidatePath, kStreamConsumedFile) + ".bak");
      const bool freshReadyMarkers =
          !consumed &&
          (fileExists(joinPath(candidatePath, kStreamReadyFile)) ||
           fileExists(joinPath(candidatePath, kStreamReadyFile) + ".bak") ||
           fileExists(joinPath(candidatePath, ".operation-ready")) ||
           fileExists(joinPath(candidatePath, ".operation-ready.bak")));
      const bool keptByMarkers =
          consumed || fileExists(joinPath(candidatePath, kLibraryRetainedFile)) ||
          (keepInstalling &&
           (fileExists(joinPath(candidatePath, kStreamInstallingFile)) ||
            fileExists(joinPath(candidatePath, kStreamInstallingFile) + ".bak")));

      auto view = map_transfer::root_state::markers(fileExists, candidatePath);
      assert(view.has(Marker::Consumed) == consumed);
      assert((!view.has(Marker::Consumed) && view.uploadFinished()) == freshReadyMarkers);
      assert(view.pruneKeepsByMarkers(keepInstalling) == keptByMarkers);
    }
  });
}

void testDiscardAllUnselectedStreamMaps() {
  const std::string root = "/sd/VECTMAP/.maps/s";
  forEachCard(root,
              {Marker::Consumed, Marker::LibraryRetained, Marker::Ready,
               Marker::Installing},
              [&](const Card &card) {
    const auto fileExists = existsOn(card);
    // map_transfer.cpp, discardAllUnselectedStreamMaps.
    const bool completed = fileExists(joinPath(root, kStreamConsumedFile)) ||
        fileExists(joinPath(root, kStreamConsumedFile) + ".bak") ||
        fileExists(joinPath(root, kLibraryRetainedFile));
    const bool streamState =
        fileExists(joinPath(root, kStreamReadyFile)) ||
        fileExists(joinPath(root, kStreamReadyFile) + ".bak") ||
        fileExists(joinPath(root, kStreamInstallingFile)) ||
        fileExists(joinPath(root, kStreamInstallingFile) + ".bak");

    auto view = map_transfer::root_state::markers(fileExists, root);
    assert(view.discardableLegacyStreamState() == (!completed && streamState));
    assert(view.completedLibraryVersion() == completed);
  });
}

void testSettleSelectionStreamMaps() {
  const std::string root = "/sd/VECTMAP/.maps/s";
  forEachCard(root, {Marker::Consumed, Marker::Ready, Marker::OperationReady},
              [&](const Card &card) {
    const auto fileExists = existsOn(card);
    for (const bool pendingNamesRoot : {false, true}) {
      // map_transfer.cpp, settleSelectionStreamMaps. `.operation-ready` is in
      // the combinations to show it never changes the decision.
      const bool consumed = fileExists(joinPath(root, kStreamConsumedFile)) ||
                            fileExists(joinPath(root, kStreamConsumedFile) + ".bak");
      const bool skipped =
          (consumed && !pendingNamesRoot) ||
          (!fileExists(joinPath(root, kStreamReadyFile)) &&
           !fileExists(joinPath(root, kStreamReadyFile) + ".bak"));

      auto view = map_transfer::root_state::markers(fileExists, root);
      assert(view.unsettledLegacyUpload(pendingNamesRoot) == !skipped);
      assert(view.has(Marker::Consumed) == consumed);
    }
  });
}

void testSingleMarkerReaders() {
  const std::string root = "/sd/VECTMAP/.maps/s";
  forEachCard(root,
              {Marker::OperationPrepared, Marker::Consumed, Marker::LibraryRetained,
               Marker::Ready, Marker::OperationReady},
              [&](const Card &card) {
    const auto fileExists = existsOn(card);
    auto view = map_transfer::root_state::markers(fileExists, root);
    // cancelOperationStaging, preparationBlocksActivation.
    assert(view.has(Marker::OperationPrepared) ==
           (fileExists(joinPath(root, ".operation-prepared")) ||
            fileExists(joinPath(root, ".operation-prepared.bak"))));
    // cancelOperationStaging, discardUnselectedStreamMap, keepSelectedStreamMap,
    // resolvePendingStreamActivation.
    assert(view.has(Marker::Consumed) ==
           (fileExists(joinPath(root, kStreamConsumedFile)) ||
            fileExists(joinPath(root, kStreamConsumedFile) + ".bak")));
    // discardUnselectedStreamMap, keepSelectedStreamMap, promotePreparedOperation.
    assert(view.has(Marker::LibraryRetained) ==
           fileExists(joinPath(root, kLibraryRetainedFile)));
    // discardIncompleteStreamMap: only the legacy marker protects a root.
    assert(view.has(Marker::Ready) ==
           (fileExists(joinPath(root, kStreamReadyFile)) ||
            fileExists(joinPath(root, kStreamReadyFile) + ".bak")));
    // readStreamMapMetadata: a prepared read, or a committed operation marker.
    for (const bool prepared : {false, true}) {
      const bool operationReady = prepared ||
          fileExists(joinPath(root, ".operation-ready")) ||
          fileExists(joinPath(root, ".operation-ready.bak"));
      assert((prepared || map_transfer::root_state::present(
                              fileExists, root, Marker::OperationReady)) ==
             operationReady);
    }
  });
}

void testJournalPhases() {
  const std::vector<std::string> values = {
      "",      "publishing", "ready",     "committed", "Ready",  "READY",
      " ready", "ready ",    "commit",    "published", "idle",   "x"};
  for (const auto &phase : values) {
    // recoverStreamActivationTransaction and the archive journal recovery.
    const bool streamAccepted = phase == "ready" || phase == "committed";
    const bool archiveAccepted =
        phase == "publishing" || phase == "ready" || phase == "committed";
    const JournalPhase parsed = map_transfer::root_state::parseJournalPhase(phase);
    assert(map_transfer::root_state::streamJournalAccepts(parsed) == streamAccepted);
    assert(map_transfer::root_state::archiveJournalAccepts(parsed) == archiveAccepted);
  }
  for (const auto phase : {JournalPhase::Publishing, JournalPhase::Ready,
                           JournalPhase::Committed}) {
    // Writers emit exactly these strings, and they parse back.
    assert(map_transfer::root_state::parseJournalPhase(
               map_transfer::root_state::journalPhaseName(phase)) == phase);
  }
  assert(std::string(map_transfer::root_state::journalPhaseName(JournalPhase::Publishing)) == "publishing");
  assert(std::string(map_transfer::root_state::journalPhaseName(JournalPhase::Ready)) == "ready");
  assert(std::string(map_transfer::root_state::journalPhaseName(JournalPhase::Committed)) == "committed");
}

} // namespace

int main() {
  testMarkerPathMatchesJoinPath();
  testSingleMarkerRule();
  testEachMarkerIsCheckedAtMostOnce();
  testStreamRecoveryCandidate();
  testActiveRootExists();
  testReadInstalledMap();
  testPruneObsoleteInstalledMaps();
  testDiscardAllUnselectedStreamMaps();
  testSettleSelectionStreamMaps();
  testSingleMarkerReaders();
  testJournalPhases();
  return 0;
}
