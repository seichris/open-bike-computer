# Firmware 0.3.5 build 108 candidate

The last public firmware is 0.3.4 build 107 at `v0.3.4-release.15`.
The next release allocates build 108 for the 1.75-inch and 2.06-inch
production profiles.

## Rider-facing changes

- Siri and Shortcuts can switch Bicino One screens through the iPhone
  when the connected firmware advertises screen activation (#807, #842).
- The release includes BLE recovery, navigation, ride totals, and map
  installation fixes from the intervening firmware changes.

## Before tagging

- [ ] CI Gate passes for the exact source candidate.
- [ ] Both production OTA images satisfy the GitHub release size and
  partition checks.
- [ ] Record exact production-image hardware acceptance for each applicable
  release gate, or any candidate-specific maintainer decision the repository
  permits. The 1.75-inch Siri result in #842 used a developer profile.
- [ ] Verify the published-tag and build history and confirm that the
  publisher's environment and signing controls pass preflight.

Use the repository's [factory release workflow](../firmware-factory-release.md).
Do not admit a migration image based on this release alone. Keep the
partition migration's independent hardware gates in force.
