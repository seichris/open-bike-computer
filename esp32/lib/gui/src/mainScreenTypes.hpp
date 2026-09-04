#pragma once

/**
 * Visible main-screen roots. Values are firmware-internal and intentionally
 * separate from the stable DeviceScreenSetting wire IDs.
 */
enum tileName {
  COMPASS = 0,
  MAP = 1,
  NAV = 2,
  SATTRACK = 3,
  RIDESTATS = 4,
  MAP_GUIDANCE = 5,
  BATTERY_STATUS = 6,
  WORLD_RADIO = 7,
};
