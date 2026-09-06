# Dedicated promotion scheduler. Preserve the qualified production converter,
# signer, validation rules and producer identity byte-for-byte.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:142957ae0d5f08d366b657f9bacb0ce17d85bfac9c5d98c644bc1b02188a59c8 AS production-base
FROM production-base AS runtime
COPY map-platform/backend/map_platform/automatic_promotion.py /opt/bicino-promotion/automatic_promotion.py
LABEL org.bicino.release-profile="production-map-promotion" \
      org.bicino.base-source="e739dfe6c0612e95db8241249dcc2edfe52d8372"
ENTRYPOINT ["python", "/opt/bicino-promotion/automatic_promotion.py"]
CMD []

FROM runtime AS validation
COPY --from=production-base /app /opt/promotion-base-app
COPY map-platform/backend/tests/test_automatic_promotion.py /opt/promotion-tests/test_automatic_promotion.py
COPY map-platform/backend/tests/test_catalog_promotion.py /opt/promotion-tests/test_catalog_promotion.py
COPY map-platform/deploy/promotion/test_runtime.py /opt/promotion-tests/test_runtime.py
RUN PROMOTION_SCHEDULER_SOURCE=/opt/bicino-promotion/automatic_promotion.py python -m unittest discover -s /opt/promotion-tests
