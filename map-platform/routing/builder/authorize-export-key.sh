#!/bin/bash
# Let one SSH key read the builder's export folder with rsync, and nothing else.
#
#   sudo authorize-export-key.sh < transfer-key.pub
#
# The key belongs to a user of its own, bicino-export, whose only permitted
# command is a read-only rrsync rooted at export/. The VPS pulls the result,
# the logs and an approved archive with it (stage_graph.py --source
# bicino-export@HOST:ungraded/valhalla_tiles.tar).
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

[ "$(id -u)" -eq 0 ] || bicino_fail "run authorize-export-key.sh as root"
rrsync=$(command -v rrsync) || bicino_fail "rrsync is not installed (it comes with the rsync package)"
IFS= read -r public_key || true
[[ "$public_key" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ [A-Za-z0-9._@-]+)?$ ]] \
  || bicino_fail "stdin must hold one Ed25519 public key"

user=bicino-export
if ! id "$user" >/dev/null 2>&1; then
  useradd --system --create-home --shell /bin/sh "$user"
fi
home=$(getent passwd "$user" | cut -d: -f6)
install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
printf 'command="%s -ro %s",restrict %s\n' "$rrsync" "$BICINO_EXPORT" "$public_key" > "$home/.ssh/authorized_keys"
chown "$user:$user" "$home/.ssh/authorized_keys"
chmod 0600 "$home/.ssh/authorized_keys"
echo "$user may now read $BICINO_EXPORT with rsync, and nothing else."
