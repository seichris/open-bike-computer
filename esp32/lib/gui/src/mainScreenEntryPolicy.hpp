/**
 * @file mainScreenEntryPolicy.hpp
 * @brief Host-testable orchestration for the first configured main-screen render.
 */

#pragma once

#include <utility>

namespace main_screen_entry_policy {

// Main-screen entry must center the map before asking the configured screen to
// select its own profile and schedule the one initial render. Keeping the
// sequence here prevents a hard-coded flat Map render from flashing before a
// configured Map + Navigation bird's-eye render.
template <typename CenterMap, typename ShowConfiguredScreen>
void enter(CenterMap &&centerMap, ShowConfiguredScreen &&showConfiguredScreen) {
  std::forward<CenterMap>(centerMap)();
  std::forward<ShowConfiguredScreen>(showConfiguredScreen)();
}

} // namespace main_screen_entry_policy
