#pragma once

// PlatformIO preincludes this file before NimBLE-Arduino and application
// sources. Including sdkconfig.h first consumes its generated definition; the
// project-wide replacement below therefore remains authoritative for the rest
// of each translation unit.
#include <sdkconfig.h>

#ifdef CONFIG_BT_NIMBLE_MAX_CONNECTIONS
#undef CONFIG_BT_NIMBLE_MAX_CONNECTIONS
#endif
#define CONFIG_BT_NIMBLE_MAX_CONNECTIONS 1

// The device is a BLE peripheral and broadcaster only: it never scans for or
// connects to other devices. Compiling the central and observer roles out of
// NimBLE-Arduino drops the GATT client, scan and remote-attribute code from
// every image. The generated sdkconfig enables both roles and also carries
// the legacy CONFIG_NIMBLE_ROLE_* aliases, which nimconfig_rename.h would turn
// back into the current names, so both spellings are consumed here and
// nimconfig.h is told not to re-enable the roles through its *_DISABLED
// switches. The port then derives MYNEWT_VAL_BLE_ROLE_CENTRAL/OBSERVER as 0.
#undef CONFIG_BT_NIMBLE_ROLE_CENTRAL
#undef CONFIG_NIMBLE_ROLE_CENTRAL
#define CONFIG_BT_NIMBLE_ROLE_CENTRAL_DISABLED 1

#undef CONFIG_BT_NIMBLE_ROLE_OBSERVER
#undef CONFIG_NIMBLE_ROLE_OBSERVER
#define CONFIG_BT_NIMBLE_ROLE_OBSERVER_DISABLED 1
