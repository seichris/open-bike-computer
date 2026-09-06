# OpenStreetMap France alias and exception research

Reviewed: **2026-09-06**. Runtime source of truth:
`map-platform/backend/map_platform/osmfr_fallback.py`.

## Method and confidence

The review compared Geofabrik's published PBF URLs and names in its official
[index](https://download.geofabrik.de/index-v1.json) (also available
[without geometry](https://download.geofabrik.de/index-v1-nogeom.json)) against
OSM.fr's official [extract listings](https://download.openstreetmap.fr/extracts/)
and [polygon directory](https://download.openstreetmap.fr/polygons/).
The table below records observed naming correspondences and directory moves,
**not identical polygon coverage or tested binary downloads**. Directory evidence
is a point-in-time observation; cached listings and extract timestamps can lag.

This is a reviewed set of differences, not an exhaustive match of every provider
subregion. Ordinary identical paths are deliberately absent. They are derived
per request, including newly published regions. Missing/unverified aliases are
not guessed from punctuation, a basename, a parent region or a political label.
An unpublished same-path candidate can fail with 404; that is not evidence that
the similarly named larger/smaller extract is safe to substitute.

The review included the continent listings, China, Japan, Canada, the four US
regional directories, Germany, the UK, Russia, Oceania and its merged extracts.
Only the ten US state relocations listed below were confirmed in the retrieved
regional listings; no claim is made that those listings constitute all of OSM.fr.
No 50-state routing table was inferred from US geography. Likewise, unconfirmed
German-state, Australian-state and other subdivision spellings were not added.

## Corrections and non-obvious cases

Geofabrik currently calls the China sources `inner-mongolia` and `tibet`.
The original examples `neimenggu` and `xizang` were not in the retrieved catalogue
and have been removed from the alias table. Tibet, Macau, Shanghai, Jiangsu,
Zhejiang, Shaanxi and Shanxi use the default same path; the last two stay distinct.

US New York becomes `us-northeast/new-york`, **not** `us-northeast/new_york`.
Canada's New Brunswick instead uses `new_brunswick`. Georgia the country moves
from Geofabrik's `europe/` to OSM.fr's `asia/`; the US state moves to `us-south/`.
Falkland Islands are under Geofabrik's `europe/united-kingdom/falklands` but
OSM.fr's `south-america/falkland`. These rule keys therefore include the full path.

For Fiji, OSM.fr publishes separate east/west extracts and a
[merged file](https://download.openstreetmap.fr/extracts/merge/).
Use `merge/fiji`, never only `oceania/fiji_east` or `oceania/fiji_west`.
Israel and Palestine also have a combined OSM.fr extract: the alias points to
`israel_and_palestine`, not to either constituent or only the West Bank.

Geofabrik explicitly labels Indonesia as including East Timor, and New South
Wales as including ACT and JBT. Their shorter destination names are not enough
to establish preservation of that broader scope, so those parent sources are
conservatively excluded. Independently requested children are not prefix-blocked.

Taiwan has no researched alternative alias here. It is **not** redirected to
China or permanently blocked merely because it was absent from a retrieved
listing; its exact same-path candidate is allowed to succeed or fail normally.

## Alias table

Both columns omit `-latest.osm.pbf`. Prefix the source with
`https://download.geofabrik.de/` and the destination with
`https://download.openstreetmap.fr/extracts/`.
Every source path is referenced by the Geofabrik index above; each row links
the official directory where the destination PBF was listed.

| Geofabrik source path | OSM.fr candidate path | Destination evidence |
| --- | --- | --- |
| `africa/congo-brazzaville` | `africa/congo_brazzaville` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/congo-democratic-republic` | `africa/congo_kinshasa` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/equatorial-guinea` | `africa/equatorial_guinea` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/ivory-coast` | `africa/ivory_coast` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/south-africa` | `africa/south_africa` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/south-sudan` | `africa/south_sudan` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `asia/china/hong-kong` | `asia/china/hong_kong` | [Listing](https://download.openstreetmap.fr/extracts/asia/china/) |
| `asia/china/inner-mongolia` | `asia/china/inner_mongolia` | [Listing](https://download.openstreetmap.fr/extracts/asia/china/) |
| `asia/east-timor` | `asia/east_timor` | [Listing](https://download.openstreetmap.fr/extracts/asia/) |
| `asia/israel-and-palestine` | `asia/israel_and_palestine` | [Listing](https://download.openstreetmap.fr/extracts/asia/) |
| `australia-oceania/australia` | `oceania/australia` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `australia-oceania/fiji` | `merge/fiji` | [Listing](https://download.openstreetmap.fr/extracts/merge/) |
| `australia-oceania/new-caledonia` | `oceania/new_caledonia` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `australia-oceania/papua-new-guinea` | `oceania/papua_new_guinea` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `australia-oceania/solomon-islands` | `oceania/solomon_islands` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `central-america/costa-rica` | `central-america/costa_rica` | [Listing](https://download.openstreetmap.fr/extracts/central-america/) |
| `central-america/el-salvador` | `central-america/el_salvador` | [Listing](https://download.openstreetmap.fr/extracts/central-america/) |
| `europe/czech-republic` | `europe/czech_republic` | [Listing](https://download.openstreetmap.fr/extracts/europe/) |
| `europe/georgia` | `asia/georgia` | [Listing](https://download.openstreetmap.fr/extracts/asia/) |
| `europe/germany/nordrhein-westfalen` | `europe/germany/nordrhein_westfalen` | [Listing](https://download.openstreetmap.fr/extracts/europe/germany/) |
| `europe/united-kingdom` | `europe/united_kingdom` | [Listing](https://download.openstreetmap.fr/extracts/europe/) |
| `europe/united-kingdom/england` | `europe/united_kingdom/england` | [Listing](https://download.openstreetmap.fr/extracts/europe/united_kingdom/) |
| `europe/united-kingdom/falklands` | `south-america/falkland` | [Listing](https://download.openstreetmap.fr/extracts/south-america/) |
| `north-america/canada/british-columbia` | `north-america/canada/british_columbia` | [Listing](https://download.openstreetmap.fr/extracts/north-america/canada/) |
| `north-america/canada/new-brunswick` | `north-america/canada/new_brunswick` | [Listing](https://download.openstreetmap.fr/extracts/north-america/canada/) |
| `north-america/canada/newfoundland-and-labrador` | `north-america/canada/newfoundland_and_labrador` | [Listing](https://download.openstreetmap.fr/extracts/north-america/canada/) |
| `north-america/canada/northwest-territories` | `north-america/canada/northwest_territories` | [Listing](https://download.openstreetmap.fr/extracts/north-america/canada/) |
| `north-america/canada/nova-scotia` | `north-america/canada/nova_scotia` | [Listing](https://download.openstreetmap.fr/extracts/north-america/canada/) |
| `north-america/canada/prince-edward-island` | `north-america/canada/prince_edward_island` | [Listing](https://download.openstreetmap.fr/extracts/north-america/canada/) |
| `north-america/us/california` | `north-america/us-west/california` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-west/) |
| `north-america/us/colorado` | `north-america/us-west/colorado` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-west/) |
| `north-america/us/florida` | `north-america/us-south/florida` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-south/) |
| `north-america/us/georgia` | `north-america/us-south/georgia` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-south/) |
| `north-america/us/illinois` | `north-america/us-midwest/illinois` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-midwest/) |
| `north-america/us/michigan` | `north-america/us-midwest/michigan` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-midwest/) |
| `north-america/us/new-york` | `north-america/us-northeast/new-york` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-northeast/) |
| `north-america/us/north-carolina` | `north-america/us-south/north-carolina` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-south/) |
| `north-america/us/texas` | `north-america/us-south/texas` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-south/) |
| `north-america/us/virginia` | `north-america/us-south/virginia` | [Listing](https://download.openstreetmap.fr/extracts/north-america/us-south/) |
| `russia/central-fed-district` | `russia/central_federal_district` | [Listing](https://download.openstreetmap.fr/extracts/russia/) |
| `russia/far-eastern-fed-district` | `russia/far_eastern_federal_district` | [Listing](https://download.openstreetmap.fr/extracts/russia/) |
| `russia/north-caucasus-fed-district` | `russia/north_caucasian_federal_district` | [Listing](https://download.openstreetmap.fr/extracts/russia/) |
| `russia/northwestern-fed-district` | `russia/northwestern_federal_district` | [Listing](https://download.openstreetmap.fr/extracts/russia/) |
| `russia/siberian-fed-district` | `russia/siberian_federal_district` | [Listing](https://download.openstreetmap.fr/extracts/russia/) |
| `russia/south-fed-district` | `russia/southern_federal_district` | [Listing](https://download.openstreetmap.fr/extracts/russia/) |
| `russia/ural-fed-district` | `russia/ural_federal_district` | [Listing](https://download.openstreetmap.fr/extracts/russia/) |
| `russia/volga-fed-district` | `russia/volga_federal_district` | [Listing](https://download.openstreetmap.fr/extracts/russia/) |

## Scope exceptions (no automatic candidate)

The source scopes are identified in the Geofabrik index above. Compare the
OSM.fr [Asia](https://download.openstreetmap.fr/extracts/asia/),
[Africa](https://download.openstreetmap.fr/extracts/africa/),
[Central America](https://download.openstreetmap.fr/extracts/central-america/),
[Europe](https://download.openstreetmap.fr/extracts/europe/),
[UK](https://download.openstreetmap.fr/extracts/europe/united_kingdom/),
[North America](https://download.openstreetmap.fr/extracts/north-america/) and
[Australian polygons](https://download.openstreetmap.fr/polygons/oceania/australia/).
These exclusions express an unresolved scope mismatch, not a claim that OSM.fr
can never publish a corresponding union. Remove an exclusion only after reviewing
the full replacement, or implement explicit multi-extract assembly separately.

| Geofabrik source path | Reason |
| --- | --- |
| `africa/senegal-and-gambia` | Combined source; Senegal alone omits Gambia. |
| `africa/south-africa-and-lesotho` | Combined source; South Africa alone may omit Lesotho. |
| `asia/gcc-states` | Combined source; no single member is an equivalent extract. |
| `asia/indonesia` | Geofabrik explicitly includes East Timor; OSM.fr publishes it separately. |
| `asia/malaysia-singapore-brunei` | Combined source; Malaysia alone omits Singapore and Brunei. |
| `australia-oceania/australia/new-south-wales` | Geofabrik explicitly includes ACT and JBT; a state-only alias is unverified. |
| `central-america/haiti-and-domrep` | Combined source; Haiti or Dominican Republic alone is incomplete. |
| `europe/britain-and-ireland` | Combined source; neither the UK nor Ireland alone suffices. |
| `europe/great-britain` | Great Britain is not the same source scope as the United Kingdom. |
| `europe/ireland-and-northern-ireland` | Combined source; Ireland alone omits Northern Ireland. |
| `north-america/us` | OSM.fr publishes regional US quadrants; none alone covers the whole US. |

## Unresolved cases and maintenance

Do not map a whole US source to a single quadrant, a combined country extract to
one country, an island group to one province, or Great Britain to the UK merely
to obtain HTTP 200. The same caution applies to Geofabrik's American Oceania,
Micronesia/Polynesia, India zones, Indonesia island groups, historical French
regions and changed Russian district boundaries: this change does not attempt
to establish their coverage equivalence. Absent an exact alias, only the literal
same-path candidate is constructed unless an explicit scope exception blocks it.

Before adding an alias, inspect the exact Geofabrik PBF URL and advertised scope,
find a published destination PBF, inspect the corresponding polygon and intended
map area where boundary completeness matters, and record the evidence here.
Do not treat a polygon filename alone as proof a downloadable PBF exists.
Add a concrete expected-URL test, including any similarly named region or unsafe
combined variant. Aliases must not be identical source/destination pairs and
must not overlap exceptions. Tests enforce these properties and that this
research table documents every runtime entry.

The current downloader still carries the resolved source identity through the
cache and is not aware of the requested map cutout. Choosing a smaller OSM.fr
extract based on the user's actual bounding box would require a separate,
geometry-aware source-resolution change. This PR intentionally does not claim
that an alias table or a PBF header check solves geographic completeness.
