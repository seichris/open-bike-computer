# Firmware host runtime

Ordinary firmware builds consume only an accepted, content-pinned bundle from
`lock-v1.json`. A bundle contains an extracted CPython 3.13 runtime, exact
PlatformIO/uv executables, their complete installed distributions, the
pioarduino root and ESP-IDF Python closures, and a canonical per-file inventory.

The current lock is deliberately a candidate: its standalone-Python inputs are
pinned, but no bundle is accepted until the manual refresh workflow has built
both board targets on Linux x86-64 and macOS arm64, replayed them offline, and
published immutable release assets. Ordinary builds fail closed while a target
is unaccepted; they never fall back to ambient Python packages or PlatformIO.

The manual workflow currently validates the strict schemas and downloads and
rehashes each target's pinned standalone-Python bootstrap. It does not yet
produce an accepted closure: exact transitive wheel metadata, root pioarduino
and ESP-IDF environment inventories, offline clean/warm/tamper builds, license
evidence, and immutable release publication remain acceptance gates. Neither a
workflow artifact nor an Actions cache is an accepted runtime URL.

Maintainers run `.github/workflows/firmware-runtime-refresh.yml`, inspect its
dependency graph, licenses, clean/warm/tamper evidence and bundle inventories,
publish the reviewed assets without replacing them, and then commit their exact
URLs, sizes and SHA-256 values with `accepted: true`.
