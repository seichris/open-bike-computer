#include "../../lib/route_elevation/route_elevation_protocol.hpp"

#include <cassert>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using namespace route_elevation_protocol;
using Bytes = std::vector<uint8_t>;

namespace {

std::map<std::string, Bytes> loadFixtures(int argc, char **argv) {
  std::ifstream input(argc > 1 ? argv[1] : "protocol/fixtures/route-elevation-v1/transfer-v1.txt");
  if (!input && argc == 1) input.open("../protocol/fixtures/route-elevation-v1/transfer-v1.txt");
  assert(input && "run from repo root/esp32 or provide the fixture path");
  std::map<std::string, Bytes> fixtures;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream fields(line);
    std::string name, hex;
    fields >> name >> hex;
    assert(!name.empty() && hex.size() % 2 == 0);
    Bytes bytes;
    for (std::size_t index = 0; index < hex.size(); index += 2) {
      bytes.push_back(static_cast<uint8_t>(std::stoul(hex.substr(index, 2), nullptr, 16)));
    }
    fixtures[name] = bytes;
  }
  return fixtures;
}

Session::Outcome feed(Session &session, const Bytes &frame, uint32_t nowMs = 1000) {
  return session.handle(frame.data(), frame.size(), nowMs);
}

std::vector<Bytes> transferFrames(const std::map<std::string, Bytes> &fixtures) {
  std::vector<Bytes> frames;
  for (int index = 0;; ++index) {
    const auto found = fixtures.find("hill_frame_" + std::to_string(index));
    if (found == fixtures.end()) break;
    frames.push_back(found->second);
  }
  return frames;
}

Bytes chunkFrame(uint16_t transferId, uint8_t index, const Bytes &body, std::size_t start, std::size_t size) {
  Bytes frame = {'E', 'L', 'V', '1', FRAME_VERSION, static_cast<uint8_t>(Op::Chunk)};
  frame.push_back(static_cast<uint8_t>(transferId));
  frame.push_back(static_cast<uint8_t>(transferId >> 8));
  frame.push_back(index);
  frame.insert(frame.end(), body.begin() + start, body.begin() + std::min(body.size(), start + size));
  return frame;
}

Bytes ackBytes(const Session::Outcome &outcome) {
  assert(outcome.hasAck);
  return Bytes(outcome.ack.begin(), outcome.ack.end());
}

void deliver(Session &session, const std::vector<Bytes> &frames, uint32_t nowMs = 1000) {
  for (std::size_t index = 0; index + 1 < frames.size(); ++index) feed(session, frames[index], nowMs);
}

} // namespace

int main(int argc, char **argv) {
  const auto fixtures = loadFixtures(argc, argv);
  const Bytes &body = fixtures.at("hill_body");

  static_assert(MAXIMUM_BODY_BYTES == 1376, "v1 body bound");
  static_assert(sizeof(Session) < 6 * 1024, "session state stays small and static");

  Profile decoded{};
  assert(decodeBody(body.data(), body.size(), decoded));
  assert(decoded.routeToken == 0x12345678 && decoded.revision == 3);
  assert(decoded.pointCount == (body.size() - BODY_HEADER_BYTES) / POINT_BYTES);
  assert(decoded.points[0].distanceM == 0);
  assert(decoded.points[decoded.pointCount - 1].distanceM == decoded.totalDistanceM);
  assert(decoded.totalDistanceM == 6000);
  assert((decoded.flags & BODY_FLAG_STATS_COMPLETE) != 0 && (decoded.flags & BODY_FLAG_ASCENT_VALID) != 0);
  assert(decoded.source == static_cast<uint8_t>(Source::InternalDem));
  std::ostringstream crcText;
  {
    char buffer[9];
    std::snprintf(buffer, sizeof(buffer), "%08x", crc32(body.data(), body.size()));
    crcText << buffer;
  }
  const Bytes &crcFixture = fixtures.at("hill_body_crc32");
  char expectedCrc[9];
  std::snprintf(expectedCrc, sizeof(expectedCrc), "%02x%02x%02x%02x", crcFixture[0], crcFixture[1], crcFixture[2],
                crcFixture[3]);
  assert(crcText.str() == expectedCrc);

  Profile gaps{};
  assert(decodeBody(fixtures.at("gaps_body").data(), fixtures.at("gaps_body").size(), gaps));
  bool sawUnknown = false;
  for (std::size_t index = 0; index < gaps.pointCount; ++index) sawUnknown |= gaps.points[index].elevationM == UNKNOWN_ELEVATION;
  assert(sawUnknown && (gaps.flags & BODY_FLAG_PARTIAL) != 0 && (gaps.flags & BODY_FLAG_STATS_COMPLETE) == 0);
  Profile longest{};
  assert(decodeBody(fixtures.at("long_body").data(), fixtures.at("long_body").size(), longest));
  assert(longest.pointCount <= 160 && longest.totalDistanceM == 260000 && longest.revision == 65535);

  // invalid_body_crc_mismatch may still parse; only the transfer CRC rejects it (below).
  for (const char *name : {"invalid_body_version", "invalid_body_reserved_point_flags", "invalid_body_distance_order",
                           "invalid_body_truncated", "invalid_body_point_count"}) {
    Profile rejected{};
    const Bytes &bytes = fixtures.at(name);
    assert(!decodeBody(bytes.data(), bytes.size(), rejected));
  }

  // Complete transfer: BEGIN, ordered chunks, COMMIT; atomic activation.
  const auto frames = transferFrames(fixtures);
  assert(frames.size() >= 3);
  Session session;
  const auto begun = feed(session, frames.front());
  assert(begun.recognized && begun.hasAck && begun.ack[6] == static_cast<uint8_t>(Result::Applied));
  assert(session.binding().state == ProfileState::Loading && !session.hasProfile());
  for (std::size_t index = 1; index + 1 < frames.size(); ++index) assert(!feed(session, frames[index]).hasAck);
  const auto committed = feed(session, frames.back());
  assert(ackBytes(committed) == fixtures.at("ack_commit_applied"));
  assert(committed.changed && session.hasProfile() && session.binding().state == ProfileState::Ready);
  assert(session.profile().pointCount == decoded.pointCount);

  // Progress for the active revision is applied once; duplicates and other revisions are ignored.
  assert(feed(session, fixtures.at("hill_progress")).changed);
  assert(session.hasProgress() && session.progress().progressM == 1235 && session.progress().sequence == 7);
  assert((session.progress().flags & PROGRESS_ON_ROUTE) != 0 && (session.progress().flags & PROGRESS_GRADE_VALID) != 0);
  assert(!feed(session, fixtures.at("hill_progress")).changed);
  assert(feed(session, fixtures.at("hill_progress_off_route")).changed);
  assert((session.progress().flags & PROGRESS_ON_ROUTE) == 0 && (session.progress().flags & PROGRESS_ELEVATION_VALID) == 0);

  // A new revision (reroute) immediately retires the old profile and its progress.
  assert(feed(session, fixtures.at("state_unavailable_source")).changed);
  assert(!session.hasProfile() && session.binding().revision == 4);
  assert(session.binding().state == ProfileState::Unavailable && session.binding().reason == Reason::SourceNotPermitted);
  assert(!feed(session, fixtures.at("hill_progress")).changed && !session.hasProgress());

  // A delayed commit for the old revision is stale and cannot replace the new binding.
  Session stale;
  feed(stale, frames.front());
  deliver(stale, std::vector<Bytes>(frames.begin() + 1, frames.end()));
  feed(stale, fixtures.at("state_unavailable_source"));
  const auto staleCommit = feed(stale, frames.back());
  assert(staleCommit.ack[6] == static_cast<uint8_t>(Result::Stale) && !stale.hasProfile());

  // Corrupted payload with the original CRC: rejected, previous profile kept.
  Session corrupt;
  deliver(corrupt, frames);
  feed(corrupt, frames.back());
  assert(corrupt.hasProfile());
  const Bytes &bad = fixtures.at("invalid_body_crc_mismatch");
  Bytes beginAgain = frames.front();
  beginAgain[12] = 0x03;
  beginAgain[13] = 0x01;  // transfer id 0x0103
  feed(corrupt, beginAgain);
  const std::size_t chunkSize = frames[1].size() - CHUNK_HEADER_BYTES;
  uint8_t chunkIndex = 0;
  for (std::size_t start = 0; start < bad.size(); start += chunkSize) {
    feed(corrupt, chunkFrame(0x0103, chunkIndex++, bad, start, chunkSize));
  }
  Bytes commitAgain = {'E', 'L', 'V', '1', FRAME_VERSION, static_cast<uint8_t>(Op::Commit), 0x03, 0x01};
  const auto crcFailure = feed(corrupt, commitAgain);
  assert(crcFailure.ack[6] == static_cast<uint8_t>(Result::CrcMismatch));
  assert(corrupt.hasProfile() && corrupt.profile().revision == 3);

  // Out-of-order chunk fails the whole transfer.
  Session ordered;
  feed(ordered, frames.front());
  feed(ordered, frames[2]);
  assert(feed(ordered, frames.back()).ack[6] == static_cast<uint8_t>(Result::Incomplete));
  assert(!ordered.hasProfile());

  // Missing final chunk and a stalled transfer.
  Session incomplete;
  feed(incomplete, frames.front());
  for (std::size_t index = 1; index + 2 < frames.size(); ++index) feed(incomplete, frames[index]);
  assert(feed(incomplete, frames.back()).ack[6] == static_cast<uint8_t>(Result::Incomplete));
  Session stalled;
  feed(stalled, frames.front(), 1000);
  feed(stalled, frames[1], 1000 + TRANSFER_TIMEOUT_MS + 1);
  assert(!stalled.staging());
  assert(feed(stalled, frames.back(), 1000 + TRANSFER_TIMEOUT_MS + 2).ack[6] == static_cast<uint8_t>(Result::Stale));

  // Oversized or malformed BEGIN gets an explicit malformed acknowledgement.
  Bytes oversized = frames.front();
  oversized[14] = 0xFF;
  oversized[15] = 0x7F;
  const auto rejectedBegin = feed(session, oversized);
  assert(rejectedBegin.hasAck && rejectedBegin.ack[6] == static_cast<uint8_t>(Result::Malformed));
  const auto unsupported = feed(session, fixtures.at("invalid_frame_version"));
  assert(unsupported.hasAck && unsupported.ack[6] == static_cast<uint8_t>(Result::Unsupported));

  // Clearing and disconnect reset remove all route state.
  Session cleared;
  deliver(cleared, frames);
  feed(cleared, frames.back());
  assert(feed(cleared, fixtures.at("state_cleared")).changed);
  assert(!cleared.hasProfile() && cleared.binding().state == ProfileState::Cleared);
  deliver(cleared, frames);
  feed(cleared, frames.back());
  cleared.reset();
  assert(!cleared.hasProfile() && !cleared.hasProgress() && cleared.binding().routeToken == 0);

  // Loading state for a new route is shown before data arrives; unrelated magic is ignored.
  Session loading;
  assert(feed(loading, fixtures.at("state_loading")).changed);
  assert(loading.binding().state == ProfileState::Loading && loading.binding().revision == 3);
  const Bytes other = {'G', 'R', 'U', 'P', 1, 0};
  assert(!feed(loading, other).recognized);

  std::puts("route elevation protocol tests passed");
  return 0;
}
