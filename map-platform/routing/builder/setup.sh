#!/bin/bash
# Prepare a fresh planet builder and start the build chain. Run it on the
# builder as user bicino, piped over SSH so nothing has to be copied first:
#
#   ssh -F CONFIG builder 'bash -s -- --commit SHA --planet-date 261116 --opening-radius 400 --start' \
#     < map-platform/routing/builder/setup.sh
#
#   --commit SHA               the open-bike-computer commit whose tools run (40 hex digits)
#   --planet-date YYMMDD       the planet snapshot, planet-YYMMDD.osm.pbf
#   --opening-radius METRES    grade a second graph with Copernicus opened at this
#                              radius and run the gate; without it only the
#                              ungraded planet is built
#   --map-platform-image REF   another digest-pinned map-platform image
#   --start                    start the chain when everything is in place
#
# It is safe to run again: finished steps are skipped.
set -euo pipefail

scratch=/srv/bicino-routing-scratch
repository=https://github.com/seichris/open-bike-computer.git
commit=
planet_date=
opening_radius=
image=
start=()

fail() {
  echo "error: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --commit) commit=${2:-}; shift 2 ;;
    --planet-date) planet_date=${2:-}; shift 2 ;;
    --opening-radius) opening_radius=${2:-}; shift 2 ;;
    --map-platform-image) image=${2:-}; shift 2 ;;
    --start) start=(--start); shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "--commit takes a full commit SHA"
[[ "$planet_date" =~ ^[0-9]{6}$ ]] || fail "--planet-date takes YYMMDD"
[[ -z "$opening_radius" || "$opening_radius" =~ ^[0-9]{2,4}$ ]] || fail "--opening-radius takes whole metres"
[ "$(id -un)" = bicino ] || fail "run setup.sh as user bicino; the units run as that user"
sudo -n true || fail "user bicino needs sudo without a password"

# 1. No package upgrades beside a build, before anything else. On 2026-11-26
#    apt-daily-upgrade ran 38 minutes after boot and needrestart restarted
#    the running build units. Stop new runs, let a running one finish (ending
#    it would leave dpkg half configured), then mask the services too.
echo "== masking package upgrades"
sudo systemctl mask --now apt-daily.timer apt-daily-upgrade.timer
if command -v cloud-init >/dev/null 2>&1; then
  sudo cloud-init status --wait >/dev/null 2>&1 || true
fi
# A running oneshot service is "activating", which `systemctl is-active` calls inactive.
unit_is_busy() {
  case "$(systemctl show --property=ActiveState --value "$1")" in
    activating|active|reloading|deactivating) return 0 ;;
    *) return 1 ;;
  esac
}
for unit in apt-daily.service apt-daily-upgrade.service; do
  for _ in $(seq 1 180); do
    unit_is_busy "$unit" || break
    sleep 5
  done
  ! unit_is_busy "$unit" || fail "$unit is still running after 15 minutes"
done
sudo systemctl mask --now apt-daily.service apt-daily-upgrade.service unattended-upgrades.service
echo 'APT::Periodic::Enable "0";' | sudo tee /etc/apt/apt.conf.d/99bicino-builder >/dev/null
sudo mkdir -p /etc/needrestart/conf.d
# List services that want a restart; never restart one.
echo "\$nrconf{restart} = 'l';" | sudo tee /etc/needrestart/conf.d/90-bicino-builder.conf >/dev/null

# 2. Packages.
echo "== installing packages"
export DEBIAN_FRONTEND=noninteractive
sudo dpkg --configure -a
sudo -E apt-get -o DPkg::Lock::Timeout=600 update -q >/dev/null
sudo -E apt-get -o DPkg::Lock::Timeout=600 install -y -q \
  docker.io osmium-tool mdadm rsync curl time python3 git >/dev/null
sudo usermod -aG docker bicino

# 3. One striped scratch volume over the four 375 GiB local SSDs. The boot
#    disk is smaller and never matches.
if mountpoint -q "$scratch"; then
  echo "== scratch is already mounted"
else
  echo "== striping the local SSDs"
  mapfile -t disks < <(lsblk -dn -o NAME,SIZE | awk '$2 == "375G" {print "/dev/" $1}' | sort)
  [ "${#disks[@]}" -eq 4 ] || fail "expected 4 local SSDs of 375G, found ${#disks[@]}: ${disks[*]:-none}"
  for disk in "${disks[@]}"; do
    [ -z "$(lsblk -no MOUNTPOINT "$disk" | tr -d '[:space:]')" ] || fail "$disk is mounted"
    [ -z "$(sudo wipefs -n "$disk")" ] || fail "$disk is not blank"
  done
  sudo mdadm --create /dev/md0 --level=0 --raid-devices=4 "${disks[@]}" --run --quiet
  sudo mkfs.ext4 -q -F -m 0 -E lazy_itable_init=1,lazy_journal_init=1 /dev/md0
  sudo mkdir -p "$scratch"
  sudo mount -o noatime /dev/md0 "$scratch"
fi
sudo chown bicino:bicino "$scratch"
mkdir -p "$scratch"/{input,build,export,tools,elevation-raw,elevation,audit}
chmod 755 "$scratch" "$scratch/export"

# 4. The tools, at exactly the commit asked for. Git checks every object
#    against its hash, so the checkout is that commit or the fetch fails.
echo "== fetching the tools at $commit"
repo=$scratch/tools/repo
if [ ! -d "$repo/.git" ]; then
  git init -q "$repo"
  git -C "$repo" remote add origin "$repository"
  git -C "$repo" sparse-checkout set map-platform
fi
git -C "$repo" fetch -q --depth 1 --filter=blob:none origin "$commit"
git -C "$repo" checkout -q --detach FETCH_HEAD
[ "$(git -C "$repo" rev-parse HEAD)" = "$commit" ] || fail "the checkout is not $commit"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "the checkout has local changes"
builder=$repo/map-platform/routing/builder

# 5. The run's settings, which systemd and the scripts both read.
env_file=$scratch/builder.env
{
  echo "BICINO_TOOLS_COMMIT=$commit"
  echo "BICINO_PLANET_DATE=$planet_date"
  echo "BICINO_OPENING_RADIUS=$opening_radius"
  if [ -n "$image" ]; then
    echo "BICINO_MAP_PLATFORM_IMAGE=$image"
  fi
} > "$env_file"
if [ -z "$image" ]; then
  # Record the default image too, so the result names the one that ran.
  # shellcheck source=config.sh
  image=$(. "$builder/config.sh" && echo "$BICINO_MAP_PLATFORM_IMAGE")
  echo "BICINO_MAP_PLATFORM_IMAGE=$image" >> "$env_file"
fi
# shellcheck source=config.sh
(. "$builder/config.sh" && bicino_validate_run)
cat "$scratch/builder.env"

df -h "$scratch" | tail -1
osmium --version | head -1
docker --version

# 6. The chain.
sudo "$builder/install-chain.sh" "${start[@]}"
