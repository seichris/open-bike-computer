#pragma once

#include <utility>

namespace ownership_ui_dispatch_policy {

// Every ownership command recognized by DeviceOwnership must publish its
// post-command UI snapshot, including Event::None failures that clear pairing.
// Keeping the return and queue ordering here makes that bridge host-testable.
template <typename Event, typename DispatchEvent, typename QueueUiSnapshot>
bool dispatchMatchedCommand(bool matched, Event event,
                            DispatchEvent &&dispatchEvent,
                            QueueUiSnapshot &&queueUiSnapshot) {
  if (!matched) {
    return false;
  }
  std::forward<DispatchEvent>(dispatchEvent)(event);
  std::forward<QueueUiSnapshot>(queueUiSnapshot)();
  return true;
}

} // namespace ownership_ui_dispatch_policy
