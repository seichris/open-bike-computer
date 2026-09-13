#include "../../lib/gui/src/worldRadioViewport.hpp"

#include <cassert>
#include <iostream>

int main() {
  using namespace world_radio_viewport;
  for (int width : {466, 410}) {
    const int height = width == 466 ? 466 : 502;
    Camera camera;
    camera.configure(width, height, 2048, 1024);
    assert(camera.anchorX() == width / 2 && camera.anchorY() == height / 2);
    camera.centerOn(0, 0);
    const int x = camera.x();
    const int y = camera.y();
    // Content follows the finger, with neither inversion nor amplification.
    camera.pan(37, 23);
    assert(camera.x() == x + 37);
    assert(camera.y() == y + 23);
    camera.pan(-37, -23);
    assert(camera.x() == x && camera.y() == y);
    camera.drag(37, 23);
    assert(camera.x() == x + 37 && camera.y() == y + 23);
    camera.drag(-37, -23);
    assert(camera.x() == x && camera.y() == y);
    for (int i = 0; i < 40; ++i) camera.pan(1, -1);
    assert(camera.x() == x + 40 && camera.y() == y - 40);

    camera.pan(0, 100000);
    assert(camera.y() == 0);
    camera.pan(0, -1);
    assert(camera.y() == -1); // No accumulated overscroll/sticky edge.
    camera.pan(0, -100000);
    assert(camera.y() + 1024 == height);
    camera.pan(0, 1);
    assert(camera.y() + 1024 == height + 1);
    for (int longitude : {-1800000000, 0, 1800000000}) {
      for (int latitude : {-900000000, 0, 900000000}) {
        camera.centerOn(latitude, longitude);
        assert(camera.y() <= 0);
        assert(camera.y() + 1024 >= height);
        assert(camera.x() <= 0 && camera.x() + 4096 >= width);
      }
    }
    camera.centerOn(0, 1790000000);
    const int32_t before = camera.longitude();
    camera.pan(-30, 0);
    assert(before > 0 && camera.longitude() < 0);
    assert(camera.latitude() == 0);
  }
  assert(!mayFocusStation(true, 10, 5, 10, 6));
  assert(!mayFocusStation(false, 0, 5, 10, 6));
  assert(!mayFocusStation(false, 10, 5, 9, 6));
  assert(!mayFocusStation(false, 10, 5, 10, 5));
  assert(mayFocusStation(false, 10, 5, 10, 6));
  std::cout << "World Radio viewport tests passed\n";
}
