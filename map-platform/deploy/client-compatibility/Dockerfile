# Registry-only controller on the attested live production API runtime.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:e16f7fb10f480ef9605994191ee874cb16f3ed4a2c93a2412a2aef76cfbb5a35 AS production-base
FROM production-base AS runtime
COPY map-platform/config/map-stream-rollout-approvals.json /app/map-platform/config/map-stream-rollout-approvals.json
COPY map-platform/deploy/client-compatibility/role_guard.py /opt/bicino-client-compatibility/role_guard.py
LABEL org.bicino.release-profile="production-map-client-compatibility" \
      org.bicino.base-source="29aa415e21eacaae83e8d801815b409a0a5178e9"
ENTRYPOINT ["python", "/opt/bicino-client-compatibility/role_guard.py"]
CMD ["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"]

FROM runtime AS validation
COPY --from=production-base /app /opt/client-compatibility-base-app
COPY --from=production-base /app/map-platform/backend/tests/test_map_stream_rollout.py /opt/client-tests/map-platform/backend/tests/test_map_stream_rollout.py
COPY map-platform/config/map-stream-rollout-approvals.json /opt/client-tests/map-platform/config/map-stream-rollout-approvals.json
COPY map-platform/deploy/client-compatibility/test_runtime.py /opt/client-tests/map-platform/backend/tests/test_runtime.py
RUN PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s /opt/client-tests/map-platform/backend/tests
