#!/usr/bin/env bash
# Paste this into the Claude cloud environment's Setup script field.
# VM setup runs as root on Ubuntu and is cached independently of the checkout.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  build-essential cmake ninja-build pkg-config python3-venv \
  libmbedtls-dev libfreetype6-dev shellcheck
