#pragma once

#include "position_source.hpp"

// The GNSS receiver side of the position-source part. gnss_receiver.cpp holds
// the real implementation where the board file sets BOARD_GNSS_FITTED and
// no-op stubs elsewhere, so the shared part links on every board.
namespace position_source::gnss_receiver {

void begin();
void startTask();
GnssStatus status();

}  // namespace position_source::gnss_receiver
