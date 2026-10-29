# Internal memory and task workspaces

The October 28, 2026 combined 1.75-inch test at `40caf06a` failed. Background
SDMMC operations reported allocation failures, and diagnostics recovery aborted
while newlib allocated a `FILE` mutex. A separate debug Wi-Fi attempt was refused
at 27,831/16,372 internal free/largest bytes and 20,199/16,372 DMA bytes. BLE
crypto/status observations recorded a DMA minimum of 451 free bytes and a
40-byte largest block. Those samples establish pressure, not which allocator
caused it. Periodic free-memory samples miss these peaks.

## Placement contract

On both Waveshare AMOLED targets, bounded task-only staging data uses the pinned
ESP-IDF external-BSS facility. `BICINO_TASK_DATA` is deliberately opt-in, with
compile-time checks for early PSRAM initialization, its memory test, and external
BSS support. This does not change the full-screen display buffer or refresh
strategy, trust rules, protocol sizes or file formats.

| Workspace | Failed 1.75 debug ELF bytes | Access and constraint |
| --- | ---: | --- |
| Screen configuration upload reassembler | 4,120 | BLE host task, existing mutex |
| Pending screen configuration | 4,136 | BLE/main task handoff, existing mutex |
| Outgoing screen configuration | 4,120 | Task notification pump |
| Processing configuration document | 4,096 | Main-loop task |
| Configuration slot buffer | 4,114 | Internal-stack Preferences calls, SDK flash-data bounce |
| Configuration serialized document | 4,096 | Main-loop serialization and persistence |
| Nearby view/search/layout state | 7,760 | UI task, existing renderer snapshot protocol |
| Nearby canvas pixels | 3,840 | LVGL software canvas; not the display DMA buffer |
| Diagnostics retention scan | 6,144 | Writer-task pruning only |
| Diagnostics pruning batch | 384 | Writer-task pruning only |

The six screen buffers total 24,682 bytes; Nearby adds 11,600 only in profiles
where that feature is compiled, and diagnostics adds 6,528. These are old-image symbol sizes, not measured
runtime savings or a promise that the largest DMA block grows by that amount.
The new ELF must prove each marked symbol is external. Production and debug
profiles differ and need separate resource evidence.

RTOS task stacks/control blocks, semaphores, critical-section locks, interrupt
data and DMA buffers stay internal. In particular, the 16 KiB static
`DeviceOperationOwner` stack remains internal: it performs cache-disabling
flash/NVS/FFat work. Moving the surrounding firmware-update server wholesale
would violate that requirement. The diagnostics owner separately governs
storage probing, recovery and persistent evidence under allocation failure.

## SDK startup and flash behavior

The frozen ESP-IDF 5.5.1 sources define this behavior:

- `esp_psram/Kconfig.spiram.common` requires early hardware and memory setup for
  usable external BSS. `esp_system/port/cpu_start.c` initializes PSRAM, runs its
  configured memory test, and zeroes external BSS before C++ constructors.
  `StartupConstructed` still runs and supplies nonzero defaults/sentinels.
- Enabling the SDK option also places supported vendor `lwip`, `net80211`, `pp`
  and `bt` BSS in PSRAM. This is a core/link-layout change, not only the
  application workspaces above. Build all affected profiles and inspect their
  resolved configuration and ELF; do not reuse an old core receipt.
- Arduino `esp32-hal-misc.c` and `esp32-hal-psram.c` recognize `SPIRAM_BOOT_INIT`:
  they do not repeat hardware initialization or add the heap twice.
- `spi_flash/esp_flash_api.c` copies external write data into an internal stack
  buffer before disabling cache. External reads obtain an internal bounce
  buffer and copy back after restoring cache. A failed read allocation returns
  `ESP_ERR_NO_MEM`. Existing Preferences length/readback failure checks remain;
  putting a caller's stack in PSRAM would still be unsafe.

Missing or faulty PSRAM now fails before application startup rather than using
Arduino's late-init path. Ignoring absent PSRAM is incompatible with external
BSS. These boards require working PSRAM for their intended display/map workload;
there is no claimed degraded no-PSRAM mode. Such an early failure can precede
application boot diagnostics and safe-mode bookkeeping. Retain serial capture
from power-on and the supported USB/BOOT recovery path in physical testing.

## Qualification boundaries

Diagnostics probes, chunks, catalogs and exports use checked POSIX descriptors
instead of newlib streams. The active map font, Nearby, transfer and operation
journal paths do the same. These owners retain short-I/O, EOF, close, metadata
readback and explicit fsync checks; file formats and acceptance rules do not
change. Descriptor ownership survives allocation exceptions without leaking a
handle. This removes the per-open newlib stream-lock abort, not every possible
allocation failure in the firmware.

Diagnostics defers background I/O below 4,608 DMA bytes free or a 1,024-byte
largest block, keeping events in its bounded queue and counting overflow.
This is a sample, not a memory reservation. Concurrent allocations may still
make a syscall fail. Recovery waits five seconds, then backs off to at most
60 seconds on repeated failure. Cumulative deferral counts, completed maximum
duration and minimum headroom are reported using existing diagnostic fields;
failed event admission retries the snapshot. These mechanisms still need
physical verification of recording integrity under real concurrent load.

Pre-existing local GPX import/edit stdio paths are outside this correction;
they are not claimed safe under universal out-of-memory conditions. Legacy
LovyanGFX PNG/calibration paths are excluded from the Waveshare configuration.

Keep existing internal/DMA Wi-Fi admission floors and crypto guards. Static
placement is one part of the budget; SDMMC bounce buffers, TLS, BLE authorization,
renderer allocation, diagnostics recovery and retained Wi-Fi driver resources
can overlap. Static BSS savings do not prove those peaks fit.

Required evidence includes exact-source host/fault tests, full profile CI, the
new ELF placement/size report and a separate physical sequence: cold start,
repeated BLE authentication/status, existing-map rendering, first and repeated
map/diagnostics Wi-Fi sessions, teardown/re-entry, and optional debug operation.
Record internal/DMA free and largest blocks plus minima and allocation refusal
counters, along with stack reserves and resets. Preserve diagnostics integrity,
not merely readiness. An app/firmware build is not physical acceptance.

The next staged test retains the installed Bicino Dev 1.11 (30), whose exact
source is still unknown. It is firmware-only validation. It does not qualify the
uninstalled combined app or the full durable-map upgrade contract.
