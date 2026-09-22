#include "../../lib/gui/src/worldRadioGlobe.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

int main() {
  using namespace world_radio_globe;
  Coordinate coordinate{};
  assert(!coordinateForPoint(0, 0, 0, coordinate));
  assert(!coordinateForPoint(0, 0, 156, coordinate));
  assert(coordinateForPoint(78, 78, 156, coordinate));
  assert(coordinate.latitudeE7 == 0);
  assert(coordinate.longitudeE7 == 0);
  assert(coordinateForPoint(156, 78, 156, coordinate));
  assert(coordinate.latitudeE7 == 0);
  assert(coordinate.longitudeE7 == 1800000000);
  assert(coordinateForPoint(78, 0, 156, coordinate));
  assert(coordinate.latitudeE7 == 900000000);
  assert(coordinate.longitudeE7 == 0);

  for (int32_t latitude : {-900000000, 0, 900000000}) {
    for (int32_t longitude : {-1800000000, 0, 1800000000}) {
      const Point point = pointForCoordinate(latitude, longitude, 156);
      const int32_t dx = point.x - 78;
      const int32_t dy = point.y - 78;
      assert(dx * dx + dy * dy <= 72 * 72);
    }
  }
  const Point origin = pointForCoordinate(0, 0, 156);
  assert(origin.x == 78 && origin.y == 78);
  std::cout << "World Radio globe tests passed\n";
}
