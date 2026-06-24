FROM ubuntu:20.04
LABEL maintainer="arestabrucs"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt update -qq && apt install -y --no-install-recommends \
    curl \
    git \
    wget \
    zip unzip \
    gpg-agent \
    mapnik-utils \
    python3-mapnik \
    python3-psycopg2 \
    python3-yaml \
    python-is-python3 \
    python3-queuelib \
    python3-pip \
    npm \
    osmium-tool \
    software-properties-common \
    build-essential \
    gdal-bin \
  && pip install pillow shapely "matplotlib<3.6" pyyaml \
  && rm -rf /var/lib/apt/lists/*
