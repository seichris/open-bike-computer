FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    fonts-noto-cjk \
    fonts-noto-core \
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

COPY map-platform/backend /app/map-platform/backend
COPY map-platform/config /app/map-platform/config
COPY tools/OSM_Extract /app/tools/OSM_Extract

# Production advances the control-plane and worker pins independently. Keep the
# pre-relocation container paths available while either pin can still reference
# an image built before the repository layout changed.
RUN ln -s /app/map-platform/backend /app/backend \
  && ln -s /app/map-platform/config /app/config

RUN python -m pip install '/app/map-platform/backend[api,object-storage]' \
  && python -m pip install shapely "matplotlib<3.6" pyyaml

ENV PYTHONPATH=/app/map-platform/backend

RUN python /app/map-platform/backend/tools/generate_map_stream_build_identity.py \
    --repo-root /app \
    --output /app/map-platform/config/map-stream-build-identity.json

ENV MAP_PLATFORM_REPO_ROOT=/app
ENV MAP_PLATFORM_DATA_ROOT=/data
ENV MAP_PLATFORM_SOURCE_INDEX=/app/map-platform/backend/config/source-regions.json

EXPOSE 8080
CMD ["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"]
