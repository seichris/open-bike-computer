FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    gdal-bin \
    git \
    mapnik-utils \
    osmium-tool \
    python-is-python3 \
    python3-mapnik \
    python3-pip \
    python3-yaml \
    unzip \
    zip \
  && python -m pip install --upgrade pip setuptools wheel \
  && rm -rf /var/lib/apt/lists/*

COPY backend /app/backend
COPY OSM_Extract /app/OSM_Extract

RUN python -m pip install /app/backend[api] \
  && python -m pip install pillow shapely "matplotlib<3.6" pyyaml

ENV MAP_PLATFORM_REPO_ROOT=/app
ENV MAP_PLATFORM_DATA_ROOT=/data
ENV MAP_PLATFORM_SOURCE_INDEX=/app/backend/config/source-regions.json

EXPOSE 8080
CMD ["uvicorn", "map_platform.api:app", "--host", "0.0.0.0", "--port", "8080"]
