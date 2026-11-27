#!/bin/bash
# Let planet builders read the bucket of kept elevation tiles, and nothing
# else. Run it where gcloud is signed in.
#
#   cache-access.sh            print the plan
#   cache-access.sh --create   create the service account and the grant
#   cache-access.sh --show     print who may read the bucket now
#
#   --project, --bucket, --account   default chiho-prod, bicino-routing-elevation,
#                                    bicino-routing-builder
#
# It creates one service account without any role in the project and grants
# it roles/storage.objectViewer on the one bucket: it can list and read that
# bucket's objects and cannot write, overwrite or delete them. No key is made:
# a builder created with `provision.sh --cache-reader EMAIL` gets short-lived
# tokens from its metadata server, and they end with the builder.
#
# The account and the grant stay until someone removes them, and cost nothing.
# Creating them changes who can read the project's data, so --create needs
# Chris's go-ahead once.
set -euo pipefail

project=chiho-prod
bucket=bicino-routing-elevation
account=bicino-routing-builder
action=plan

fail() {
  echo "error: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) project=${2:-}; shift 2 ;;
    --bucket) bucket=${2:-}; shift 2 ;;
    --account) account=${2:-}; shift 2 ;;
    --create) action=create; shift ;;
    --show) action=show; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ "$project" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || fail "--project takes a project id"
[[ "$bucket" =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || fail "--bucket takes a bucket name"
[[ "$account" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || fail "--account takes a service account id of 6 to 30 characters"
email=$account@$project.iam.gserviceaccount.com

if [ "$action" = show ]; then
  gcloud storage buckets get-iam-policy "gs://$bucket" --project "$project"
  exit 0
fi

# run COMMAND...: print the command, and run it only with --create.
run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [ "$action" = create ]; then
    "$@"
  fi
}

run gcloud iam service-accounts create "$account" --project "$project" \
  --display-name="Planet builder: reads the kept elevation tiles" \
  --description="Read-only on gs://$bucket. No key; used by temporary builders through their metadata server."
run gcloud storage buckets add-iam-policy-binding "gs://$bucket" --project "$project" \
  --member="serviceAccount:$email" --role=roles/storage.objectViewer

if [ "$action" = create ]; then
  echo "created $email; next: provision.sh ... --cache-reader $email"
else
  echo "plan only: nothing was created. Add --create once Chris has agreed."
  echo "builders would then be created with: provision.sh ... --cache-reader $email"
fi
