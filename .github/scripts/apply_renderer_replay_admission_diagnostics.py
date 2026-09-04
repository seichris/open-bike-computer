from pathlib import Path

root = Path.cwd()


def read(path: str) -> str:
    return (root / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (root / path).write_text(text, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}")
    write(path, text.replace(old, new, 1))


policy = "esp32/lib/renderer_diagnostics/renderer_diagnostics_policy.hpp"
api = "esp32/lib/renderer_diagnostics/renderer_diagnostics.hpp"
implementation = "esp32/lib/renderer_diagnostics/renderer_diagnostics.cpp"
ble = "esp32/lib/ble_navigation/ble_navigation.cpp"
test = "esp32/tools/tests/test_renderer_diagnostics.cpp"

replace_once(
    policy,
    '''struct RouteMarker {
  std::array<uint8_t, 32> fixtureSha256{};
  uint16_t sampleIndex = 0;
  uint16_t sampleCount = 0;
  uint32_t loop = 0;
  uint32_t receivedAtMs = 0;
  uint32_t accepted = 0;
  uint32_t rejected = 0;
  bool valid = false;
};
''',
    '''struct RouteMarker {
  std::array<uint8_t, 32> fixtureSha256{};
  uint16_t sampleIndex = 0;
  uint16_t sampleCount = 0;
  uint32_t loop = 0;
  uint32_t receivedAtMs = 0;
  uint32_t accepted = 0;
  uint32_t rejected = 0;
  bool valid = false;
};

enum class ReplayMarkerResult : uint8_t {
  None,
  Accepted,
  Invalid,
  NoActiveWindow,
  ActiveFixtureUnavailable,
  FixtureMismatch,
};

inline const char *replayMarkerResultName(ReplayMarkerResult result) {
  switch (result) {
  case ReplayMarkerResult::Accepted:
    return "accepted";
  case ReplayMarkerResult::Invalid:
    return "invalid";
  case ReplayMarkerResult::NoActiveWindow:
    return "no_active_window";
  case ReplayMarkerResult::ActiveFixtureUnavailable:
    return "active_fixture_unavailable";
  case ReplayMarkerResult::FixtureMismatch:
    return "fixture_mismatch";
  case ReplayMarkerResult::None:
  default:
    return "none";
  }
}

// Session-scoped, non-secret transport evidence. Unlike RouteMarker, this is
// deliberately not cleared by beginWindow(), so an RBS1 received before the
// first measurement window remains observable after that window is created.
struct ReplayTransportDiagnostics {
  uint32_t gpsAuthenticationAccepted = 0;
  uint32_t gpsAuthenticationRejected = 0;
  uint32_t rbs1Detected = 0;
  uint32_t rbs1Decoded = 0;
  uint32_t rbs1Malformed = 0;
  uint32_t rbs1Unnegotiated = 0;
  uint32_t gpsMailboxAccepted = 0;
  uint32_t gpsMailboxRejected = 0;
  uint32_t markerAccepted = 0;
  uint32_t markerRejectedInvalid = 0;
  uint32_t markerRejectedNoActiveWindow = 0;
  uint32_t markerRejectedActiveFixtureUnavailable = 0;
  uint32_t markerRejectedFixtureMismatch = 0;
  uint32_t lastTransportEventAtMs = 0;
  uint32_t lastMarkerAtMs = 0;
  uint32_t lastActiveWindowId = 0;
  uint16_t lastSampleIndex = 0;
  uint16_t lastSampleCount = 0;
  uint32_t lastLoop = 0;
  uint32_t lastCandidateFixtureTag = 0;
  uint32_t lastExpectedFixtureTag = 0;
  bool lastCandidateFixtureTagValid = false;
  bool lastExpectedFixtureTagValid = false;
  ReplayMarkerResult lastMarkerResult = ReplayMarkerResult::None;
};
'''
)

replace_once(
    policy,
    '''  RouteMarker routeMarker{};
  bool routeFixtureMatches = false;
  RemoteDebugOverhead remoteDebug{};
''',
    '''  RouteMarker routeMarker{};
  bool routeFixtureMatches = false;
  ReplayTransportDiagnostics replayTransport{};
  RemoteDebugOverhead remoteDebug{};
'''
)

replace_once(
    policy,
    '''    remoteDebug_ = {};
    remoteDebug_.active = remoteDebugActive;
    resetWindowState();
''',
    '''    remoteDebug_ = {};
    remoteDebug_.active = remoteDebugActive;
    replayTransport_ = {};
    resetWindowState();
'''
)

replace_once(
    policy,
    '''    profile_ = renderer_tuning::Profile::Current;
    remoteDebug_ = {};
    resetWindowState();
''',
    '''    profile_ = renderer_tuning::Profile::Current;
    remoteDebug_ = {};
    replayTransport_ = {};
    resetWindowState();
'''
)

replace_once(
    policy,
    '''  bool noteRouteMarker(const uint8_t *fixtureSha256, size_t hashBytes,
                       uint16_t sampleIndex, uint16_t sampleCount,
                       uint32_t loop, uint32_t nowMs) {
    if (fixtureSha256 == nullptr ||
        hashBytes != routeMarker_.fixtureSha256.size() || sampleCount == 0 ||
        sampleIndex >= sampleCount || !routeHashMatches(fixtureSha256)) {
      ++routeMarker_.rejected;
      return false;
    }
    std::copy(fixtureSha256, fixtureSha256 + hashBytes,
              routeMarker_.fixtureSha256.begin());
    routeMarker_.sampleIndex = sampleIndex;
    routeMarker_.sampleCount = sampleCount;
    routeMarker_.loop = loop;
    routeMarker_.receivedAtMs = nowMs;
    ++routeMarker_.accepted;
    routeMarker_.valid = true;
    return true;
  }
''',
    '''  void noteGpsAuthentication(bool accepted, uint32_t nowMs) {
    if (!sessionActive_)
      return;
    if (accepted)
      ++replayTransport_.gpsAuthenticationAccepted;
    else
      ++replayTransport_.gpsAuthenticationRejected;
    replayTransport_.lastTransportEventAtMs = nowMs;
  }

  void noteReplaySampleDetected(uint32_t nowMs) {
    if (!sessionActive_)
      return;
    ++replayTransport_.rbs1Detected;
    replayTransport_.lastTransportEventAtMs = nowMs;
  }

  void noteReplaySampleDecoded(bool accepted, uint32_t nowMs) {
    if (!sessionActive_)
      return;
    if (accepted)
      ++replayTransport_.rbs1Decoded;
    else
      ++replayTransport_.rbs1Malformed;
    replayTransport_.lastTransportEventAtMs = nowMs;
  }

  void noteReplaySampleUnnegotiated(uint32_t nowMs) {
    if (!sessionActive_)
      return;
    ++replayTransport_.rbs1Unnegotiated;
    replayTransport_.lastTransportEventAtMs = nowMs;
  }

  void noteReplayGpsMailbox(bool accepted, uint32_t nowMs) {
    if (!sessionActive_)
      return;
    if (accepted)
      ++replayTransport_.gpsMailboxAccepted;
    else
      ++replayTransport_.gpsMailboxRejected;
    replayTransport_.lastTransportEventAtMs = nowMs;
  }

  ReplayTransportDiagnostics replayTransportDiagnostics() const {
    return replayTransport_;
  }

  bool noteRouteMarker(const uint8_t *fixtureSha256, size_t hashBytes,
                       uint16_t sampleIndex, uint16_t sampleCount,
                       uint32_t loop, uint32_t nowMs) {
    replayTransport_.lastTransportEventAtMs = nowMs;
    replayTransport_.lastMarkerAtMs = nowMs;
    replayTransport_.lastActiveWindowId = measurementWindowId_;
    replayTransport_.lastSampleIndex = sampleIndex;
    replayTransport_.lastSampleCount = sampleCount;
    replayTransport_.lastLoop = loop;
    replayTransport_.lastCandidateFixtureTagValid =
        fixtureSha256 != nullptr &&
        hashBytes == routeMarker_.fixtureSha256.size();
    replayTransport_.lastCandidateFixtureTag =
        replayTransport_.lastCandidateFixtureTagValid
            ? fixtureTag(fixtureSha256)
            : 0;
    uint32_t expectedFixtureTag = 0;
    replayTransport_.lastExpectedFixtureTagValid =
        expectedRouteHashTag(expectedFixtureTag);
    replayTransport_.lastExpectedFixtureTag = expectedFixtureTag;

    auto reject = [this](ReplayMarkerResult result, uint32_t &counter) {
      ++routeMarker_.rejected;
      ++counter;
      replayTransport_.lastMarkerResult = result;
      return false;
    };
    if (fixtureSha256 == nullptr ||
        hashBytes != routeMarker_.fixtureSha256.size() || sampleCount == 0 ||
        sampleIndex >= sampleCount) {
      return reject(ReplayMarkerResult::Invalid,
                    replayTransport_.markerRejectedInvalid);
    }
    if (measurementWindowId_ == 0) {
      return reject(ReplayMarkerResult::NoActiveWindow,
                    replayTransport_.markerRejectedNoActiveWindow);
    }
    if (!replayTransport_.lastExpectedFixtureTagValid) {
      return reject(
          ReplayMarkerResult::ActiveFixtureUnavailable,
          replayTransport_.markerRejectedActiveFixtureUnavailable);
    }
    if (!routeHashMatches(fixtureSha256)) {
      return reject(ReplayMarkerResult::FixtureMismatch,
                    replayTransport_.markerRejectedFixtureMismatch);
    }
    std::copy(fixtureSha256, fixtureSha256 + hashBytes,
              routeMarker_.fixtureSha256.begin());
    routeMarker_.sampleIndex = sampleIndex;
    routeMarker_.sampleCount = sampleCount;
    routeMarker_.loop = loop;
    routeMarker_.receivedAtMs = nowMs;
    ++routeMarker_.accepted;
    routeMarker_.valid = true;
    ++replayTransport_.markerAccepted;
    replayTransport_.lastMarkerResult = ReplayMarkerResult::Accepted;
    return true;
  }
'''
)

replace_once(
    policy,
    '''    result.routeMarker = routeMarker_;
    result.routeFixtureMatches = routeHashMatches();
    result.remoteDebug = remoteDebug_;
''',
    '''    result.routeMarker = routeMarker_;
    result.routeFixtureMatches = routeHashMatches();
    result.replayTransport = replayTransport_;
    result.remoteDebug = remoteDebug_;
'''
)

replace_once(
    policy,
    '''  bool routeHashMatches(const uint8_t *candidate) const {
''',
    '''  static uint32_t fixtureTag(const uint8_t *hash) {
    if (hash == nullptr)
      return 0;
    return (static_cast<uint32_t>(hash[0]) << 24U) |
           (static_cast<uint32_t>(hash[1]) << 16U) |
           (static_cast<uint32_t>(hash[2]) << 8U) |
           static_cast<uint32_t>(hash[3]);
  }

  bool expectedRouteHashTag(uint32_t &tag) const {
    const char *expected = run_.routeFixtureSha256.c_str();
    if (std::strlen(expected) != 64)
      return false;
    tag = 0;
    for (size_t index = 0; index < 32; ++index) {
      const int high = hexNibble(expected[index * 2]);
      const int low = hexNibble(expected[index * 2 + 1]);
      if (high < 0 || low < 0)
        return false;
      if (index < 4) {
        tag = (tag << 8U) |
              static_cast<uint32_t>((high << 4) | low);
      }
    }
    return true;
  }

  bool routeHashMatches(const uint8_t *candidate) const {
'''
)

replace_once(
    policy,
    '''  RouteMarker routeMarker_{};
  RemoteDebugOverhead remoteDebug_{};
''',
    '''  RouteMarker routeMarker_{};
  ReplayTransportDiagnostics replayTransport_{};
  RemoteDebugOverhead remoteDebug_{};
'''
)

replace_once(
    api,
    '''void notePrediction(bool graceActive, bool exhausted);
bool noteRouteMarker''',
    '''void notePrediction(bool graceActive, bool exhausted);
void noteGpsAuthentication(bool accepted, uint32_t nowMs);
void noteReplaySampleDetected(uint32_t nowMs);
void noteReplaySampleDecoded(bool accepted, uint32_t nowMs);
void noteReplaySampleUnnegotiated(uint32_t nowMs);
void noteReplayGpsMailbox(bool accepted, uint32_t nowMs);
bool noteRouteMarker'''
)

replace_once(
    api,
    '''inline void notePrediction(bool, bool) {}
inline bool noteRouteMarker''',
    '''inline void notePrediction(bool, bool) {}
inline void noteGpsAuthentication(bool, uint32_t) {}
inline void noteReplaySampleDetected(uint32_t) {}
inline void noteReplaySampleDecoded(bool, uint32_t) {}
inline void noteReplaySampleUnnegotiated(uint32_t) {}
inline void noteReplayGpsMailbox(bool, uint32_t) {}
inline bool noteRouteMarker'''
)

replace_once(
    implementation,
    '''bool noteRouteMarker(const uint8_t *fixtureSha256, size_t hashBytes,
''',
    '''void noteGpsAuthentication(bool accepted, uint32_t nowMs) {
  portENTER_CRITICAL(&diagnosticsMux);
  if (diagnosticsState != nullptr)
    diagnosticsState->noteGpsAuthentication(accepted, nowMs);
  portEXIT_CRITICAL(&diagnosticsMux);
}

void noteReplaySampleDetected(uint32_t nowMs) {
  portENTER_CRITICAL(&diagnosticsMux);
  if (diagnosticsState != nullptr)
    diagnosticsState->noteReplaySampleDetected(nowMs);
  portEXIT_CRITICAL(&diagnosticsMux);
}

void noteReplaySampleDecoded(bool accepted, uint32_t nowMs) {
  portENTER_CRITICAL(&diagnosticsMux);
  if (diagnosticsState != nullptr)
    diagnosticsState->noteReplaySampleDecoded(accepted, nowMs);
  portEXIT_CRITICAL(&diagnosticsMux);
}

void noteReplaySampleUnnegotiated(uint32_t nowMs) {
  portENTER_CRITICAL(&diagnosticsMux);
  if (diagnosticsState != nullptr)
    diagnosticsState->noteReplaySampleUnnegotiated(nowMs);
  portEXIT_CRITICAL(&diagnosticsMux);
}

void noteReplayGpsMailbox(bool accepted, uint32_t nowMs) {
  portENTER_CRITICAL(&diagnosticsMux);
  if (diagnosticsState != nullptr)
    diagnosticsState->noteReplayGpsMailbox(accepted, nowMs);
  portEXIT_CRITICAL(&diagnosticsMux);
}

bool noteRouteMarker(const uint8_t *fixtureSha256, size_t hashBytes,
'''
)

replace_once(
    implementation,
    '''       << ",\\\"accepted\\\":" << value.routeMarker.accepted
       << ",\\\"rejected\\\":" << value.routeMarker.rejected << "}"
       << ",\\\"remoteDebug\\\":{\\\"active\\\":"
''',
    '''       << ",\\\"accepted\\\":" << value.routeMarker.accepted
       << ",\\\"rejected\\\":" << value.routeMarker.rejected << "}"
       << ",\\\"replayTransport\\\":{\\\"gpsAuthenticationAccepted\\\":"
       << value.replayTransport.gpsAuthenticationAccepted
       << ",\\\"gpsAuthenticationRejected\\\":"
       << value.replayTransport.gpsAuthenticationRejected
       << ",\\\"rbs1Detected\\\":" << value.replayTransport.rbs1Detected
       << ",\\\"rbs1Decoded\\\":" << value.replayTransport.rbs1Decoded
       << ",\\\"rbs1Malformed\\\":" << value.replayTransport.rbs1Malformed
       << ",\\\"rbs1Unnegotiated\\\":"
       << value.replayTransport.rbs1Unnegotiated
       << ",\\\"gpsMailboxAccepted\\\":"
       << value.replayTransport.gpsMailboxAccepted
       << ",\\\"gpsMailboxRejected\\\":"
       << value.replayTransport.gpsMailboxRejected
       << ",\\\"markerAccepted\\\":"
       << value.replayTransport.markerAccepted
       << ",\\\"markerRejectedInvalid\\\":"
       << value.replayTransport.markerRejectedInvalid
       << ",\\\"markerRejectedNoActiveWindow\\\":"
       << value.replayTransport.markerRejectedNoActiveWindow
       << ",\\\"markerRejectedActiveFixtureUnavailable\\\":"
       << value.replayTransport.markerRejectedActiveFixtureUnavailable
       << ",\\\"markerRejectedFixtureMismatch\\\":"
       << value.replayTransport.markerRejectedFixtureMismatch
       << ",\\\"lastTransportEventAtMs\\\":"
       << value.replayTransport.lastTransportEventAtMs
       << ",\\\"lastMarkerAtMs\\\":"
       << value.replayTransport.lastMarkerAtMs
       << ",\\\"lastActiveWindowId\\\":"
       << value.replayTransport.lastActiveWindowId
       << ",\\\"lastSampleIndex\\\":"
       << value.replayTransport.lastSampleIndex
       << ",\\\"lastSampleCount\\\":"
       << value.replayTransport.lastSampleCount
       << ",\\\"lastLoop\\\":" << value.replayTransport.lastLoop
       << ",\\\"lastCandidateFixtureTag\\\":"
       << value.replayTransport.lastCandidateFixtureTag
       << ",\\\"lastCandidateFixtureTagValid\\\":"
       << (value.replayTransport.lastCandidateFixtureTagValid
               ? "true"
               : "false")
       << ",\\\"lastExpectedFixtureTag\\\":"
       << value.replayTransport.lastExpectedFixtureTag
       << ",\\\"lastExpectedFixtureTagValid\\\":"
       << (value.replayTransport.lastExpectedFixtureTagValid
               ? "true"
               : "false")
       << ",\\\"lastMarkerResult\\\":\\\""
       << replayMarkerResultName(value.replayTransport.lastMarkerResult)
       << "\\\"}"
       << ",\\\"remoteDebug\\\":{\\\"active\\\":"
'''
)

replace_once(
    ble,
    '''    const std::string frame = pChar->getValue();
    std::string value;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Gps, frame, value,
            "GPS characteristic")) {
      return;
    }
''',
    '''    const std::string frame = pChar->getValue();
    const uint32_t receivedAtMs = millis();
    std::string value;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Gps, frame, value,
            "GPS characteristic")) {
#if FIRMWARE_DIAGNOSTICS
      renderer_diagnostics::noteGpsAuthentication(false, receivedAtMs);
#endif
      return;
    }
#if FIRMWARE_DIAGNOSTICS
    renderer_diagnostics::noteGpsAuthentication(true, receivedAtMs);
#endif
'''
)

replace_once(
    ble,
    '''    if (renderer_diagnostics_ble_protocol::hasReplaySamplePrefix(
            bytes, value.length())) {
      if (!bleSessionSupportsRendererBenchmarkSample.load(
              std::memory_order_acquire)) {
''',
    '''    if (renderer_diagnostics_ble_protocol::hasReplaySamplePrefix(
            bytes, value.length())) {
      renderer_diagnostics::noteReplaySampleDetected(receivedAtMs);
      if (!bleSessionSupportsRendererBenchmarkSample.load(
              std::memory_order_acquire)) {
        renderer_diagnostics::noteReplaySampleUnnegotiated(millis());
'''
)

replace_once(
    ble,
    '''              [](const uint8_t *gpsPayload, size_t gpsPayloadLength) {
                return queueMapInput(PendingMapInputType::Gps, gpsPayload,
                                     gpsPayloadLength, "native");
              },
''',
    '''              [](const uint8_t *gpsPayload, size_t gpsPayloadLength) {
                const bool accepted = queueMapInput(
                    PendingMapInputType::Gps, gpsPayload, gpsPayloadLength,
                    "native");
                renderer_diagnostics::noteReplayGpsMailbox(accepted, millis());
                return accepted;
              },
'''
)

replace_once(
    ble,
    '''              });
      if (result == renderer_diagnostics_ble_protocol::
                        ReplaySampleDispatchResult::Malformed) {
''',
    '''              });
      const bool decoded =
          result != renderer_diagnostics_ble_protocol::
                        ReplaySampleDispatchResult::Malformed;
      renderer_diagnostics::noteReplaySampleDecoded(decoded, millis());
      if (result == renderer_diagnostics_ble_protocol::
                        ReplaySampleDispatchResult::Malformed) {
'''
)

replace_once(
    test,
    '''  state.beginSession(true);

  constexpr const char *kRouteHash =
''',
    '''  state.beginSession(true);

  uint8_t preWindowRouteHash[32]{};
  state.noteGpsAuthentication(false, 900);
  state.noteGpsAuthentication(true, 901);
  state.noteReplaySampleDetected(902);
  state.noteReplaySampleDecoded(true, 903);
  state.noteReplayGpsMailbox(true, 904);
  assert(!state.noteRouteMarker(preWindowRouteHash,
                                sizeof(preWindowRouteHash), 1, 90, 0, 905));
  const ReplayTransportDiagnostics preWindowDiagnostics =
      state.replayTransportDiagnostics();
  assert(preWindowDiagnostics.gpsAuthenticationRejected == 1);
  assert(preWindowDiagnostics.gpsAuthenticationAccepted == 1);
  assert(preWindowDiagnostics.rbs1Detected == 1);
  assert(preWindowDiagnostics.rbs1Decoded == 1);
  assert(preWindowDiagnostics.gpsMailboxAccepted == 1);
  assert(preWindowDiagnostics.markerRejectedNoActiveWindow == 1);
  assert(preWindowDiagnostics.lastMarkerResult ==
         ReplayMarkerResult::NoActiveWindow);
  assert(preWindowDiagnostics.lastActiveWindowId == 0);
  assert(preWindowDiagnostics.lastCandidateFixtureTagValid);
  assert(!preWindowDiagnostics.lastExpectedFixtureTagValid);

  constexpr const char *kRouteHash =
'''
)

replace_once(
    test,
    '''  assert(state.measurementWindowId() == 41);
''',
    '''  assert(state.measurementWindowId() == 41);
  assert(state.replayTransportDiagnostics()
             .markerRejectedNoActiveWindow == 1);
'''
)

replace_once(
    test,
    '''  assert(snapshot.routeMarker.accepted == 1);
  assert(snapshot.routeMarker.rejected == 2);
  assert(snapshot.routeFixtureMatches);
''',
    '''  assert(snapshot.routeMarker.accepted == 1);
  assert(snapshot.routeMarker.rejected == 2);
  assert(snapshot.routeFixtureMatches);
  assert(snapshot.replayTransport.markerAccepted == 1);
  assert(snapshot.replayTransport.markerRejectedInvalid == 1);
  assert(snapshot.replayTransport.markerRejectedFixtureMismatch == 1);
  assert(snapshot.replayTransport.markerRejectedNoActiveWindow == 1);
  assert(snapshot.replayTransport.lastMarkerResult ==
         ReplayMarkerResult::Accepted);
  assert(snapshot.replayTransport.lastActiveWindowId == 41);
  assert(snapshot.replayTransport.lastSampleIndex == 12);
  assert(snapshot.replayTransport.lastExpectedFixtureTagValid);
  assert(snapshot.replayTransport.lastCandidateFixtureTagValid);
  assert(snapshot.replayTransport.lastExpectedFixtureTag == 0x00010203U);
  assert(snapshot.replayTransport.lastCandidateFixtureTag == 0x00010203U);
'''
)

replace_once(
    test,
    '''  assert(reset.routeMarker.accepted == 0);
''',
    '''  assert(reset.routeMarker.accepted == 0);
  assert(reset.replayTransport.markerRejectedNoActiveWindow == 1);
  assert(reset.replayTransport.markerAccepted == 1);
'''
)

replace_once(
    test,
    '''  assert(!ended.remoteDebug.active);
''',
    '''  assert(!ended.remoteDebug.active);
  assert(ended.replayTransport.rbs1Detected == 0);
  assert(ended.replayTransport.markerRejectedNoActiveWindow == 0);
'''
)

for path in (policy, api, implementation, ble, test):
    text = read(path)
    if "\r\n" in text:
        raise SystemExit(f"{path}: unexpected CRLF")
