# Main-screen architecture

`mainScr.cpp` historically owned screen IDs, cycle order, settings mappings,
root-object visibility, and each screen's implementation. That made every new
screen a cross-cutting edit and encouraged more globals and switch statements.

World Radio starts an incremental migration rather than a risky rewrite of all
existing screens.

## Registry

`mainScreenRegistry.hpp` is the source of truth for stable device-screen IDs,
cycle order, internal tile mapping, and whether a screen is map-backed. It is a
pure header with host tests, so settings compatibility and cycle behavior can
be validated without LVGL or hardware.

Wire IDs remain separate from internal `tileName` values. Static assertions in
`mainScr.cpp` prevent the registry and BLE contract from drifting.

## Screen modules

A new screen should own its LVGL objects, events, local presentation state, and
create/update/activate entry points in its own `*Scr.cpp` module. The main
screen supplies narrow callbacks for application actions; the module must not
reach into BLE, storage, or network managers directly.

Background work publishes immutable snapshots. Only the LVGL task reads those
snapshots and mutates visible objects. A stable update with no changed revision
must be a no-op.

## Adding the next screen

1. Allocate a stable `DeviceScreenSetting` wire ID and capability when the
   screen depends on a companion-app feature.
2. Add one descriptor to `mainScreenRegistry.hpp`.
3. Implement a self-contained screen module with bounded callbacks.
4. Add the iOS settings case and migration for existing users.
5. Add registry, protocol, and module-state host tests.
6. Validate both Waveshare firmware profiles and the iOS build.

Future PRs can migrate the legacy screens behind the same module interface one
at a time. Once all roots are registered, the remaining `showMainTile` switch
can become descriptor callbacks without changing the stable settings protocol.
