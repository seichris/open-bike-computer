FROM ubuntu:22.04 AS brotli-security-build

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential ca-certificates cmake curl patchelf \
    && rm -rf /var/lib/apt/lists/*

# Pillow's Python 3.10 wheel bundles its own decoder. Updating Ubuntu's Brotli
# package does not update that copy. Build the ABI-compatible security release.
RUN curl -fsSL https://codeload.github.com/google/brotli/tar.gz/db24a98aed38a16de78cc05ca15cdd8dc2a0d92d -o /tmp/brotli.tar.gz \
    && echo '113b9685dfc14dd2f3360d077283266eec2fbdfb0fe3e5600f11be151da0d68e  /tmp/brotli.tar.gz' | sha256sum -c - \
    && mkdir /src \
    && tar xzf /tmp/brotli.tar.gz --strip-components=1 -C /src \
    && cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DCMAKE_INSTALL_PREFIX=/opt/brotli-security \
    && cmake --build /build --parallel 2 \
    && ctest --test-dir /build --output-on-failure \
    && cmake --install /build

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
    libexpat1 \
    libbrotli1 \
    mapnik-utils \
    osmium-tool \
    python-is-python3 \
    python3-mapnik \
    python3-pip \
    python3-yaml \
    unzip \
    zip \
  && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libbrotli1)" ge '1.0.9-2ubuntu0.1' \
  && curl -fsSL https://files.pythonhosted.org/packages/3f/06/3e4420302363fbb71be3c7f35ce042f54bfca330e3e66b3a2e3c4cca579f/pip-26.2.2-py3-none-any.whl -o /tmp/pip-26.2.2-py3-none-any.whl \
  && echo 'fd7f4dfa8190e014013b9f08f3e973f4e4c26ffd179a204895533a7254813a70  /tmp/pip-26.2.2-py3-none-any.whl' | sha256sum -c - \
  && PYTHONPATH=/tmp/pip-26.2.2-py3-none-any.whl python -m pip install --no-index --no-deps --upgrade /tmp/pip-26.2.2-py3-none-any.whl \
  && rm /tmp/pip-26.2.2-py3-none-any.whl \
  && python -m pip install --upgrade setuptools wheel \
  && rm -rf /var/lib/apt/lists/*

COPY map-platform/backend /app/map-platform/backend
COPY map-platform/config /app/map-platform/config
COPY tools/OSM_Extract /app/tools/OSM_Extract

# Production advances the control-plane and worker pins independently. Keep the
# pre-relocation container paths available while either pin can still reference
# an image built before the repository layout changed.
RUN ln -s /app/map-platform/backend /app/backend \
  && ln -s /app/map-platform/config /app/config

RUN python -m pip install '/app/map-platform/backend[api,object-storage,topography,social]' \
  && python -m pip install "matplotlib<3.6" pyyaml

COPY --from=brotli-security-build /opt/brotli-security/lib/libbrotlidec.so.1.2.1 /opt/brotli-security/libbrotlidec.so.1.2.1
COPY --from=brotli-security-build /opt/brotli-security/lib/libbrotlicommon.so.1.2.1 /opt/brotli-security/libbrotlicommon.so.1.2.1
COPY --from=brotli-security-build /usr/bin/patchelf /opt/brotli-security/patchelf
RUN python /app/map-platform/backend/tools/repair_pillow_brotli.py /opt/brotli-security

ENV PYTHONPATH=/app/map-platform/backend

RUN python /app/map-platform/backend/tools/generate_map_stream_build_identity.py \
    --repo-root /app \
    --output /app/map-platform/config/map-stream-build-identity.json

ENV MAP_PLATFORM_REPO_ROOT=/app
ENV MAP_PLATFORM_DATA_ROOT=/data
ENV MAP_PLATFORM_SOURCE_INDEX=/app/map-platform/backend/config/source-regions.json

EXPOSE 8080
CMD ["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"]
