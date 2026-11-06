# Dedicated promotion scheduler. Preserve the approved immutable converter,
# signer, validation rules and producer identity byte-for-byte.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:d43949528703c4e7319ce0907f16ca00c9dde425ee085e90ef2bc183bbf85e00 AS production-base
FROM production-base AS runtime
COPY map-platform/backend/map_platform/automatic_promotion.py /opt/bicino-promotion/automatic_promotion.py
LABEL org.bicino.release-profile="production-map-promotion" \
      org.bicino.converter-image="ghcr.io/seichris/open-bike-computer-map-platform@sha256:d43949528703c4e7319ce0907f16ca00c9dde425ee085e90ef2bc183bbf85e00" \
      org.bicino.base-source="8baaf9804ebba273cfce3a7397ec6db341f49260"
ENTRYPOINT ["python", "/opt/bicino-promotion/automatic_promotion.py"]
CMD []

FROM runtime AS validation
COPY --from=production-base /app /opt/promotion-base-app
COPY map-platform/backend/tests/test_automatic_promotion.py /opt/promotion-tests/test_automatic_promotion.py
COPY map-platform/backend/tests/test_catalog_promotion.py /opt/promotion-tests/test_catalog_promotion.py
COPY map-platform/deploy/promotion/test_runtime.py /opt/promotion-tests/test_runtime.py
RUN PROMOTION_SCHEDULER_SOURCE=/opt/bicino-promotion/automatic_promotion.py python -m unittest discover -s /opt/promotion-tests
