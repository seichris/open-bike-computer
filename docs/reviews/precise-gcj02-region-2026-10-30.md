# Precise GCJ-02 region: review record

Local branch `fix/precise-gcj02-region`, not pushed. Recorded under
REVIEW.md before a pull request exists.

- Base: `54657fd0590abc497e4d62756916a4d7843f0beb` (GitHub `main`).
- Reviewed head: `6ee047893ad1854c72fd1ab07a48e5c4736aa402`. Commits:
  - `9e4502cf`: the change;
  - `3e8a8f28`: pass-1 fixes;
  - `6ee04789`: pass-2 fix.

  This record is a later documentation-only commit.
- Passes: 3 of 3.
  - Pass 1 reviewed `54657fd0..9e4502cf` in full.
  - Pass 2 reviewed `9e4502cf..3e8a8f28`, plus GCJ-RT and TOPO-EXTENT.
  - Pass 3 reviewed `3e8a8f28..6ee04789`, plus REF-FAR and TEST-CHAIN. A
    session restart interrupted it once, and it was rerun in full.
- State: **clean**. 0 active P0–P2 findings.

## Change

Apple Maps uses GCJ-02 only in mainland China. The app treated a rectangle
from 0.8293 to 55.8271° N and 72.004 to 135.5° E as GCJ-02. Apple Maps routes,
GPS fixes and drawings were therefore shifted by up to about 730 m in:
- Hong Kong, Macau and Taiwan;
- the Koreas and western Japan;
- Southeast Asia and most of India.

Live navigation there measured the rider against a shifted route.

The change makes these updates:
- **Region.** `MainlandChinaRegion` is generated from Natural Earth's
  public-domain 1:10m mainland China, plus the sea nearest its coast. Matsu,
  Lieyu, Tung Ping Chau and Neilingding are corrected by hand.
- **One conversion.** Every conversion goes through `GCJ02`, which
  `RouteCoordinateNormalizationV1` and `CoordinateConverter` delegate to on
  the iPhone and the Watch.
- **Two readings near a border.** Near a border, an Apple Maps coordinate can
  be read as a position on either side. The mainland reading wins unless:
  - a reference lies at the other reading, such as the rider's fix for a
    location derived from GPS;
  - the coordinate is route geometry, which keeps the side of the point
    before it.
- **Topography.** Whole topography selections are classified, and Saved Maps
  explains why a selection across the border shows no contours.
- **Archives.** Routes normalized from Apple Maps are marked normalization
  version 2. Saved version-1 archives are left unchanged.

Design notes: `docs/mapkit-china-coordinates.md`.

## Risk: medium

Conversion changes on every Apple Maps path on the iPhone and the Watch,
including navigation start, rerouting and deviation. No stored data is
rewritten and no server or firmware changes. Recovery needs an app update.

## Findings

| ID | Severity | Status | Summary |
| --- | --- | --- | --- |
| GCJ-RT | P2 | fixed in `3e8a8f28`, verified | A GPS fix within about 1 km of the Hong Kong or Macau border came back from Apple Maps space as the mainland position sharing its coordinate, about 600 m away. Navigation from Lok Ma Chau then rejected every live fix at the 150 m start gate. GPS-derived locations now use the rider's fix as a reference. |
| TOPO-EXTENT | P2 | fixed in `3e8a8f28`, verified | A saved contour selection crossing the region's edge asked for a download that cannot help. With the precise region, that covers most selections of Shenzhen, Zhuhai, Xiamen, Fuzhou, Dandong and Ruili. It now says contours aren't shown across the border. |
| REF-FAR | P2 | fixed in `6ee04789`, verified | The `3e8a8f28` reference trusted any position. A rider 5 km from a searched Shenzhen start, or route vertices 400 m or more apart, could move mainland positions into Hong Kong. A reference now counts only within 40% of the gap between the readings, and route geometry keeps the previous point's side. |
| TEST-CHAIN | P3 | fixed in `6ee04789` | The in-order tests passed even when every point was read against the start. A Hong Kong route along the border inside the strip now fails that mutation. |
| PRE-2 | — | pre-existing, out of scope | Without a GPS fix in the coordinator, `handleDestinationSelection` falls back to `MKMapView.userLocation` and converts it as GPS. In mainland China that location is likely already GCJ-02, so it would be shifted twice. |

P3 notes, accepted:
- **RES-1.** A searched start is misread when the rider stands within about
  240 m of its other reading. The same happens when the rider moved 360 to
  850 m during the route preview. The route's section in the strip follows the
  misread start. If this is revisited: keep the WGS-84 fix behind
  `PendingRoutePlan.initialLocation`, and pass no reference for searched
  starts.
- **TEST-THRESHOLD.** No test pins the 40% bound.
- **Crossings.** A route crossing the border is misread in the strip after the
  crossing: a median of 360 to 420 m, and at most about 2 km. Hong Kong to
  mainland crossings now misread the mainland strip, which `9e4502cf` read
  correctly. Crossings are rare for cycling.
- **Step vertices.** Step polylines that do not share their boundary vertex
  with the route could disagree with it. That happened in about 6% of
  simulated sparse Hong Kong steps. Whether real `MKRoute` steps share
  vertices can't be checked without a fixture.
- **Generator.** Its dependencies are recorded in the generated file but not
  pinned, and no check regenerates the data.

Fixed pass-1 P3 notes: the offset ranges and simulated-position notes in the
docs, and a trap on huge finite boxes.

## Checks

The receipt-signing key was blanked for every run, so no local result was
published.

- `tools/dev-check --level full` on clean `6ee04789`: 19 passed, including
  the iOS and Watch simulator contracts and the Debug and Release container
  builds.
- `tools/dev-check --level full` on clean `3e8a8f28`: 19 passed.
- `tools/dev-check` on clean `9e4502cf`: 17 passed.
- Discriminating tests:
  - `testHongKongBorderStartKeepsGPSFix` fails on `9e4502cf`.
  - The far-reference and 400 m checks fail on `3e8a8f28`.
  - The reviewer found that both chaining mutations fail the
    along-the-border route.
- Reviewer measurements on `6ee04789`:
  - **Round trips:** the Hong Kong and Macau window has 115 km² of ambiguous
    GPS positions, and their round-trip errors fell from 57.5 km² to 0.
  - **Shenzhen stations:** the three ambiguous ones were misread in 0 of 8
    rider directions at 5 km.
  - **One-side routes:** of 6,000 random routes with 30 to 1,200 m spacing, 0
    vertices were wrong.
- Region data: 1,192 generator probes agree with the Swift lookup.
  Regenerating twice produced identical data.
- Unsigned iPhone app build with the embedded Watch app: succeeded on each
  commit. Warnings in touched files only appear on lines that were already
  there.

## Not verified

- No check on a device in mainland China, Hong Kong or Macau, or with a
  paired Watch.
- Apple's own GCJ-02 boundary is unpublished, so agreement with it near
  borders is not measured.
- Whether real `MKRoute` step polylines share vertices with the route
  polyline.

## Recovery

Revert the commits and ship an app update. Version-2 archives stay valid,
because validation accepts any positive normalization version. There is no
server state or firmware to roll back.
