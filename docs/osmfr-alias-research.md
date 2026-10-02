# OpenStreetMap France alias and exception research

Reviewed: **2026-09-06**. Runtime source of truth:
`map-platform/backend/map_platform/osmfr_fallback.py`.

## Method and confidence

This combines the research already on PR #412 with an additional audit of
African names, historical French regions, overseas territories and Australian
subdivisions. The resolver still constructs the same path by default and uses
**exact aliases only**. No prefix rewrite, inherited child alias, fuzzy matching,
global punctuation normalization, catalogue crawl or parent substitution occurs.

Source evidence: Geofabrik's official
[index](https://download.geofabrik.de/index-v1.json),
[index without geometry](https://download.geofabrik.de/index-v1-nogeom.json), and
[technical documentation](https://download.geofabrik.de/technical.html).
Destination evidence: OSM.fr's official
[extract listings](https://download.openstreetmap.fr/extracts/) and
[polygon directory](https://download.openstreetmap.fr/polygons/).
Each alias below links the destination PBF directory. Polygon filenames alone
were not treated as evidence that a PBF is available.

The review covers continent listings plus China, Japan, France, Germany,
the United Kingdom/England, Canada, four US regional directories, Russia,
Oceania, Australia and provider-supplied merged extracts. It is **not an
exhaustive recursive crawl** of all subdivisions. Some retrieved listings were
cached and their data timestamps differ. These are observed naming
correspondences, **not proofs of identical polygons or tested binary downloads**.
No full binary download or worldwide geometry-equivalence test was performed.

Identical paths are deliberately absent from the table, including Shanghai,
Jiangsu, Zhejiang, Tibet, Macau and Germany. New/unlisted canonical latest paths
are attempted as-is; a missing candidate can fail with 404. Neither failure nor
absence from a listing justifies selecting a similarly named larger/smaller
extract. Taiwan is not redirected to China or blocked solely because its
same-path alternative was not verified.

## Corrections and non-obvious cases

Geofabrik currently uses `inner-mongolia` and `tibet`. The initial examples
`neimenggu` and `xizang` are not verified current catalogue paths and are **not
aliases**. Their unlisted same-path candidates behave like any other unknown
path. Shaanxi and Shanxi stay distinct.

US states use regional parents and retain hyphens in `new-york` and
`north-carolina`; Canada's `new_brunswick` instead uses an underscore. Only
ten US state relocations were confirmed in the retrieved listings. No all-state
routing table was inferred from geography. Georgia the country moves from
`europe/` to `asia/`, while the US state moves to `us-south/`.

French overseas regions move out of Geofabrik's `europe/france/` hierarchy.
Bermuda moves to `north-america/bermuda`, and Falklands uses the distinct
`europe/united-kingdom/falklands` to `south-america/falkland` correspondence.
French Guiana (`guyane`) must not be confused with Guyana (`guyana`).

Geofabrik's Australian Capital Territory key is `act`; OSM.fr spells it
`australian_capital_territory`. Its Heard/McDonald destination literally spells
`heard_island_and_mcdonald_slands`; do not silently correct that published name.
Historical French-region naming matches below are not an assertion that their
polygons or current administrative boundaries are identical.

Fiji and Kiribati use OSM.fr's own [merged files](https://download.openstreetmap.fr/extracts/merge/).
Never select just `fiji_east` or `fiji_west`. Israel and Palestine likewise use
the combined `israel_and_palestine`, not one constituent or only the West Bank.
No local multi-PBF merge is implemented.

## Alias table

**86 exact naming aliases**, including the entries preserved from the concurrent
PR revision. Both columns omit `-latest.osm.pbf`; the source base is
`https://download.geofabrik.de/` and destination base is
`https://download.openstreetmap.fr/extracts/`. Every source path is referenced by
the Geofabrik index above. A rule changes only its complete source path, never
an arbitrary descendant. This remains an exception table, not an allowlist of
all supported regions.

| Geofabrik source path | OSM.fr candidate path | Destination evidence |
| --- | --- | --- |
| `africa/burkina-faso` | `africa/burkina_faso` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/cape-verde` | `africa/cape_verde` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/central-african-republic` | `africa/central_african_republic` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/comores` | `africa/comoros` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/congo-brazzaville` | `africa/congo_brazzaville` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/congo-democratic-republic` | `africa/congo_kinshasa` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/equatorial-guinea` | `africa/equatorial_guinea` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/ivory-coast` | `africa/ivory_coast` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/saint-helena-ascension-and-tristan-da-cunha` | `africa/saint_helena_ascension_tristan_da_cunha` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/sao-tome-and-principe` | `africa/sao_tome_and_principe` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/south-africa` | `africa/south_africa` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `africa/south-sudan` | `africa/south_sudan` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `asia/china/hong-kong` | `asia/china/hong_kong` | [Listing](https://download.openstreetmap.fr/extracts/asia/china/) |
| `asia/china/inner-mongolia` | `asia/china/inner_mongolia` | [Listing](https://download.openstreetmap.fr/extracts/asia/china/) |
| `asia/east-timor` | `asia/east_timor` | [Listing](https://download.openstreetmap.fr/extracts/asia/) |
| `asia/israel-and-palestine` | `asia/israel_and_palestine` | [Listing](https://download.openstreetmap.fr/extracts/asia/) |
| `australia-oceania/australia` | `oceania/australia` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `australia-oceania/australia/act` | `oceania/australia/australian_capital_territory` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/australia/ashmore-cartier` | `oceania/australia/ashmore_and_cartier_islands` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/australia/christmas-island` | `oceania/australia/christmas_island` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/australia/cocos-islands` | `oceania/australia/cocos_islands` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/australia/coral-sea-islands` | `oceania/australia/coral_sea_islands` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/australia/heard-mcdonald` | `oceania/australia/heard_island_and_mcdonald_slands` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/australia/norfolk-island` | `oceania/australia/norfolk_island` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/australia/northern-territory` | `oceania/australia/northern_territory` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/australia/south-australia` | `oceania/australia/south_australia` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/australia/western-australia` | `oceania/australia/western_australia` | [Listing](https://download.openstreetmap.fr/extracts/oceania/australia/) |
| `australia-oceania/cook-islands` | `oceania/cook_islands` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `australia-oceania/fiji` | `merge/fiji` | [Listing](https://download.openstreetmap.fr/extracts/merge/) |
| `australia-oceania/kiribati` | `merge/kiribati` | [Listing](https://download.openstreetmap.fr/extracts/merge/) |
| `australia-oceania/marshall-islands` | `oceania/marshall_islands` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `australia-oceania/new-caledonia` | `oceania/new_caledonia` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `australia-oceania/papua-new-guinea` | `oceania/papua_new_guinea` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `australia-oceania/solomon-islands` | `oceania/solomon_islands` | [Listing](https://download.openstreetmap.fr/extracts/oceania/) |
| `central-america/costa-rica` | `central-america/costa_rica` | [Listing](https://download.openstreetmap.fr/extracts/central-america/) |
| `central-america/el-salvador` | `central-america/el_salvador` | [Listing](https://download.openstreetmap.fr/extracts/central-america/) |
| `europe/czech-republic` | `europe/czech_republic` | [Listing](https://download.openstreetmap.fr/extracts/europe/) |
| `europe/france/basse-normandie` | `europe/france/basse_normandie` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/champagne-ardenne` | `europe/france/champagne_ardenne` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/franche-comte` | `europe/france/franche_comte` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/guadeloupe` | `central-america/guadeloupe` | [Listing](https://download.openstreetmap.fr/extracts/central-america/) |
| `europe/france/guyane` | `south-america/guyane` | [Listing](https://download.openstreetmap.fr/extracts/south-america/) |
| `europe/france/haute-normandie` | `europe/france/haute_normandie` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/ile-de-france` | `europe/france/ile_de_france` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/languedoc-roussillon` | `europe/france/languedoc_roussillon` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/martinique` | `central-america/martinique` | [Listing](https://download.openstreetmap.fr/extracts/central-america/) |
| `europe/france/mayotte` | `africa/mayotte` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `europe/france/midi-pyrenees` | `europe/france/midi_pyrenees` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/nord-pas-de-calais` | `europe/france/nord_pas_de_calais` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/pays-de-la-loire` | `europe/france/pays_de_la_loire` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/poitou-charentes` | `europe/france/poitou_charentes` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/provence-alpes-cote-d-azur` | `europe/france/provence_alpes_cote_d_azur` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/france/reunion` | `africa/reunion` | [Listing](https://download.openstreetmap.fr/extracts/africa/) |
| `europe/france/rhone-alpes` | `europe/france/rhone_alpes` | [Listing](https://download.openstreetmap.fr/extracts/europe/france/) |
| `europe/georgia` | `asia/georgia` | [Listing](https://download.openstreetmap.fr/extracts/asia/) |
| `europe/germany/nordrhein-westfalen` | `europe/germany/nordrhein_westfalen` | [Listing](https://download.openstreetmap.fr/extracts/europe/germany/) |
| `europe/united-kingdom` | `europe/united_kingdom` | [Listing](https://download.openstreetmap.fr/extracts/europe/) |
| `europe/united-kingdom/bermuda` | `north-america/bermuda` | [Listing](https://download.openstreetmap.fr/extracts/north-america/) |
| `europe/united-kingdom/england` | `europe/united_kingdom/england` | [Listing](https://download.openstreetmap.fr/extracts/europe/united_kingdom/) |
| `europe/united-kingdom/england/greater-london` | `europe/united_kingdom/england/greater_london` | [Listing](https://download.openstreetmap.fr/extracts/europe/united_kingdom/england/) |
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
| `north-america/us/puerto-rico` | `central-america/puerto_rico` | [Listing](https://download.openstreetmap.fr/extracts/central-america/) |
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

**14 exact source-level holds** take precedence over aliases. Independently
resolved children are not prefix-blocked. The source scopes are identified in
the Geofabrik index above; compare OSM.fr's corresponding directories.

In particular, Geofabrik explicitly advertises Guangdong including Hong Kong
and Macau, Hebei including Beijing and Tianjin, Indonesia including East Timor,
and New South Wales including ACT and JBT. See
[Geofabrik China](https://download.geofabrik.de/asia/china.html),
[Geofabrik Australia](https://download.geofabrik.de/australia-oceania/australia.html),
[OSM.fr China](https://download.openstreetmap.fr/extracts/asia/china/),
[OSM.fr Asia](https://download.openstreetmap.fr/extracts/asia/), and
[OSM.fr Australia](https://download.openstreetmap.fr/extracts/oceania/australia/).
OSM.fr lists constituent areas separately. **Separate listings do not themselves
prove omission from a parent polygon**: these are conservative holds until
combined coverage is verified, not claims of measured missing border nodes.

Do not reduce Guernsey/Jersey, Senegal/Gambia, South Africa/Lesotho,
Malaysia/Singapore/Brunei, Haiti/Dominican Republic, GCC states or all-island
Ireland to only one member. Great Britain is not the same scope as the UK.
No one US quadrant represents a whole-US source. These holds are not assertions
that OSM.fr can never publish a matching union; review the full replacement
before removing a hold, or implement geometry-aware/multi-extract handling
separately. Unknown paths and continent paths are not blanket-blocked.

| Geofabrik source path | Reason |
| --- | --- |
| `africa/senegal-and-gambia` | Combined source; Senegal alone omits Gambia. |
| `africa/south-africa-and-lesotho` | Combined source; South Africa alone may omit Lesotho. |
| `asia/china/guangdong` | Geofabrik includes Hong Kong and Macau; matching combined coverage is unverified. |
| `asia/china/hebei` | Geofabrik includes Beijing and Tianjin; matching combined coverage is unverified. |
| `asia/gcc-states` | Combined source; no single member is an equivalent extract. |
| `asia/indonesia` | Geofabrik explicitly includes East Timor; OSM.fr publishes it separately. |
| `asia/malaysia-singapore-brunei` | Combined source; Malaysia alone omits Singapore and Brunei. |
| `australia-oceania/australia/new-south-wales` | Geofabrik explicitly includes ACT and JBT; a state-only alias is unverified. |
| `central-america/haiti-and-domrep` | Combined source; Haiti or Dominican Republic alone is incomplete. |
| `europe/britain-and-ireland` | Combined source; neither the UK nor Ireland alone suffices. |
| `europe/great-britain` | Great Britain is not the same source scope as the United Kingdom. |
| `europe/guernsey-jersey` | Combined islands must not become only guernesey or only jersey. |
| `europe/ireland-and-northern-ireland` | Combined source; Ireland alone omits Northern Ireland. |
| `north-america/us` | OSM.fr publishes regional US quadrants; none alone covers the whole US. |

## Cache migration and validation

Adding the Guangdong/Hebei scope holds removes their previous same-path fallback
URLs from the cache's accepted alternatives. An existing fallback entry must
therefore revalidate against Geofabrik rather than remain accepted as fresh;
failed refreshes preserve the old bytes and metadata but do not return them as
a successful refresh. Primary-first ordering, provider-isolated validators,
partial-transfer cleanup, cancellation, storage reserve, hashing, atomic
publication, pinned sources and bounded PBF header validation are unchanged.

The current downloader is not aware of the requested map cutout. Matching a
name or receiving HTTP 200 does not prove that an alternative covers that
cutout. This remains download failover after source resolution, not an
independent OSM.fr catalogue; cold discovery still depends on Geofabrik when
no cached catalogue is available.

## Maintaining the table

Before adding an alias, verify the exact Geofabrik URL and advertised scope,
find the full published destination PBF path, and inspect polygons and the
required map area where completeness matters. Record evidence here, including
all parent segments. Do not infer aliases by punctuation, basename, political
labels, parent substitution or an incomplete list of US/German states.
Unconfirmed subdivision paths remain literal same-path candidates.

Add a concrete expected-URL test and any similarly named or unsafe combined
variant. Exact aliases must not be identity mappings or overlap exceptions.
The original resolver tests and `test_osmfr_additional_aliases.py` check that
this document covers every runtime record. `test_osmfr_case_fallback.py` covers
new candidates, normal 404 failure, stable cache preservation, primary recovery
and invalidation of a formerly accepted fallback. These tests use synthetic
HTTP responses, not public-provider availability or real-map assertions.

From a complete checkout with backend dependencies:

```sh
cd map-platform/backend
python -m unittest discover -s tests -p 'test_osmfr_*.py'
python -m unittest discover -s tests -p 'test_source_cache.py'
```

See the [fallback guide](osm-source-fallback.md) for configuration and the
unchanged download protections. No iOS, firmware or deployment changes are
introduced by the alias-table revision.
