#pragma once

// A map root's lifecycle on the card is the set of marker files inside it.
// This header is the one place that names them and decides which copies count.
// Readers still decide differently on purpose; each decision is a named
// predicate below, so the differences are visible rather than repeated by hand.

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>

namespace map_transfer {
namespace root_state {

enum class Marker : uint8_t {
  // A stream upload is writing this root.
  Installing,
  // A legacy stream upload finished and waits for activation.
  Ready,
  // A durable operation verified this root but has not committed it.
  OperationPrepared,
  // A committed durable operation waits for activation.
  OperationReady,
  // Activation finished: the root is an installed library map.
  Consumed,
  // Completed-library evidence kept while a same-content operation owns the root.
  LibraryRetained,
};

constexpr std::size_t kMarkerCount = 6;

constexpr const char *fileName(Marker marker) {
  switch (marker) {
  case Marker::Installing: return ".installing";
  case Marker::Ready: return ".ready";
  case Marker::OperationPrepared: return ".operation-prepared";
  case Marker::OperationReady: return ".operation-ready";
  case Marker::Consumed: return ".activation-consumed";
  case Marker::LibraryRetained: return ".library-retained";
  }
  return "";
}

// A marker counts as present when its file or its ".bak" copy is a regular
// file. A ".tmp" copy never counts: it is an unfinished atomic write.
// `.library-retained` is written once and never has a ".bak" copy.
constexpr bool backupCounts(Marker marker) {
  return marker != Marker::LibraryRetained;
}

// The same path the installers build with joinPath(root, fileName(marker)).
inline std::string markerPath(const std::string &root, Marker marker) {
  std::string path = root;
  if (!path.empty() && path.back() != '/')
    path.push_back('/');
  path += fileName(marker);
  return path;
}

// One live check. Use it where a reader writes a marker between its checks.
template <typename Exists>
bool present(const Exists &exists, const std::string &root, Marker marker) {
  const std::string path = markerPath(root, marker);
  return exists(path) || (backupCounts(marker) && exists(path + ".bak"));
}

// One root's markers. Each marker is checked at most once and only when a
// reader asks, so a reader keeps its own order and number of card reads.
// Use a view only while the reader writes no marker of this root.
template <typename Exists>
class Markers {
public:
  Markers(Exists exists, std::string root)
      : exists_(std::move(exists)), root_(std::move(root)) {}

  bool has(Marker marker) {
    const auto index = static_cast<std::size_t>(marker);
    if (!known_[index]) {
      present_[index] = present(exists_, root_, marker);
      known_[index] = true;
    }
    return present_[index];
  }

  // Either install path finished its upload: legacy `.ready` or a committed
  // operation's `.operation-ready`.
  bool uploadFinished() {
    return has(Marker::Ready) || has(Marker::OperationReady);
  }

  // A completed library map, including one a same-content operation retains.
  bool completedLibraryVersion() {
    return has(Marker::Consumed) || has(Marker::LibraryRetained);
  }

  // Boot recovery of a stream install (MapStreamInstaller) looks only at roots
  // with unfinished work: a finished upload not yet consumed, an upload still
  // writing, or an uncommitted operation.
  bool streamRecoveryCandidate() {
    const bool operationReady = has(Marker::OperationReady);
    const bool operationPrepared = has(Marker::OperationPrepared);
    const bool ready = operationReady || has(Marker::Ready);
    const bool consumed = has(Marker::Consumed);
    const bool installing = has(Marker::Installing);
    return !((!ready || consumed) && !installing && !operationPrepared);
  }

  // An active-pointer root that an upload is still writing, without a
  // finished upload, is not usable. Older roots without markers are.
  bool unusableActiveRoot() {
    const bool installing = has(Marker::Installing);
    const bool finished = has(Marker::OperationReady) || has(Marker::Ready);
    return installing && !finished;
  }

  // Selection settling handles only legacy uploads: an operation-backed root
  // keeps its ready state until finalizeOperation persists the receipt. A
  // consumed root is settled unless the pending activation still names it.
  bool unsettledLegacyUpload(bool pendingNamesRoot) {
    const bool consumed = has(Marker::Consumed);
    return !((consumed && !pendingNamesRoot) || !has(Marker::Ready));
  }

  // Discarding all unselected stream state removes only legacy upload state.
  // Completed or retained library versions stay, and operation-backed roots
  // belong to the operation ledger.
  bool discardableLegacyStreamState() {
    if (has(Marker::Consumed) || has(Marker::LibraryRetained))
      return false;
    return has(Marker::Ready) || has(Marker::Installing);
  }

  // Pruning keeps every completed library map and, while an upload may be in
  // progress, any root it is writing. keepInstalling is true when no session
  // is named or this root is the named one.
  bool pruneKeepsByMarkers(bool keepInstalling) {
    return has(Marker::Consumed) || has(Marker::LibraryRetained) ||
           (keepInstalling && has(Marker::Installing));
  }

private:
  Exists exists_;
  std::string root_;
  std::array<bool, kMarkerCount> known_{};
  std::array<bool, kMarkerCount> present_{};
};

template <typename Exists>
Markers<Exists> markers(Exists exists, std::string root) {
  return Markers<Exists>(std::move(exists), std::move(root));
}

// The "phase" of `.activation-transaction.json`.
enum class JournalPhase : uint8_t {
  Invalid,
  // An archive activation is copying files.
  Publishing,
  // The new selection is written, not yet committed.
  Ready,
  Committed,
};

constexpr const char *journalPhaseName(JournalPhase phase) {
  switch (phase) {
  case JournalPhase::Publishing: return "publishing";
  case JournalPhase::Ready: return "ready";
  case JournalPhase::Committed: return "committed";
  case JournalPhase::Invalid: break;
  }
  return "";
}

inline JournalPhase parseJournalPhase(const std::string &value) {
  for (const auto phase : {JournalPhase::Publishing, JournalPhase::Ready,
                           JournalPhase::Committed}) {
    if (value == journalPhaseName(phase))
      return phase;
  }
  return JournalPhase::Invalid;
}

// A stream activation writes only ready and committed.
constexpr bool streamJournalAccepts(JournalPhase phase) {
  return phase == JournalPhase::Ready || phase == JournalPhase::Committed;
}

// An archive activation also writes publishing before it copies files.
constexpr bool archiveJournalAccepts(JournalPhase phase) {
  return phase != JournalPhase::Invalid;
}

} // namespace root_state
} // namespace map_transfer
