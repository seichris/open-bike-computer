# The live production API and maintenance base, with no generation changes.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:a0e04381c08aa8798320beef4d412e42b8fc1f982a574dcc9e464f4142f701ca AS production-base
FROM production-base AS runtime

COPY map-platform/backend/map_platform/api.py \
     map-platform/backend/map_platform/strava_development.py \
     map-platform/backend/map_platform/strava_integrations.py \
     /app/map-platform/backend/map_platform/
COPY map-platform/deploy/client-compatibility/role_guard.py /opt/bicino-strava/role_guard.py
COPY map-platform/deploy/strava-compatibility/overlay.sha256 /opt/bicino-strava/overlay.sha256
RUN cd / && sha256sum --check --strict /opt/bicino-strava/overlay.sha256
LABEL org.bicino.release-profile="production-strava-compatibility" \
      org.bicino.base-source="08c8b4cce7425466cf9041fd9e995d5450514abf"
ENTRYPOINT ["python", "/opt/bicino-strava/role_guard.py"]
CMD ["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"]

FROM runtime AS validation
COPY --from=production-base /app /opt/strava-base-app
COPY map-platform/backend/tests/test_strava_api.py \
     map-platform/backend/tests/test_strava_integrations.py \
     map-platform/backend/tests/test_strava_client.py \
     map-platform/backend/tests/app_attest_support.py \
     map-platform/deploy/strava-compatibility/test_runtime.py \
     /opt/strava-tests/map-platform/backend/tests/
RUN ln -s /app/map-platform/backend/config /opt/strava-tests/map-platform/backend/config \
    && ln -s /app/map-platform/config /opt/strava-tests/map-platform/config \
    && PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s /opt/strava-tests/map-platform/backend/tests
