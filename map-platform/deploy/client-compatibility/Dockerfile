# API-only client upgrade on the exact healthy production controller.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:a007eb1beeeba69e51a287394aa2741879598d55a7586fff1d13f3e0004e29f0 AS production-base
FROM production-base AS runtime
COPY map-platform/config/map-stream-rollout-approvals.json /app/map-platform/config/map-stream-rollout-approvals.json
COPY map-platform/deploy/client-compatibility/role_guard.py /opt/bicino-client-compatibility/role_guard.py
LABEL org.bicino.release-profile="production-map-client-compatibility" \
      org.bicino.base-source="2e4d28554061f3b7243fd7f8d21fe628a407f67b"
ENTRYPOINT ["python", "/opt/bicino-client-compatibility/role_guard.py"]
CMD ["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"]

FROM runtime AS validation
COPY --from=production-base /app /opt/client-compatibility-base-app
COPY --from=production-base /app/map-platform/backend/tests/test_map_stream_rollout.py /opt/client-tests/map-platform/backend/tests/test_map_stream_rollout.py
COPY map-platform/config/map-stream-rollout-approvals.json /opt/client-tests/map-platform/config/map-stream-rollout-approvals.json
COPY map-platform/deploy/client-compatibility/test_runtime.py /opt/client-tests/map-platform/backend/tests/test_runtime.py
RUN PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s /opt/client-tests/map-platform/backend/tests
