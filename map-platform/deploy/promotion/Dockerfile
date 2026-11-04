# Dedicated promotion scheduler. Preserve the approved immutable converter,
# signer, validation rules and producer identity byte-for-byte.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:6f1bbf736b6cc77159ffbee8c880d75bdbc307ccd5139b8beb3f92128e1cfd14 AS production-base
FROM production-base AS runtime
COPY map-platform/backend/map_platform/automatic_promotion.py /opt/bicino-promotion/automatic_promotion.py
LABEL org.bicino.release-profile="production-map-promotion" \
      org.bicino.converter-image="ghcr.io/seichris/open-bike-computer-map-platform@sha256:6f1bbf736b6cc77159ffbee8c880d75bdbc307ccd5139b8beb3f92128e1cfd14" \
      org.bicino.base-source="ef49abbb47b527a16b440eeb7238b2ce5a184f93"
ENTRYPOINT ["python", "/opt/bicino-promotion/automatic_promotion.py"]
CMD []

FROM runtime AS validation
COPY --from=production-base /app /opt/promotion-base-app
COPY map-platform/backend/tests/test_automatic_promotion.py /opt/promotion-tests/test_automatic_promotion.py
COPY map-platform/backend/tests/test_catalog_promotion.py /opt/promotion-tests/test_catalog_promotion.py
COPY map-platform/deploy/promotion/test_runtime.py /opt/promotion-tests/test_runtime.py
RUN PROMOTION_SCHEDULER_SOURCE=/opt/bicino-promotion/automatic_promotion.py python -m unittest discover -s /opt/promotion-tests
