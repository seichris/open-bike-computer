#include "../../lib/spoken_directions/spoken_session.hpp"
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>
using namespace spoken_directions;
#define CHECK(value) do { if (!(value)) { std::cerr << "line " << __LINE__ << ": " #value "\n"; std::exit(1); } } while (false)
std::vector<uint8_t> hex(const char *text) {
    std::vector<uint8_t> result;
    for (size_t i = 0; text[i]; i += 2)
        result.push_back(static_cast<uint8_t>(std::stoul(std::string(text + i, 2), nullptr, 16)));
    return result;
}
int main() {
    const auto raw = hex(generated::SPOKEN_CUE_HEX);
    const auto cr = hex(generated::SPOKEN_CONTROL_HEX);
    Cue c{}, output{}; Control control{};
    CHECK(decodeCue(raw.data(), raw.size(), c));
    CHECK(c.token == 0x0102030405060708ULL && c.generation == 0x11223344 && c.distance == 50 && c.maneuver == Maneuver::Right);
    CHECK(decodeControl(cr.data(), cr.size(), control));
    for (size_t n = 0; n < raw.size(); ++n) CHECK(!decodeCue(raw.data(), n, output));
    for (size_t n = 0; n < cr.size(); ++n) CHECK(!decodeControl(cr.data(), n, control));
    CHECK(decodeControl(cr.data(), cr.size(), control));
    for (size_t at : {size_t(0),size_t(4),size_t(5),size_t(6),size_t(7),size_t(36),size_t(37)}) {
        auto bad = raw; bad[at] = 255; CHECK(!decodeCue(bad.data(), bad.size(), output));
    }
    // Deterministic exhaustive single-byte mutations exercise both parsers
    // under ASan/UBSan, including enum values used by the phase bit mask.
    for (size_t at = 0; at < raw.size(); ++at) {
        for (unsigned value = 0; value <= 255; ++value) {
            auto mutated = raw; mutated[at] = uint8_t(value);
            Cue candidate{};
            if (decodeCue(mutated.data(), mutated.size(), candidate)) CHECK(valid(candidate));
        }
    }
    for (size_t at = 0; at < cr.size(); ++at) {
        for (unsigned value = 0; value <= 255; ++value) {
            auto mutated = cr; mutated[at] = uint8_t(value);
            Control candidate{};
            if (decodeControl(mutated.data(), mutated.size(), candidate)) CHECK(valid(candidate));
        }
    }
    Session s;
    CHECK(s.control(control, 100, false) == Admission::unauthorized);
    CHECK(s.control(control, 100, true) == Admission::accepted);
    CHECK(s.control(control, 101, true) == Admission::stale);
    CHECK(s.admit(c, 110, false, true) == Admission::unauthorized);
    CHECK(s.admit(c, 110, true, false) == Admission::unavailable);
    CHECK(s.admit(c, 110, true, true) == Admission::accepted);
    CHECK(s.admit(c, 111, true, true) == Admission::stale);
    CHECK(s.take(112, output) && output.sequence == c.sequence);
    const auto originalEpoch = s.epoch();
    CHECK(s.playbackCurrent(output, originalEpoch, 112));
    ++c.sequence; CHECK(s.admit(c, 113, true, true) == Admission::stale); // same phase
    c.phase = Phase::Action; c.distance = 0;
    CHECK(s.admit(c, 114, true, true) == Admission::accepted);
    CHECK(!s.playbackCurrent(output, originalEpoch, 115));
    CHECK(s.take(115, output) && output.phase == Phase::Action);
    auto invalid = c; invalid.phase = static_cast<Phase>(255);
    CHECK(s.admit(invalid, 115, true, true) == Admission::malformed);
    control.action = ControlAction::Progress; ++control.progressRevision;
    CHECK(s.control(control, 120, true) == Admission::accepted);
    CHECK(s.control(control, 121, true) == Admission::stale);
    ++control.progressRevision; ++control.stepId;
    CHECK(s.control(control, 125, true) == Admission::accepted);
    CHECK(!s.playbackCurrent(output, s.epoch(), 125));
    CHECK(s.admit(c, 126, true, true) == Admission::stale); // old step
    c.stepId = control.stepId; c.progressRevision = control.progressRevision; ++c.sequence;
    CHECK(s.admit(c, 126, true, true) == Admission::accepted);
    CHECK(!s.take(6000, output)); // both lease and start deadline expired
    ++control.progressRevision; CHECK(s.control(control, 6001, true) == Admission::accepted);
    CHECK(!s.take(6002, output)); // renewal never revives consumed work
    c.progressRevision = control.progressRevision; ++c.sequence;
    CHECK(s.admit(c, 6002, true, true) == Admission::stale); // phase ledger survives expired lease
    control.action = ControlAction::Cancel; ++control.revision;
    CHECK(s.control(control, 6003, true) == Admission::accepted && !s.live(6003));
    CHECK(s.admit(c, 6004, true, true) == Admission::stale);

    s.disconnect(); control.action = ControlAction::Activate;
    CHECK(s.control(control, UINT32_MAX - 50, true) == Admission::accepted);
    CHECK(s.live(10)); // rollover-safe elapsed monotonic time
    c.phase = Phase::Arrival; c.maneuver = Maneuver::Arrive;
    c.progressRevision = control.progressRevision;
    CHECK(s.admit(c, 11, true, true) == Admission::accepted);
    CHECK(s.take(12, output)); const auto arrivalEpoch = s.epoch();
    control.action = ControlAction::Arrived; ++control.revision;
    CHECK(s.control(control, 13, true) == Admission::accepted);
    ++control.revision;
    CHECK(s.control(control, 14, true) == Admission::stale); // grace cannot be renewed
    CHECK(s.playbackCurrent(output, arrivalEpoch, 14));
    CHECK(!s.playbackCurrent(output, arrivalEpoch, 8013));
    s.disconnect(); CHECK(!s.live(20));
    std::cout << "spoken protocol/session tests passed\n";
}
