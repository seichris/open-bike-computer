#include "../../lib/ble_navigation/route_reference_track_protocol.hpp"

#include <cassert>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

using namespace route_reference_track_protocol;
using Bytes = std::vector<uint8_t>;

namespace {

struct Fixtures {
  std::map<std::string, Bytes> frames;
  std::map<std::string, std::vector<Point>> points;
};

Fixtures loadFixtures(int argc, char **argv) {
  std::ifstream input(argc > 1 ? argv[1]
                               : "protocol/fixtures/route-reference-track-v1/frames-v1.txt");
  if (!input && argc == 1)
    input.open("../protocol/fixtures/route-reference-track-v1/frames-v1.txt");
  assert(input && "run from repo root/esp32 or provide the fixture path");
  Fixtures fixtures;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#')
      continue;
    std::istringstream fields(line);
    std::string name, value;
    fields >> name >> value;
    assert(!name.empty() && !value.empty());
    if (name.size() > 6 && name.compare(name.size() - 6, 6, "_track") == 0) {
      std::vector<Point> points;
      std::istringstream pairs(value);
      std::string pair;
      while (std::getline(pairs, pair, ';')) {
        const size_t comma = pair.find(',');
        assert(comma != std::string::npos);
        points.push_back({static_cast<int32_t>(std::stol(pair.substr(0, comma))),
                          static_cast<int32_t>(std::stol(pair.substr(comma + 1)))});
      }
      fixtures.points[name.substr(0, name.size() - 6)] = points;
      continue;
    }
    assert(value.size() % 2 == 0);
    Bytes bytes;
    for (size_t index = 0; index < value.size(); index += 2)
      bytes.push_back(static_cast<uint8_t>(std::stoul(value.substr(index, 2), nullptr, 16)));
    fixtures.frames[name] = bytes;
  }
  return fixtures;
}

Frame parseBytes(const Bytes &bytes) { return parse(bytes.data(), bytes.size()); }

void expectPoints(const Frame &frame, const std::vector<Point> &expected) {
  assert(frame.kind == FrameKind::Set);
  assert(frame.count == expected.size());
  for (size_t index = 0; index < expected.size(); ++index) {
    assert(frame.points[index].lat == expected[index].lat);
    assert(frame.points[index].lon == expected[index].lon);
  }
}

} // namespace

int main(int argc, char **argv) {
  static_assert(MAXIMUM_FRAME_BYTES == 202, "48 points fit one 512-byte protected write");
  const Fixtures fixtures = loadFixtures(argc, argv);

  expectPoints(parseBytes(fixtures.frames.at("dubai_set")), fixtures.points.at("dubai"));
  const Frame maximum = parseBytes(fixtures.frames.at("maximum_set"));
  expectPoints(maximum, fixtures.points.at("maximum"));
  assert(maximum.count == MAXIMUM_POINTS);
  assert(fixtures.frames.at("maximum_set").size() == MAXIMUM_FRAME_BYTES);

  const Frame clear = parseBytes(fixtures.frames.at("clear"));
  assert(clear.kind == FrameKind::Clear && clear.count == 0);

  assert(parseBytes(fixtures.frames.at("unsupported_version")).kind == FrameKind::Unsupported);
  for (const char *name : {"unknown_operation", "clear_with_body", "single_point",
                           "partial_delta", "too_many_points", "latitude_out_of_range"}) {
    const Frame frame = parseBytes(fixtures.frames.at(name));
    if (frame.kind != FrameKind::Malformed) {
      std::fprintf(stderr, "%s was not rejected\n", name);
      return 1;
    }
  }

  // Other frames on the navigation characteristic never match.
  const uint8_t elevation[] = {'E', 'L', 'V', '1', 1, 1};
  assert(!hasFrameMagic(elevation, sizeof(elevation)));
  assert(!hasFrameMagic(nullptr, 0));
  const uint8_t shortMagic[] = {'R', 'T', 'K'};
  assert(!hasFrameMagic(shortMagic, sizeof(shortMagic)));
  assert(parse(shortMagic, sizeof(shortMagic)).kind == FrameKind::Malformed);
  const uint8_t headerOnly[] = {'R', 'T', 'K', '1', 1};
  assert(parse(headerOnly, sizeof(headerOnly)).kind == FrameKind::Malformed);

  std::puts("route reference track protocol tests passed");
  return 0;
}
