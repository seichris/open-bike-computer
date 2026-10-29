# Registry-only controller on the attested contract-1 producer runtime.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:d8b9d172d657cbfa7298e970968b64520c6b3d00f8dcb28758bab8f8cef3a9b9 AS production-base
FROM production-base AS runtime
COPY map-platform/config/map-stream-rollout-approvals.json /app/map-platform/config/map-stream-rollout-approvals.json
COPY map-platform/deploy/client-compatibility/role_guard.py /opt/bicino-client-compatibility/role_guard.py
LABEL org.bicino.release-profile="production-map-client-compatibility" \
      org.bicino.base-source="8104250ca68499a50c9ec68b9102f13fe1ab5965"
ENTRYPOINT ["python", "/opt/bicino-client-compatibility/role_guard.py"]
CMD ["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"]

FROM runtime AS validation
COPY --from=production-base /app /opt/client-compatibility-base-app
COPY --from=production-base /app/map-platform/backend/tests/test_map_stream_rollout.py /opt/client-tests/map-platform/backend/tests/test_map_stream_rollout.py
COPY map-platform/config/map-stream-rollout-approvals.json /opt/client-tests/map-platform/config/map-stream-rollout-approvals.json
COPY map-platform/deploy/client-compatibility/test_runtime.py /opt/client-tests/map-platform/backend/tests/test_runtime.py
RUN PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s /opt/client-tests/map-platform/backend/tests
