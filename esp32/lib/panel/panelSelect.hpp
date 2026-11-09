/**
 * @file panelSelect.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief Panel model select
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

// The board layer chooses the panel header: lib/board/panel_select.hpp
// includes the header of the panel that the board definition names. Shared
// code keeps including this file because PlatformIO's dependency finder gives
// each includer lib/panel and its dependencies' include paths for it; an
// include of lib/board alone would not, since that library is header-only.
#include "../board/panel_select.hpp"
