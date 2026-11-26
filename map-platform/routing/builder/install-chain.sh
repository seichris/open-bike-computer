#!/bin/bash
# Install the chain's systemd units on the builder and, with --start, start it.
#
#   sudo /srv/bicino-routing-scratch/tools/repo/map-platform/routing/builder/install-chain.sh [--start]
#
# Starting it again after a failure runs the failed stage and everything
# after it; stages that are done stay done.
set -euo pipefail
# shellcheck source=config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

start=0
case "${1:-}" in
  --start) start=1 ;;
  '') ;;
  *) bicino_fail "usage: install-chain.sh [--start]" ;;
esac
[ "$(id -u)" -eq 0 ] || bicino_fail "run install-chain.sh as root"
# The unit files name this path; they are installed as they are checked in.
[ "$BICINO_SCRATCH" = /srv/bicino-routing-scratch ] || bicino_fail "the units expect /srv/bicino-routing-scratch"
[ -s "$BICINO_SCRATCH/builder.env" ] || bicino_fail "no $BICINO_SCRATCH/builder.env; setup.sh writes it"
bicino_validate_run
id bicino >/dev/null 2>&1 || bicino_fail "the units run as user bicino, who does not exist"
sudo -u bicino docker info >/dev/null 2>&1 || bicino_fail "user bicino cannot reach Docker"
# A build must never share the machine with a package upgrade (setup.sh).
for unit in apt-daily.timer apt-daily-upgrade.timer; do
  [ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" = masked ] || bicino_fail "$unit is not masked; run setup.sh first"
done

install -m 0644 "$BICINO_BUILDER"/units/bicino-planet-*.service /etc/systemd/system/
systemctl daemon-reload
systemctl reset-failed 'bicino-planet-*' 2>/dev/null || true
systemctl start bicino-planet-sampler.service
echo "installed: $(cd "$BICINO_BUILDER/units" && echo bicino-planet-*.service)"
if [ "$start" -eq 1 ]; then
  systemctl start --no-block bicino-planet-result.service
  echo "chain started at $(bicino_now)"
fi
sudo -u bicino BICINO_SCRATCH="$BICINO_SCRATCH" python3 "$BICINO_BUILDER/chain_state.py" status
