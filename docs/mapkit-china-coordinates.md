# Apple Maps coordinates in mainland China

Apple Maps uses GCJ-02 in mainland China and WGS-84 everywhere else,
including Hong Kong, Macau and Taiwan with Kinmen and Matsu. GPS, route
archives, the Bicino's maps and every protocol stay WGS-84. The iPhone and
the Watch convert only where they meet Apple Maps.

## The region

`MainlandChinaRegion` (`ios-app/BikeComputer/RideShared/MainlandChinaRegion.swift`)
answers whether a WGS-84 position is in mainland China. `GCJ02` in the same
file holds the conversion. `RouteCoordinateNormalizationV1` and the iPhone's
`CoordinateConverter` both delegate to it, so the iPhone and the Watch share
one region and one formula.

The region is:

- Natural Earth's mainland China: the 1:10m Admin 0 "China" feature, version
  5.1.2, which excludes Hong Kong, Macau and Taiwan;
- the sea whose nearest coastline is mainland China's, within 15 to 56° N and
  70 to 140° E, so coastal roads, reclaimed land and ferries stay with the
  mainland, and Deep Bay, the Macau channels and the Kinmen strait are split
  along their midlines;
- corrections for islands Natural Earth omits: Matsu, Lieyu (Little Kinmen)
  and Tung Ping Chau are added outside the region, and Neilingding inside it,
  as approximate discs.

`ios-app/scripts/generate_mainland_china_region.py` builds the region from the
SHA-256-pinned source and writes `MainlandChinaRegion.generated.swift`: 2
rings and 6,263 vertices at 0.00001° resolution, about 25 KB. It also writes
1,192 probe points with their expected answers to
`ios-app/BikeComputerTests/Fixtures/mainland-china-region-probes.json`. The
RideShared tests check every probe and the named border pairs. The generator
needs shapely 2.1 or later, which the development environment does not
install; its docstring gives the regeneration command, and the generated file
records the shapely, GEOS and numpy versions used. No check regenerates it, so
review a regenerated file's diff. Natural Earth is in the public domain.

Lookups reject points outside the bounding box at once. Inside it, a lookup
casts a ray against the edges in one 0.1° latitude band.

### Precision

- **Land borders** are Natural Earth's generalized 1:10m lines, simplified by
  at most 30 m. They are typically within a few hundred metres of the true
  border, more in remote mountains. At some crossings Natural Earth is
  further off: in Mong Cai, Vietnam, about 1 km of the town falls inside its
  China polygon. Within that band, a position may be converted on the wrong
  side.
- **Cities** near borders are classified correctly with at least 1 km to
  spare. The generator refuses to write a region that misplaces Shenzhen,
  Sheung Shui, Zhuhai, Macau, Xiamen, Kinmen, Lieyu, Matsu, Tung Ping Chau,
  Dandong, Sinuiju, Taipei, Singapore, Seoul or Bangkok, among others.
- **Apple's own boundary** is not published. Where it differs from this one,
  the app and Apple Maps disagree by one GCJ-02 offset, about 140 to 700 m
  along this region's edge.

A more precise source, such as OpenStreetMap's boundaries, would bring
ODbL obligations into the app's source and needs a licensing decision first.

## Converting near a border

GCJ-02 moves a position by a few hundred metres. Near Shenzhen it moves
positions about 300 m south and 530 m east, so a strip of Shenzhen lands on
Apple Maps coordinates that also belong to Hong Kong. The two directions
behave as follows:

- **WGS-84 to Apple Maps** tests the WGS-84 position, which is exact.
- **Apple Maps to WGS-84** computes the GCJ-02 preimage. A coordinate outside
  the region whose preimage lies inside it has two readings, one on each side,
  in strips up to about 1.2 km deep beside the border. The mainland reading
  wins unless something better is known:
  - a location the phone derived from GPS, such as the start of navigation, a
    reroute or the deviation check, passes the rider's latest fix as a
    reference. The reference counts only when it lies within 40% of the gap
    between the two readings, as a fix does at the position it came from, so
    the fix comes back exactly while a rider far from a searched start changes
    nothing;
  - Apple route geometry is read in order and keeps the side of the point
    before it, so a route that stays on one side reads correctly however far
    apart its points are. The first point uses the position the route was
    requested from as its reference. The iPhone and the Watch both do this.

  Some cases stay wrong. A Hong Kong or Macau place in the strip with no
  usable reference, such as a searched start or a favorite synced to the
  Watch, takes the mainland reading. A searched mainland start takes the
  other reading if the rider happens to stand at that reading, within about
  240 m of it near Shenzhen, and the route's section in the strip follows the
  start. A route crossing the border is misread until it leaves the strip. The RideShared and navigation tests pin these cases near
  Luohu, Lok Ma Chau and Shenzhen Railway Station.

A topography overlay that reaches mainland China reads every pixel the same
way, with no reference:
- A pixel whose Apple Maps coordinate has a mainland reading samples its
  WGS-84 source pixel.
- A pixel inside the region with no mainland reading stays transparent. Where
  the offset points away from the border, as at Khorgos on the Kazakh border,
  GCJ-02 has moved the terrain just inside the border further in, and drawing
  it in place as well would show it twice. The empty band is at most one
  offset deep.
- Every other pixel keeps its position.
- Terrain lookups take the mainland reading where there is one.
- A contour label is drawn where its own contours are drawn, and is skipped
  where the tile at that point shows other terrain.
- Each 128 m cell of the Terrain Experiments relief moves whole with its
  centre, so a cell across the border keeps its shape. A cell is skipped
  where the tile at its centre shows other terrain.

A selection across the border, such as Shenzhen with Hong Kong, Zhuhai with
Macau or Xiamen with Kinmen, therefore lines up on both sides:
- **Border cells:** grid cells that straddle the border are mapped pixel by
  pixel rather than interpolated, so nothing smears across it.
- **Two source areas:** each side of the border has its own source area. A
  tile at high zoom can therefore use two sources thousands of pixels apart.
- **The strip near the border:** in the strip up to about 1.2 km deep beside
  the border, pixels take the mainland reading. There the overlay shows the
  shifted mainland terrain, and the other side's terrain begins where the
  shifted mainland ends. The other side's contour labels and relief cells in
  the strip are skipped.

## Where the app converts

| Path | Direction |
| --- | --- |
| Apple Maps routes into route archives and the Bicino (`MapKitRouteAdapter`, Watch `WatchOnlineRouteProvider`) | Apple Maps to WGS-84 |
| GPS into Apple Maps route space for routing, rerouting and deviation (`CoordinateConverter.mapKitRouteLocation`) | WGS-84 to Apple Maps |
| Saved, offline, social and live positions drawn on Apple Maps (`SavedRouteMapPreview`, `BikeComputerCoordinator`, `SocialMapLayer`, `SocialHubView`, `SocialInvitePreview`, `MapView`) | WGS-84 to Apple Maps |
| Favorites synced to the Watch (`BikeComputerApp`) | Apple Maps to WGS-84 |
| Watch online routing endpoints | WGS-84 to Apple Maps |
| Simulated positions shown on Apple Maps (`NavigationEngine`) | WGS-84 to Apple Maps |
| Topography overlay (`BicinoTopographyTileOverlay`, `TopographyMapKitTileWarp`) | per pixel, Apple Maps to WGS-84 |
| Version-1 Apple Maps routes when an archive is loaded (`NavigationRouteArchiveV1`, `RouteCoordinateNormalizationV1.rereadVersion1`) | WGS-84 as version 1 saved it, to Apple Maps and back with version 2 |

The firmware and the map backend never convert.

## Route archives

`NavigationRouteV1.normalizationVersion` records how a route's coordinates
reached WGS-84. Routes normalized from Apple Maps now carry version 2
(`RouteCoordinateNormalizationV1.mapKitVersion`). Version 1 treated a
rectangle from 0.8293 to 55.8271° N and 72.004 to 135.5° E as GCJ-02. That
rectangle also covers Hong Kong, Macau, Taiwan, the Koreas, western Japan,
most of Southeast Asia, most of India and southern Siberia. There, version 1
saved Apple Maps routes up to about 730 m off the road, typically 130 to
620 m in the cities affected.

### Version-1 Apple Maps archives

Saved archives keep their bytes. An archive's content hash identifies its
revision in the library, on the Watch, in elevation profiles and in social
shares, so the app reads version-1 routes again instead of rewriting them.
When an archive with the `apple.mapkit` provider and normalization version 1
is loaded, `RouteCoordinateNormalizationV1.rereadVersion1` reads its route
as follows:

1. Each point inside the old rectangle gets back the GCJ-02 shift that
   version 1 removed (`GCJ02.fromWGS84`). That is where the phone drew it
   before version 2, and it recovers the point's Apple Maps coordinate.
2. These coordinates are read with version 2, in order, like a newly planned
   route. A point read as mainland China keeps its stored value, which both
   versions compute the same way, so mainland routes are unchanged.
3. Version 2 settles a first point that has two readings with the position
   the route was requested from. An archive does not keep that position, so
   the side of the first point with a single reading is used instead.
4. The endpoints and bounds follow the new points, and the route is marked
   version 2. If the new points would make the route invalid, for example a
   segment beyond the Bicino's 16-bit delta range, the stored route is used.

`NavigationRouteArchiveV1` holds both routes:

- **`storedRoute`** is the route as saved. The content hash covers it,
  encoding and social sharing send it, and social geometry fingerprints use
  it, as the backend does. A social duplicate copies it, so the copy is read
  the same way and keeps the original's fingerprint.
- **`route`** is the route the app uses. The saved-route map, offline
  navigation and the route sent to the Bicino, elevation profiles, favorites
  starred from the route and social previews all follow it.

The library, Watch sync, elevation bindings and social provenance therefore
go on identifying the same revision. An elevation profile cached for the
stored line no longer matches the route's geometry. The next online lookup
measures the road and replaces it under the same binding.

Some cases stay wrong:

- **Within the border strip:** a route that stays in a strip beside a
  mainland border has no point with a single reading. It keeps the mainland
  reading, like a new route with no reference.
- **Across a border:** a route crossing a mainland border is misread after
  the crossing until it leaves the strip, as version 2 reads one.
- **At the rectangle's edges:** a stored point up to about 410 m west of
  72.004° E or 140 m south of 0.8293° N may have come from either side of the
  rectangle. Like the old drawing, the reading leaves it in place.
- **On the backend:** it stores and fingerprints the saved bytes and never
  converts. Group Ride progress there compares riders with the stored points,
  so for an affected version-1 route it stays unknown.

Other providers, such as GPX and Strava routes, are WGS-84 from the start.
The old rectangle only misdrew them, and they are not read again.

## Recovery

Reverting the precise region and shipping an app update restores the
rectangle. The Watch receives the same app update. Version-2 archives remain
valid, because validation accepts any positive normalization version.

Reading version-1 archives again writes nothing to them, so reverting it and
shipping an app update returns those routes to their stored geometry. An
elevation profile cached for the new geometry then no longer matches, and the
next online lookup replaces it. Neither change needs server or firmware
changes.
