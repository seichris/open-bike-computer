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
