#!/usr/bin/env bash
# Paste this into the Claude cloud environment's Setup script field.
# VM setup runs as root on Ubuntu and is cached independently of the checkout.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  build-essential cmake ninja-build pkg-config python3-venv \
  libmbedtls-dev libfreetype6-dev shellcheck osmium-tool \
  fonts-dejavu-core fonts-noto-core fonts-noto-cjk gdal-bin postgresql

# Extract the official Swift 6.2.4 Noble image without starting a Docker daemon.
# Only swiftc is added to PATH. Keep the image's linker and libraries together.
if ! command -v swiftc >/dev/null; then
  apt-get install -y --no-install-recommends skopeo umoci
  swift_tmp=$(mktemp -d)
  trap 'rm -r "$swift_tmp"' EXIT
  swift_image=docker://docker.io/library/swift@sha256:576698469fd3cf95b2abdeb91a7571d3afcd91806c87283dd01d564803554c0f
  skopeo copy "$swift_image" "oci:$swift_tmp/image:swift"
  umoci unpack --rootless --image "$swift_tmp/image:swift" "$swift_tmp/bundle"
  install -d /opt/bicino-swift
  mv "$swift_tmp/bundle/rootfs/usr" /opt/bicino-swift/toolchain
  ln -sfn /opt/bicino-swift/toolchain/bin/swiftc /usr/local/bin/swiftc
fi
swiftc --version
