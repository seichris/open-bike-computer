# Dedicated promotion scheduler. Preserve the approved immutable converter,
# signer, validation rules and producer identity byte-for-byte.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:d8b9d172d657cbfa7298e970968b64520c6b3d00f8dcb28758bab8f8cef3a9b9 AS production-base
FROM production-base AS runtime
COPY map-platform/backend/map_platform/automatic_promotion.py /opt/bicino-promotion/automatic_promotion.py
LABEL org.bicino.release-profile="production-map-promotion" \
      org.bicino.converter-image="ghcr.io/seichris/open-bike-computer-map-platform@sha256:d8b9d172d657cbfa7298e970968b64520c6b3d00f8dcb28758bab8f8cef3a9b9" \
      org.bicino.base-source="8104250ca68499a50c9ec68b9102f13fe1ab5965"
ENTRYPOINT ["python", "/opt/bicino-promotion/automatic_promotion.py"]
CMD []

FROM runtime AS validation
COPY --from=production-base /app /opt/promotion-base-app
COPY map-platform/backend/tests/test_automatic_promotion.py /opt/promotion-tests/test_automatic_promotion.py
COPY map-platform/backend/tests/test_catalog_promotion.py /opt/promotion-tests/test_catalog_promotion.py
COPY map-platform/deploy/promotion/test_runtime.py /opt/promotion-tests/test_runtime.py
RUN PROMOTION_SCHEDULER_SOURCE=/opt/bicino-promotion/automatic_promotion.py python -m unittest discover -s /opt/promotion-tests
