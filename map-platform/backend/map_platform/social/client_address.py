"""Client network identity for limits on requests that carry no account token.

Only the TCP peer is trusted by default. `X-Forwarded-For` is read only when that
peer is a configured trusted proxy, and then right to left: each trusted proxy
appends the address it received the request from, so the nearest address that
is not itself a trusted proxy is the client. Entries a client writes itself sit
further left and are never reached, so forging the header cannot select another
client's bucket. IPv6 clients share one bucket per /64, the smallest prefix a
single subscriber is normally assigned.
"""
from __future__ import annotations

import hashlib
import ipaddress
import os


class ClientAddressPolicy:
    def __init__(self, trusted_proxies: str = ""):
        self.trusted = tuple(ipaddress.ip_network(value.strip(), strict=False)
                             for value in trusted_proxies.split(",") if value.strip())

    @classmethod
    def from_environment(cls):
        # Invalid configuration fails startup instead of silently trusting nobody.
        return cls(os.environ.get("BICINO_SOCIAL_TRUSTED_PROXIES", ""))

    def _is_trusted(self, address) -> bool:
        return any(address in network for network in self.trusted)

    @staticmethod
    def _parse(value):
        try:
            address = ipaddress.ip_address(value.strip())
        except ValueError:
            return None
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
            return address.ipv4_mapped
        return address

    def client(self, scope):
        """The client address for this request, or None when the peer is not an IP."""
        peer = self._parse((scope.get("client") or ("", 0))[0])
        if peer is None or not self._is_trusted(peer):
            return peer
        forwarded = []
        for name, value in scope.get("headers") or []:
            if name.lower() == b"x-forwarded-for":
                forwarded.extend(value.decode("latin-1").split(","))
        address = peer
        for entry in reversed(forwarded):
            candidate = self._parse(entry)
            if candidate is None:
                break  # A malformed hop stops the walk at the last address a trusted proxy vouched for.
            address = candidate
            if not self._is_trusted(candidate):
                break
        return address

    def bucket(self, scope) -> str:
        """A stable, non-reversible-at-a-glance limiter key for the client network."""
        address = self.client(scope)
        if address is None:
            network = "unknown-peer"
        elif address.version == 6:
            network = str(ipaddress.ip_network(f"{address}/64", strict=False))
        else:
            network = str(address)
        # Limiter rows outlive a request briefly; store a digest, not the address.
        return hashlib.sha256(network.encode()).hexdigest()[:32]
