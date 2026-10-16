# API-only client upgrade on the exact healthy production controller.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:1bd81869764ab37d8a8337f4814a540aab3e1deaf62504ef922740c0388e48cc AS production-base
FROM production-base AS runtime
COPY map-platform/backend/map_platform/map_stream_rollout.py /app/map-platform/backend/map_platform/map_stream_rollout.py
COPY map-platform/config/map-stream-rollout-approvals.json /app/map-platform/config/map-stream-rollout-approvals.json
COPY map-platform/deploy/client-compatibility/role_guard.py /opt/bicino-client-compatibility/role_guard.py
LABEL org.bicino.release-profile="production-map-client-compatibility" \
      org.bicino.base-source="503ab8945d14857452b77e3ef7d06dd7510e94c8"
ENTRYPOINT ["python", "/opt/bicino-client-compatibility/role_guard.py"]
CMD ["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"]

FROM runtime AS validation
COPY --from=production-base /app /opt/client-compatibility-base-app
COPY map-platform/backend/tests/test_map_stream_rollout.py /opt/client-tests/map-platform/backend/tests/test_map_stream_rollout.py
COPY map-platform/config/map-stream-rollout-approvals.json /opt/client-tests/map-platform/config/map-stream-rollout-approvals.json
COPY map-platform/deploy/client-compatibility/test_runtime.py /opt/client-tests/map-platform/backend/tests/test_runtime.py
RUN PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s /opt/client-tests/map-platform/backend/tests
