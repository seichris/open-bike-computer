# Bicycle detour service fixtures

`dubai-ready-response.json` is the `POST /v1/bicycle-detours` answer the
backend builds (`map_platform.bicycle_detour_service`) from the recorded
Valhalla 3.9.2 Dubai bicycle route in
`map-platform/backend/tests/fixtures/bicycle_detour/valhalla-dubai-bicycle-route.json`
(verified GCC States graph, archive SHA-256
`a1911ad2d013f43bc1595a9fdd40e7caa4b88075db4b86f4ddfc8f0b3150bfff`).
The Swift detour tests decode it, so the backend and app contracts stay in step.
