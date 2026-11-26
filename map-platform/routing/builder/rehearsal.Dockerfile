# The planet builder's host tools, for rehearse.sh: Ubuntu 24.04 as on the
# builder, with a Docker client that drives the host's Docker.
FROM docker:27-cli AS docker
FROM ubuntu:24.04
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
      ca-certificates curl osmium-tool python3 time \
 && rm -rf /var/lib/apt/lists/*
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
