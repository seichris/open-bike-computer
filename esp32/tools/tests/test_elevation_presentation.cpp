#include "../../lib/gui/src/elevationPresentation.hpp"

#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace ep = elevation_presentation;
namespace rep = route_elevation_protocol;

namespace {

std::map<std::string, std::vector<uint8_t>> loadFixtures(int argc, char **argv) {
  std::ifstream input(argc > 1 ? argv[1] : "protocol/fixtures/route-elevation-v1/transfer-v1.txt");
  if (!input && argc == 1) input.open("../protocol/fixtures/route-elevation-v1/transfer-v1.txt");
  assert(input && "run from repo root/esp32 or provide the fixture path");
  std::map<std::string, std::vector<uint8_t>> fixtures;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream fields(line);
    std::string name, hex;
    fields >> name >> hex;
    std::vector<uint8_t> bytes;
    for (std::size_t index = 0; index + 1 < hex.size(); index += 2) {
      bytes.push_back(static_cast<uint8_t>(std::stoul(hex.substr(index, 2), nullptr, 16)));
    }
    fixtures[name] = bytes;
  }
  return fixtures;
}

rep::Profile decode(const std::vector<uint8_t> &bytes) {
  rep::Profile profile{};
  assert(rep::decodeBody(bytes.data(), bytes.size(), profile));
  return profile;
}

} // namespace

int main(int argc, char **argv) {
  const auto fixtures = loadFixtures(argc, argv);
  constexpr ep::Layout round = ep::makeLayout(466, 466);
  static_assert(round.chart.width == 350 && round.chart.height == 152);
  static_assert(round.chart.width <= ep::MAXIMUM_CHART_WIDTH);
  static_assert(ep::rectFitsCircle(round.chart, 466));
  static_assert(ep::rectFitsCircle(round.primaryLeft, 466, 0));
  static_assert(ep::rectFitsCircle(round.primaryRight, 466, 0));
  static_assert(ep::rectFitsCircle(round.secondaryLeft, 466));
  static_assert(ep::rectFitsCircle(round.secondaryRight, 466));
  static_assert(ep::rectFitsCircle(round.footer, 466, 0));
  static_assert(round.primaryLeft.y + round.primaryLeft.height <= round.secondaryLeft.y);
  static_assert(round.secondaryLeft.y + round.secondaryLeft.height <= round.chart.y);
  constexpr ep::Layout rectangular = ep::makeLayout(410, 502);
  static_assert(rectangular.chart.x >= 0 && rectangular.chart.x + rectangular.chart.width <= 410);
  static_assert(rectangular.chart.y + rectangular.chart.height <= 502);

  // A full climb uses the whole height; the peak and valley are not clipped.
  const rep::Profile hill = decode(fixtures.at("hill_body"));
  static ep::Chart chart{};
  ep::buildChart(hill, round.chart.width, round.chart.height, chart);
  int32_t highest = round.chart.height;
  int32_t lowest = -1;
  for (int32_t x = 0; x < chart.width; ++x) {
    const ep::Column &column = chart.columns[static_cast<std::size_t>(x)];
    assert(column.style != ep::ColumnStyle::Unknown);
    highest = column.top < highest ? column.top : highest;
    lowest = column.top > lowest ? column.top : lowest;
  }
  assert(highest == ep::CHART_TOP_PADDING_PX);
  assert(lowest == round.chart.height - 1);
  assert(chart.minimumM == hill.minimumElevationM || chart.minimumM <= hill.minimumElevationM);

  // Unknown display points produce unknown columns, never a zero-height line.
  const rep::Profile gaps = decode(fixtures.at("gaps_body"));
  ep::buildChart(gaps, round.chart.width, round.chart.height, chart);
  int unknown = 0;
  for (int32_t x = 0; x < chart.width; ++x) unknown += chart.columns[static_cast<std::size_t>(x)].style == ep::ColumnStyle::Unknown;
  assert(unknown > 20);
  assert(chart.columns[0].style != ep::ColumnStyle::Unknown);

  // A nearly flat profile keeps a 40 m minimum span instead of exaggerating noise.
  rep::Profile flat{};
  flat.routeToken = 1;
  flat.revision = 1;
  flat.pointCount = 3;
  flat.totalDistanceM = 1000;
  flat.points[0] = {0, 10, 2};
  flat.points[1] = {500, 13, 2};
  flat.points[2] = {1000, 11, 2};
  ep::buildChart(flat, round.chart.width, round.chart.height, chart);
  assert(chart.maximumM - chart.minimumM == ep::MINIMUM_VERTICAL_SPAN_M);
  for (int32_t x = 0; x < chart.width; ++x) {
    const int16_t top = chart.columns[static_cast<std::size_t>(x)].top;
    assert(top > 50 && top < 110);
  }
  rep::Profile estimated = flat;
  estimated.points[1].flags = static_cast<uint8_t>(rep::POINT_FLAG_ESTIMATED | 5);
  estimated.points[2].flags = rep::POINT_FLAG_LOW_CONFIDENCE;
  ep::buildChart(estimated, round.chart.width, round.chart.height, chart);
  assert(chart.columns[10].style == ep::ColumnStyle::Estimated && chart.columns[10].gradeBand == 5);
  assert(chart.columns[300].style == ep::ColumnStyle::LowConfidence);

  // Marker comes only from phone progress.
  static_assert(ep::markerX(0, 6000, 350) == 0);
  static_assert(ep::markerX(6000, 6000, 350) == 349);
  static_assert(ep::markerX(9000, 6000, 350) == 349);
  static_assert(ep::markerX(3000, 6000, 350) == 174);
  static_assert(ep::markerX(rep::UNKNOWN_PROGRESS, 6000, 350) == -1);

  // Explicit states: missing data is never shown as zero or as a ready chart.
  rep::Session::Binding binding{};
  assert(ep::status(false, false, binding, false).state == ep::ScreenState::PhoneDisconnected);
  assert(ep::status(true, false, binding, false).state == ep::ScreenState::AppUpdateNeeded);
  assert(ep::status(true, true, binding, false).state == ep::ScreenState::NoRoute);
  binding = {1, 2, rep::ProfileState::Loading, rep::Reason::Unspecified};
  assert(ep::status(true, true, binding, false).state == ep::ScreenState::Loading);
  binding.state = rep::ProfileState::Unavailable;
  binding.reason = rep::Reason::SourceNotPermitted;
  const ep::Status unavailable = ep::status(true, true, binding, false);
  assert(unavailable.state == ep::ScreenState::Unavailable);
  assert(std::strcmp(unavailable.detail, "Not available for this route") == 0);
  binding.state = rep::ProfileState::Ready;
  assert(ep::status(true, true, binding, true).state == ep::ScreenState::Ready);
  assert(ep::status(true, true, binding, false).state == ep::ScreenState::NoRoute);

  char text[32];
  ep::formatMeters(text, sizeof(text), 287, true, false);
  assert(std::strcmp(text, "~287 m") == 0);
  ep::formatMeters(text, sizeof(text), 1234, false, true);
  assert(std::strcmp(text, "1234+ m") == 0);
  ep::formatMeters(text, sizeof(text), -410, false, false);
  assert(std::strcmp(text, "-410 m") == 0);
  ep::formatGrade(text, sizeof(text), -45, false);
  assert(std::strcmp(text, "-4.5%") == 0);
  ep::formatGrade(text, sizeof(text), 3, true);
  assert(std::strcmp(text, "~0.3%") == 0);
  ep::formatGrade(text, sizeof(text), 120, false);
  assert(std::strcmp(text, "12.0%") == 0);

  char footer[64];
  ep::footerText(footer, sizeof(footer), hill);
  assert(std::strcmp(footer, "") == 0);
  ep::footerText(footer, sizeof(footer), gaps);
  assert(std::strcmp(footer, "Partial elevation") == 0);
  assert(ep::gradeColor(0) == ep::gradeColor(2) && ep::gradeColor(7) == 0xFF372E);

  std::cout << "elevation presentation tests passed\n";
  return 0;
}
