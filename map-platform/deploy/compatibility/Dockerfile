# Authentication compatibility is built on the exact deployed production image.
# No package installation or generation-source replacement is permitted here.
FROM ghcr.io/seichris/open-bike-computer-map-platform@sha256:142957ae0d5f08d366b657f9bacb0ce17d85bfac9c5d98c644bc1b02188a59c8 AS production-base
FROM production-base AS runtime

COPY map-platform/backend/map_platform/api.py /opt/bicino-auth-source/api.py
COPY map-platform/backend/map_platform/app_attest.py /opt/bicino-auth-source/app_attest.py
COPY map-platform/backend/map_platform/data/Apple_App_Attestation_Root_CA.pem /opt/bicino-auth-source/data/Apple_App_Attestation_Root_CA.pem
COPY map-platform/deploy/compatibility/prepare_auth_backport.py /opt/bicino-auth-source/prepare_auth_backport.py
COPY map-platform/deploy/compatibility/role_guard.py /opt/bicino-auth-source/role_guard.py
RUN python /opt/bicino-auth-source/prepare_auth_backport.py \
      --package /app/map-platform/backend/map_platform --current /opt/bicino-auth-source \
    && python -c "from map_platform.app_attest import production_app_attest_verifier; production_app_attest_verifier('production')"

LABEL org.bicino.release-profile="production-auth-compatibility" \
      org.bicino.base-source="e739dfe6c0612e95db8241249dcc2edfe52d8372"
ENTRYPOINT ["python", "/opt/bicino-auth-source/role_guard.py"]
CMD ["uvicorn", "--factory", "map_platform.api:create_app", "--host", "0.0.0.0", "--port", "8080"]

# Test-only dependencies never enter the published runtime target.
FROM runtime AS validation
COPY --from=production-base /app /opt/compatibility-base-app
RUN python -m pip install 'httpx==0.28.1'
COPY map-platform/backend/tests/app_attest_support.py /opt/compatibility-tests/app_attest_support.py
COPY map-platform/backend/tests/test_app_attest.py /opt/compatibility-tests/test_app_attest.py
COPY map-platform/backend/tests/fixtures/app_attest_map_create_v1.json /opt/compatibility-tests/fixtures/app_attest_map_create_v1.json
COPY map-platform/deploy/compatibility/test_runtime.py /opt/compatibility-tests/test_runtime.py
RUN python -m unittest discover -s /opt/compatibility-tests
