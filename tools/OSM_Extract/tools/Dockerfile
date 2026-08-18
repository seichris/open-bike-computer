FROM ubuntu:22.04
LABEL maintainer="arestabrucs"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt update -qq && apt install -y --no-install-recommends \
    curl \
    fonts-noto-cjk \
    fonts-noto-core \
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
    cmake \
    libbz2-dev \
    libexpat1-dev \
    python3-dev \
    zlib1g-dev \
    gdal-bin \
  && pip install pillow "shapely==2.0.7" "matplotlib<3.6" pyyaml uharfbuzz freetype-py "osmium==4.3.1" \
  && rm -rf /var/lib/apt/lists/*
