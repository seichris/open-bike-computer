# Bicycle routes with road, gravel and everyday profiles

Create a Route builds a multi-stop route one leg at a time. Drive and Walk legs
stay on Apple Maps. For bicycle legs the rider picks one of three Valhalla
bicycle profiles (**Road**, **Gravel**, **Everyday**), and each leg is one
request to `POST /v1/bicycle-routes` carrying exactly two coordinates: the
leg's origin and destination. The backend forwards them to Bicino's own
internal Valhalla 3.9.2 service, the one that serves
[saved-route detours](saved-route-detours.md), with the `bicycle` costing and
the profile's options.

The production graph covers only the places where Apple Maps has no cycling
directions, plus a border band (see the
[routing README](../map-platform/routing/README.md)). Elsewhere an
`unavailable` / `no_bicycle_route` answer is normal, and the app decides what
to fall back to.

## Endpoint

`POST /v1/bicycle-routes?clientInstallationId=…` with `X-Installation-Token`.
The request needs an App Attest–enrolled installation
(`installation_attestation_required` otherwise). The body is limited to
16 KiB, and every response carries `Cache-Control: private, no-store`.

```json
{
  "schema": "bicino-bicycle-route-request-v1",
  "requestId": "<lowercase uuid>",
  "origin": {"latitudeE6": 25206600, "longitudeE6": 55269200},
  "destination": {"latitudeE6": 25225800, "longitudeE6": 55263100},
  "profile": "road",
  "locale": "en-AE"
}
```

- `profile` is `road`, `gravel` or `everyday`, matched exactly.
- `locale` is a BCP 47 tag; `en_AE` is normalised to `en-AE`. It is optional
  and defaults to `en-US`.
- Unknown fields are rejected.
- The straight-line separation must be at least 10 m and at most
  `MAP_PLATFORM_BICYCLE_ROUTE_MAX_SEPARATION_METERS` (default 150,000 m).

```json
{
  "schema": "bicino-bicycle-route-response-v1",
  "status": "ready",
  "route": {
    "provider": {"id": "bicino.valhalla", "attribution": "© OpenStreetMap contributors"},
    "travelMode": "bicycle",
    "distanceMeters": 3198.0,
    "durationSeconds": 499.0,
    "pointsE6": [[25206617, 55269262], "…"],
    "maneuvers": [{"type": 2, "instruction": "Bike south on 91b شارع.", "beginShapeIndex": 0,
                   "endShapeIndex": 3, "lengthMeters": 13.0, "timeSeconds": 2.0, "bearingAfter": 180}, "…"],
    "profile": "road"
  },
  "reason": null
}
```

The route has the detour route's shape: `pointsE6` (`[latitudeE6,
longitudeE6]` in travel order) and `maneuvers` (Valhalla `type`,
`instruction`, contiguous `beginShapeIndex`/`endShapeIndex` that cover the
whole shape, length, time and optional bearings). It also carries `profile`,
which echoes the request.

| Outcome | Meaning |
| --- | --- |
| `200` `ready` | `route` as above, `reason: null`. |
| `200` `unavailable`, `no_bicycle_route` | Valhalla 170/171/442/443 (no path, or a point outside the loaded graph), or Valhalla answered with a maneuver that is neither `bicycle` nor a short pedestrian push stretch (see below). |
| `200` `unavailable`, `request_too_long` | Valhalla 154 (beyond its bicycle distance limit), or the answer exceeds the size caps below. Asking again cannot help. |
| `200` `unavailable`, `service_disabled` | No upstream configured, or `MAP_PLATFORM_BICYCLE_ROUTE_ENABLED=0`. |
| `400` `bicycle_route_invalid_request` | Schema, field, profile, locale or separation error. |
| `401` | Missing or wrong credential, or `installation_attestation_required`. |
| `413` | Body over 16 KiB. |
| `429` | Per-IP or per-installation hourly/daily limit, with `Retry-After`. |
| `503` `bicycle_route_busy` | All route slots in use; `Retry-After: 5`. |
| `503` `bicycle_route_unavailable` | Valhalla unreachable, timed out or answered unexpectedly; `Retry-After: 30`. |

`GET /v1/capabilities` advertises the endpoint next to `bicycleDetour`:

```json
"bicycleRoute": {
  "available": true,
  "schema": "bicino-bicycle-route-request-v1",
  "provider": "bicino.valhalla",
  "attribution": "© OpenStreetMap contributors",
  "profiles": ["road", "gravel", "everyday"],
  "maximumSeparationMeters": 150000
}
```

When the service is disabled, `available` is `false` and `provider` and
`attribution` are `null`. `/healthz` reports
`bicycleRoute: {"enabled", "provider"}`.

## Profiles

| Profile | `bicycle_type` | `use_roads` | `use_hills` | `avoid_bad_surfaces` | `use_ferry` |
| --- | --- | ---: | ---: | ---: | ---: |
| `road` | `road` | 0.5 | 0.5 | 0.9 | 0 |
| `gravel` | `cross` | 0.2 | 0.5 | 0.0 | 0 |
| `everyday` | `hybrid` | 0.25 | 0.25 | 0.5 | 0 |

- **Road** favours smooth surfaces. `avoid_bad_surfaces` 0.9 weighs unpaved
  surfaces heavily without making them impassable; 1.0 would, and a leg that
  starts on a short unpaved stretch would then fail.
- **Gravel** uses Valhalla's cyclocross type. It tolerates unpaved surfaces
  and prefers quieter ways to roads.
- **Everyday** is a city or hybrid bike: low-stress streets, a mild dislike of
  hills, and moderate avoidance of rough surfaces.
- Ferries are never used. `use_hills` has no effect on the current graphs,
  which are built without elevation.

The type also sets Valhalla's default speed on smooth flat roads (road
25 km/h, cross 20, hybrid 18), its per-surface speed factors, and the worst
surface each bike tolerates before `avoid_bad_surfaces` applies.

**How Valhalla parses the type.** Valhalla 3.9.2 lowercases `bicycle_type`
before comparing it with `road`, `cross` and `mountain`, and silently treats
any other value as `hybrid` (`ParseBicycleCostOptions` and the `BicycleCost`
constructor in `src/sif/bicyclecost.cc`; its default is `"hybrid"`). `Road` and
`road` are therefore the same, and the detour endpoint's `"hybrid"` was
already correct. A misspelling is never rejected, so the probe below checks
that each maneuver's `travel_type` matches the requested type.

### Evidence that the profiles differ

[`probe_profiles.py`](../map-platform/routing/probe_profiles.py) sends every
pair in [`profile-probes.json`](../map-platform/routing/profile-probes.json)
through the backend's own `BicycleRouteService` once per profile. It records
the app-facing result together with the raw `travel_type`, and fails in three
cases:
- a type was not applied;
- a pair marked ready is not ready for every profile;
- no pair gives different road and gravel geometry.

The run on 2026-11-24 used the following setup:
- the pinned image `ghcr.io/valhalla/valhalla-scripted@sha256:b523b803…`
  (`linux/arm64` from the same index), archive-only;
- the retained regional qualification archive
  (`db1433b4f93365b64413e8200efa3305716e0e232a88e1d5549294f8a5ed2615`,
  1,013,391,360 bytes, 3,675 tiles), which covers GCC States and
  Argentina/Uruguay.

| Pair | Road | Gravel | Everyday |
| --- | --- | --- | --- |
| Dubai (detour fixture pair) | 3.198 km, 8.3 min | 3.194 km, 10.3 min | 3.194 km, 11.3 min |
| Hatta | 9.364 km, 25.7 min | 8.333 km, 30.6 min | 9.075 km, 34.5 min |
| Al Awir, Dubai | 17.997 km, 45.1 min | 21.629 km, 81.1 min | 17.997 km, 62.0 min |
| Dubai → Ras Al Khaimah | 124.6 km, 5.15 h | 139.5 km, 7.54 h | 139.6 km, 8.21 h |
| Buenos Aires | 7.144 km, 19.2 min | 7.404 km, 24.4 min | 7.404 km, 26.9 min |

- Road and gravel geometry differ on every pair.
- Every maneuver reported `travel_type` `road`, `cross` or `hybrid` as
  requested.
- Each upstream answer took at most 0.2 s.

In a wider sweep of 73 routable random UAE pairs, road and gravel geometry
differed on 60, and durations differed on all.

Re-run it against any private Valhalla origin:

```sh
tools/dev-env --map-backend python map-platform/routing/probe_profiles.py \
  --origin http://127.0.0.1:8002
```

### Push-the-bike stretches

Valhalla's bicycle routes can include short stretches where the rider walks
the bike. These come back as `travel_mode: "pedestrian"` /
`travel_type: "foot"` maneuvers, typically 12–60 m on a footway or a cycle-path
connector.

- **Bicycle routes:** a push stretch of at most
  `MAP_PLATFORM_BICYCLE_ROUTE_MAX_PUSH_METERS` (default 100 m, `0` turns it
  off) stays in the route with Valhalla's own instructions. Valhalla starts a
  new maneuver at each turn, so back-to-back pedestrian maneuvers are summed
  as one stretch. Chris approved this on 2026-11-24.
- **Refused:** a longer walk, any other mode, or a route with no bicycle
  maneuver at all is `no_bicycle_route`.
- **Detours:** saved-route detours never accept push stretches.

In the UAE sweep with the old all-strict rule, 11 of 73 routes failed this
way. Most were longer than 25 km (7 of the 18 routes over 100 km), each with
17–173 m of walking in total, spread over 12–60 m stretches.

## Limits and configuration

Bicycle routes share the Valhalla upstream with detours but never their
slots. Each service has its own concurrency cap, so leg planning cannot take
the slots a rider needs for a detour mid-ride. Valhalla itself runs two
worker threads (`valhalla_service … 2`). When both route slots are busy, a
detour can queue behind them inside Valhalla. Measured route times are well
under the detour timeout of 8 s.

| `MAP_PLATFORM_…` | Default | Range |
| --- | --- | --- |
| `BICYCLE_ROUTING_UPSTREAM_URL` | unset (disabled) | internal http(s) origin, shared with detours |
| `BICYCLE_ROUTE_ENABLED` | `1` | `0`/`1` (detours keep `BICYCLE_DETOUR_ENABLED`) |
| `BICYCLE_ROUTE_TIMEOUT_SECONDS` | 15 | 2–60 |
| `BICYCLE_ROUTE_MAX_CONCURRENT` | 2 | 1–32 (detours: separate, 4) |
| `BICYCLE_ROUTE_MAX_SEPARATION_METERS` | 150,000 | 1,000–500,000 (Valhalla's bicycle `max_distance` is 500 km) |
| `BICYCLE_ROUTE_REQUIRE_APP_ATTEST` | true | `'1'` in the production lock; defaults to 1 in development |
| `BICYCLE_ROUTE_IP_LIMIT_PER_HOUR` | 480 | per client IP |
| `BICYCLE_ROUTE_LIMIT_PER_HOUR` | 240 | per installation |
| `BICYCLE_ROUTE_LIMIT_PER_DAY` | 1,200 | per installation |

Both `compose.yaml` and `compose.development.yaml` pass these settings to the
API, and only to the API. The public per-IP request limit applies as well.

**Answer-size caps.** These scale with `BICYCLE_ROUTE_MAX_SEPARATION_METERS`
and never drop below the detour caps (2 MiB, 20,000 points, 1,000 maneuvers).
Each straight-line kilometre allows 10 KiB of Valhalla JSON, 300 shape points
and 20 maneuvers, so 150 km gives 2 MiB, 45,000 points and 3,000 maneuvers.

Measured on 2026-11-24 on legs of 60–218 km in the UAE, Oman, Saudi Arabia
and Argentina:
- at most 30 shape points, 1.8 maneuvers and 1 KiB of Valhalla JSON per
  route kilometre;
- at most about 5,200 points per route;
- about 100 KiB of `pointsE6` per route.

An answer over a cap is `request_too_long`, not a retryable `503`.

## In the app

`MultiStopRoutePlanner` asks this endpoint for every leg of a Road, Gravel or
Everyday plan (`BicinoBicycleRouteService`, `BicycleRouteClient`), using the
stops' WGS-84 coordinates. Legs are cached per profile and locale, so editing
one stop re-asks only the legs that changed.

- **Apple Maps fallback for the whole plan:** `no_bicycle_route` /
  `request_too_long` ("isn't available here"), and a missing or disabled
  service, a refused installation or an unusable answer ("isn't available
  right now"). A leg longer than 150 km goes to Apple Maps without a request.
  A plan never mixes providers, and the panel names the fallback. A fallback
  for an unavailable service lasts only for that plan, so the next plan asks
  again. A route without a Bicino route stays on Apple Maps until the
  session ends.
- **Try Again:** offline, `429` and `503`.
- **Saving:** a Bicino plan saves as `bicino.valhalla` with phone-only scope
  (`RouteProviderPolicyV1.valhallaSavedOnPhone`). It is never sent to the Watch
  or shared. It gets route elevation with the `saved` source and detours with
  the `valhalla` source.

## Privacy

For a bicycle leg, the app sends the leg's start and end coordinates, the
chosen profile and the display language to the Bicino service with the
installation credential. The service computes the route on Bicino's own
Valhalla server and returns it. Neither the coordinates nor the route are
stored or logged. Log lines carry only the outcome, Valhalla's error code,
and the profile name. The upstream address never appears in a response.
Requests count against per-IP and per-installation rate limits, which keep
pseudonymous counters only.
