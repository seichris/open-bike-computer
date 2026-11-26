#!/bin/bash
# Delete a planet builder and its network, then prove nothing is left.
#
#   teardown.sh --job r400-261116            print the plan
#   teardown.sh --job r400-261116 --delete   delete it and check
#
# Deleting the VM destroys its scratch volume: both archives, the elevation
# tiles and every log that was not pulled. Pull export/ to the VPS first.
set -euo pipefail

project=chiho-prod
zone=europe-west4-b
job=
action=plan

fail() {
  echo "error: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --job) job=${2:-}; shift 2 ;;
    --project) project=${2:-}; shift 2 ;;
    --zone) zone=${2:-}; shift 2 ;;
    --delete) action=delete; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ "$job" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || fail "--job takes the name the builder was provisioned with"
name=bicino-valhalla-$job
region=${zone%-*}

# run COMMAND...: print the command, and run it only with --delete. A
# resource that is already gone must not stop the rest.
run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [ "$action" = delete ]; then
    "$@" || echo "  (failed or already gone)"
  fi
}

run gcloud compute instances delete "$name" --project "$project" --zone "$zone" --quiet
run gcloud compute firewall-rules delete "$name-ssh" --project "$project" --quiet
run gcloud compute networks subnets delete "$name" --project "$project" --region "$region" --quiet
run gcloud compute networks delete "$name" --project "$project" --quiet

if [ "$action" != delete ]; then
  echo "plan only: nothing was deleted. Add --delete to run it."
  exit 0
fi

# remaining KIND COMMAND...: the names the listing still shows. A listing that
# fails must never read as "gone".
remaining() {
  local kind=$1 names item
  shift
  names=$("$@") || fail "could not list the ${kind}s of $project; check them by hand"
  if [ -n "$names" ]; then
    while IFS= read -r item; do
      echo "$kind $item"
    done <<<"$names"
  fi
}
left=$(
  remaining instance gcloud compute instances list --project "$project" --filter="name=$name" --format='value(name)'
  remaining disk gcloud compute disks list --project "$project" --filter="name~^$name" --format='value(name)'
  remaining "firewall rule" gcloud compute firewall-rules list --project "$project" --filter="name~^$name" --format='value(name)'
  remaining subnet gcloud compute networks subnets list --project "$project" --filter="name=$name" --format='value(name)'
  remaining network gcloud compute networks list --project "$project" --filter="name=$name" --format='value(name)'
)
if [ -n "$left" ]; then
  echo "still there:" >&2
  echo "$left" >&2
  exit 1
fi
echo "$name, its disks, firewall rule, subnet and network are gone."
echo "Now remove the job's key and SSH configuration from the VPS (/root/.ssh/$name*)."
