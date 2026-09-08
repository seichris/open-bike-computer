# PR #424 current-main integration

Reviewed main: `25b6352e69c39af66369743b57dd6f76c92c5e91`.
Published integration: `71a896d39c4b97c8e0580f29a1f3321c48e9258f`.
Reviewed integration tree: `ebf90e5e18d11de555e38be1ba51e3086ae5fa22`.

The existing branch was updated without force-pushing. It preserves the newer
#422 boot-confirmation sequence and the intervening CI dependency updates.
Recorder-ready reporting follows startup completion, successful running-image
confirmation, and boot-ready publication. The old early-confirmation block was
not restored.

The earlier review comment about 13 CHECK macro errors in
`test_vector_runtime.cpp` is withdrawn: this file does not exist at the reviewed
head. The actual ownership executable is `esp32/tools/tests/test_runtime_ownership.cpp`.

Fresh Linux-host evidence:

- Threaded ownership/socket-lease/allocation executable: passed.
- Ownership source-contract suite, including the new boot-order regression: 8 passed.
- Root tooling: 97 passed; current-main workflow tests: 78 passed.
- Generated BLE contract and whitespace checks: passed.
- Additional unmodified CI host steps passed: ride diagnostics/watchdog,
  render-ahead map architecture, capabilities protocol, controller lease and
  scoped Watch delivery, and real map-transfer tests.
- Full firmware Python discovery ran 455 tests but was not green locally:
  `zxingcpp` is absent, preventing import of the pre-connection asset test module.
  No assertion failure was observed. Required CI must install the pinned asset
  dependencies and rerun all required steps.

The isolated publishing job reproduced the exact reviewed tree and reran the
ownership executable, all eight source-contract tests, and generated-contract
verification before updating the branch. This documentation commit requests the
normal PR CI at the resulting head; no future CI result is asserted here.

No physical device was accessed, flashed, updated by OTA, or deployed. No release
was created. Historical firmware builds are not fresh integration builds.

**Merge gate:** production-enabled hardware paths still require the separate
1.75-inch and 2.06-inch physical qualification recorded in the implementation
ledger, or explicit and recorded maintainer acceptance of residual hardware
risk under AGENTS.md. A general request to merge is not treated as that exception.

## Fresh integration fixes and validation

The actual production CI failure at c6210f58 is a size overrun: 3,151,379
program bytes and a 3,151,920-byte binary exceed the 3,145,728-byte partition.
The historical test_vector_runtime.cpp / CHECK diagnosis is invalid: that file
and literal test/test-maps targets are absent from both cited and current trees.

A new host test executes the exact production executeRollback callback with a
storage boundary that throws after successful rollback. It reproduced false
restoration success. The catch now clears succeeded before publishing completion;
the regression passes and is explicitly wired into normal host CI.

Error-result construction now uses shared non-inlined overloads: literal codes
and messages are constructed at one call site, and dynamic messages move into
the result. Error text, partition layout, enabled features and allocation
failure behavior are preserved. A first move-only version saved 2,356 program
bytes but was still oversized; the literal overload version requires the final
clean build size check before publication or merge.

Passed locally after fixes: 459 firmware Python tests; 97 root tooling tests;
78 workflow tests; native runtime ownership, map transfer, stream format/install,
renderer and other prescribed host steps, using private Mbed TLS 2.28.10.
No board flashing, serial access, deployment or physical qualification occurred.
The connected 1.75 model was confirmed before build-only work. Physical gates
for both board families remain open; no residual-risk exception is inferred.
