#pragma once

#include "../renderer_diagnostics/renderer_diagnostics_policy.hpp"

namespace device_debug {

// Implemented by the GUI owner. The frame store calls this synchronously only
// at the full-panel UI flush boundary; it must never be called by HTTP tasks.
// Keep this interface free of GUI/map headers so storage does not pull the
// complete GUI library dependency graph into unrelated firmware libraries.
renderer_diagnostics::CameraSample captureMapCameraForPanelFrame();

} // namespace device_debug
