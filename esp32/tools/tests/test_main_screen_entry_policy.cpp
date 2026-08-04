#include "../../lib/gui/src/mainScreenEntryPolicy.hpp"

#include <cassert>
#include <vector>

int main() {
  std::vector<int> calls;
  main_screen_entry_policy::enter(
      [&]() { calls.push_back(1); }, [&]() { calls.push_back(2); });
  assert((calls == std::vector<int>{1, 2}));
  return 0;
}
