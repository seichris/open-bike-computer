# Saved-route detour acceptance (live, development only)

`run.sh` rides `dubai-detour-acceptance.gpx` (a Dubai cycling route built from
the verified GCC States Valhalla graph; OSM data © OpenStreetMap contributors),
leaves it at a right angle after `LEAVE_AFTER_METERS` (600), and checks the
whole chain with the app's shared code: live Apple MapKit cycling (expected:
`MKDirectionsErrorCode` 8 in the UAE) → authenticated `POST /v1/bicycle-detours`
on `BICINO_SERVICE_URL` → Valhalla bicycle detour → confirmed rejoin → saved
route guidance resumed with its generation and content hash. Set `EVIDENCE` to
keep the JSON evidence. It is not part of the automated checks because it uses
live services and an installation credential.
