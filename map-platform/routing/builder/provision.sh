#!/bin/bash
# Create the temporary Google Cloud VM for one planet build, in a network of
# its own. Run it where gcloud is signed in.
#
#   provision.sh --job r400-261116 --ssh-source 203.0.113.7/32 --ssh-key job.pub            print the plan
#   provision.sh --job r400-261116 --ssh-source 203.0.113.7/32 --ssh-key job.pub --create   create it
#   provision.sh --job r400-261116 --host-key                                               print its SSH host key
#
#   --job NAME         names every resource bicino-valhalla-NAME
#   --ssh-source CIDR  the only address allowed to reach SSH: the map VPS
#   --ssh-key FILE     the job's Ed25519 public key, generated on the VPS
#   --project, --zone, --subnet-range   default chiho-prod, europe-west4-b, 10.247.29.0/28
#
# Without --create it only prints the commands. Creating the VM costs money
# until it is deleted, so --create needs Chris's go-ahead for that build. The
# VM deletes itself after 24 hours whatever happens; teardown.sh removes it
# and its network sooner.
set -euo pipefail

project=chiho-prod
zone=europe-west4-b
subnet_range=10.247.29.0/28
job=
ssh_source=
ssh_key=
action=plan

fail() {
  echo "error: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --job) job=${2:-}; shift 2 ;;
    --ssh-source) ssh_source=${2:-}; shift 2 ;;
    --ssh-key) ssh_key=${2:-}; shift 2 ;;
    --project) project=${2:-}; shift 2 ;;
    --zone) zone=${2:-}; shift 2 ;;
    --subnet-range) subnet_range=${2:-}; shift 2 ;;
    --create) action=create; shift ;;
    --host-key) action=host-key; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ "$job" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || fail "--job takes a short lower-case name, such as r400-261116"
name=bicino-valhalla-$job
region=${zone%-*}

if [ "$action" = host-key ]; then
  # The serial console is read through the authenticated Compute Engine API,
  # so this host key can be trusted before the first SSH connection.
  for _ in $(seq 1 30); do
    console=$(gcloud compute instances get-serial-port-output "$name" --project "$project" --zone "$zone" 2>/dev/null || true)
    if grep -q 'END SSH HOST KEY KEYS' <<<"$console"; then
      break
    fi
    sleep 10
  done
  key=$(sed -n '/BEGIN SSH HOST KEY KEYS/,/END SSH HOST KEY KEYS/p' <<<"$console" | awk '$1 == "ssh-ed25519" {print $1, $2}' | tail -1)
  [ -n "$key" ] || fail "the serial console of $name shows no Ed25519 host key yet"
  address=$(gcloud compute instances describe "$name" --project "$project" --zone "$zone" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
  [ -n "$address" ] || fail "$name has no external address"
  echo "$address $key"
  exit 0
fi

[[ "$ssh_source" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32$ ]] || fail "--ssh-source takes one IPv4 address as a /32"
[ -r "$ssh_key" ] || fail "--ssh-key takes the job's public key file"
public_key=$(cat "$ssh_key")
[[ "$public_key" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ [A-Za-z0-9._@-]+)?$ ]] || fail "$ssh_key is not one Ed25519 public key"

# run COMMAND...: print the command, and run it only with --create.
run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [ "$action" = create ]; then
    "$@"
  fi
}

run gcloud compute networks create "$name" --project "$project" --subnet-mode=custom --bgp-routing-mode=regional --quiet
run gcloud compute networks subnets create "$name" --project "$project" --network="$name" \
  --region="$region" --range="$subnet_range" --quiet
run gcloud compute firewall-rules create "$name-ssh" --project "$project" --network="$name" \
  --direction=INGRESS --allow=tcp:22 --source-ranges="$ssh_source" --target-tags=bicino-routing-builder --quiet
# c4-highmem-24-lssd brings its four 375 GiB local SSDs; setup.sh stripes them.
# No service account: the builder reads public inputs only.
run gcloud compute instances create "$name" --project "$project" --zone="$zone" \
  --machine-type=c4-highmem-24-lssd --subnet="$name" --network-tier=STANDARD \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB --boot-disk-type=hyperdisk-balanced \
  --no-service-account --no-scopes --tags=bicino-routing-builder \
  --labels=ephemeral=true,purpose=bicino-routing-builder \
  --provisioning-model=STANDARD --max-run-duration=24h --instance-termination-action=DELETE \
  --maintenance-policy=TERMINATE --no-restart-on-failure \
  --metadata="ssh-keys=bicino:$public_key" --quiet

if [ "$action" = create ]; then
  gcloud compute instances describe "$name" --project "$project" --zone "$zone" \
    --format='yaml(name,status,creationTimestamp,scheduling)'
  echo "created $name; next: provision.sh --job $job --host-key"
else
  echo "plan only: nothing was created. Add --create once the build is approved."
fi
