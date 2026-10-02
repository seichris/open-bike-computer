## Maintainer acceptance for release.8 and worldwide signed-map rollout

On 2026-10-01 (Asia/Singapore), the maintainer explicitly answered **“yes both”** to releasing both board targets with the listed risks recorded, following the request to publish firmware to GitHub/backends and enable worldwide delivery.

Release candidate: version 0.3.4, build 101, proposed tag `v0.3.4-release.8`; prepared source `7747ca900820f95a6fe0f58659a0139d11ffe982`. Full CI https://github.com/seichris/open-bike-computer/actions/runs/36733060140 and all ten diagnostics https://github.com/seichris/open-bike-computer/actions/runs/36733630891 passed. Tagged artifacts undergo the release workflow again.

### Target-specific evidence and accepted remaining risk

- **WAVESHARE_AMOLED_175:** an earlier production-profile recovery image at source `6c4120afa84047c36c36db34195e47651ce5a9b7` (binary SHA-256 `5f36449618617c5436d8128863ac21caaf01bae68bf7e95983f378bc1d30fc86`) was flashed. The user reported successful regular Bicino map download, transfer, rendering, and persistence after full power off/on. This does not qualify the final tagged build 101 bytes. Its authenticated production boot acceptance and instrumented interruption/resume/thermal matrix remain open.
- **WAVESHARE_AMOLED_206:** software builds passed; final production image and signed-map transfer have no physical qualification in this chat. These physical gates remain open and are accepted for publication.
- **Shared Wi-Fi:** the broader review's activation acknowledgement, auth revocation during stream completion, lease/cleanup asymmetry, background SSID cleanup, and shutdown quiescence findings remain unimplemented/unqualified. Pointer recovery was fixed in #540. Publication does not mark those remaining findings resolved.
- **Worldwide rollout:** the hardware report intentionally records no measured matrix runs and relies on explicit operator risk acceptance under the current optional matrix policy. Approval must bind the released firmware identity, exact tested worker/producer, regular Bicino build 24 identity, and unchanged signing trust. Worldwide delivery remains constrained by the server's exact supported client/firmware checks and App Attest authorization.

This is explicit residual-risk acceptance, not a claim of physical factory/golden qualification. No release keys, trust anchors, App Attest requirements, or physical-device writes are changed by this approval.

## Approved rollout identity

- Released firmware source: `309791611ad7125dcea9ea69abedbc66342434e2`, both targets, 0.3.4 build 101.
- Promotion: `msr-20261001-worldwide-build101`.
- Raw report SHA-256: `d12c185c583ef1ce6fe9643fd6fe9da7796be0374d8d3b3aa09abe0ba0915acc`; report retained outside Git. The optional hardware matrix has zero recorded measured runs.
- Tested worker: `sha256:1030d2c361cfdbc5ef506938c80938086053df9321895576ee1a3923082afafd`; producer component `83e0dac465b76fbbf06d3eb1c465224d708885a4cc8d19a25460f47ffb199046`. Deploy the approval through a new control-plane image while preserving this worker.
- Regular Bicino: build `24`, source `1d54b2a8cf0b16dc1e1b7aadcaee1256761380e1`, component `e3d60f19bbb2866159a81eb0205146dfccd886f7d73ad46679360c4c42a49810`.
- Trusted map signing key: `map-prod-2026-08`, public fingerprint `8042e4bbac215fcebb44a157849b252a844f195e634f89a9b8fdd989cf681c12`.

Global admission must wait for GitHub publication, signed OTA channel verification for both targets, and deployment of the approval registry. Health checks establish configuration readiness; they do not establish traffic, thermal, physical or long-duration performance acceptance. Roll back delivery using the documented cohort controls if regressions arise.

The repository runbook recommends staged percentage observations. This maintainer authorization explicitly accepts the incomplete physical and measured matrix for global deployment. Any shortened observation provides only operational configuration evidence and must not be reported as measured field qualification. Topography generation has a separate gate and is outside this signed-map cohort promotion.
