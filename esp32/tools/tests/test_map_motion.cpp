#include "../../lib/maps/src/mapMotion.hpp"

#include <cassert>
#include <cmath>

int main() {
  map_motion::PositionPresenter position;
  const auto initial = position.update({0.0, 0.0}, 0);
  assert(initial.x == 0.0 && initial.y == 0.0);

  // A new fix is presented between frames instead of being teleported to the
  // next raw coordinate. The bounded prediction continues briefly, then the
  // display converges back to the measured target.
  position.update({10.0, 0.0}, 1000);
  const auto inBetween = position.update({10.0, 0.0}, 1030);
  assert(inBetween.x > 0.0 && inBetween.x < 10.0);
  for (uint32_t time = 1060; time <= 3000; time += 30) {
    position.update({10.0, 0.0}, time);
  }
  const auto settled = position.update({10.0, 0.0}, 3000);
  assert(std::fabs(settled.x - 10.0) < 0.1);

  map_motion::HeadingPresenter heading;
  assert(heading.update(359.0, 0, 1) == 359);
  const uint16_t wrapped = heading.update(1.0, 30, 1);
  assert(wrapped == 0 || wrapped == 1 || wrapped == 359);
  assert(heading.update(90.0, 30, 1) == wrapped);
  heading.reset();
  assert(heading.update(90.0, 1000, 2) == 90);

  return 0;
}
