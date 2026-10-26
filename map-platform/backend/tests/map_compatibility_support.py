"""Test-only durable-contract variants that register fixture signers.

Production code always loads the checked-in contract; tests that sign durable
maps with fixture keys register those keys explicitly instead of relaxing the
signer check.
"""
from __future__ import annotations

from dataclasses import replace

from map_platform.map_compatibility import (
    MapCompatibilityContract,
    load_map_compatibility_contract,
)


def contract_with_signers(
    *signers: tuple[str, object],
) -> MapCompatibilityContract:
    """Return the checked-in contract with only ``(channel, signer)`` keys."""
    return replace(
        load_map_compatibility_contract(),
        signers=frozenset(
            (channel, signer.key_id, signer.public_key_sha256)
            for channel, signer in signers
        ),
    )
