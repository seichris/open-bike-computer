# Proposal: keep the elevation tiles between builds

Status: **proposed on 2026-11-26, not decided, nothing built.** A bucket costs
money every month, so the decision is Chris's.

## The problem

Every graded planet build spends its first 2 hours 20 minutes on elevation
tiles: 72 minutes to read 589 GB of Copernicus DEM from the public mirrors and
write the raw tiles, then 67 minutes to open them. The Copernicus data is the
2021 release and does not change. The tiles are deleted with the builder, so
the next build makes the same files again. Three builds did so between
2026-11-24 and 2026-11-26.

The download is also the least reliable stage. On 2026-11-25 four cells ran
past the 15-minute deadline and the run stopped in its third round.

| Tile set | Files | Size |
|---|---|---|
| Raw Copernicus tiles | 26,475 | 160.4 GB (149.4 GiB) |
| Opened at 200 m | 26,475 | 104.2 GB (97.0 GiB) |
| Opened at 400 m | 26,475 | 83.9 GB (78.1 GiB) |

## What could be kept

**A. The raw tiles.** Every opening radius reads the same raw tiles, so they
serve any later attempt that opens Copernicus. A build that restores them
skips the 72-minute download and still opens them for 67 minutes.

**B. One opened set**, for example 400 m. It serves only builds that grade
with exactly that method. A build that restores it skips the whole elevation
stage.

**C. Both.**

**D. Nothing**, as today.

## Time saved

The chain's long path today is `elevation` (2 h 20 min), then `build-graded`
(4 h 50 min), then the gate: about 7.5 hours. The graded build cannot start
before the download of the planet has finished, 35 minutes in.

| Kept | Graded build starts | Chain ends | Saved per graded build |
|---|---|---|---|
| Nothing | 2 h 20 min | about 7 h 15 min | – |
| Raw tiles | about 1 h 25 min (restore, then 67 min of opening) | about 6 h 20 min | about 55 min |
| The opened set | 35 min, with the ungraded build | about 5 h 30 min | about 1 h 45 min |

The restore times are estimates: 15 minutes for 149 GiB and 10 minutes for
78 GiB from a bucket in the builder's region, with the check below. Nobody
has measured them.

The builder costs about $2 an hour (the 8 idle hours of 2026-11-25 were put
at about $16). So a restored opened set saves about $3.50 per graded build,
and restored raw tiles about $2. The larger gains are the gate's answer
almost two hours sooner and no dependence on the Copernicus mirrors.

## Cost per month

Google's list prices for a regional bucket, read from
`cloud.google.com/storage/pricing` on 2026-11-26. The page showed them for
its default region (Iowa); **confirm the `europe-west4` prices in the billing
console before deciding.** Storage is billed per GiB.

| Class | Price per GiB per month | Raw (149.4 GiB) | Opened 400 m (78.1 GiB) | Both | Read fee per restore | Minimum stay |
|---|---|---|---|---|---|---|
| Standard | $0.020 | $2.99 | $1.56 | $4.55 | none | none |
| Nearline | $0.010 | $1.49 | $0.78 | $2.28 | $0.01 per GiB: $1.49 raw, $0.78 opened | 30 days |
| Coldline | $0.004 | $0.60 | $0.31 | $0.91 | $0.02 per GiB: $2.99 raw, $1.56 opened | 90 days |
| Archive | $0.0012 | $0.18 | $0.09 | $0.27 | $0.05 per GiB: $7.47 raw, $3.91 opened | 365 days |

- Reading from a bucket into a VM in the same region has no transfer charge.
- Uploading 26,475 tiles and their receipts is about 53,000 write operations:
  $0.27 once at the Standard rate. Packing each latitude directory into one
  tar file (about 180 objects) makes this negligible and the restore faster.
- A set deleted before its minimum stay is billed for the whole stay.

With one graded build a month, Standard storage of the opened set costs
about half of what the build saves, and Nearline a quarter, plus $0.78 per
restore. With no graded build in a month, the bucket only costs.

## How a build would check the cached set

A cached tile must be exactly the tile `build_elevation.py` would write. The
elevation manifest already makes that checkable:

- `cells.txt` lists every cell with the SHA-256 of its unpacked posts.
- The manifest's `cellListSha256` is the SHA-256 of `cells.txt`.
- An opened manifest's `method` names the radius and the raw manifest it was
  opened from (`input.manifestSha256`, `input.cellListSha256`).
- The graph manifest records the elevation manifest's SHA-256, so a shipped
  graph names its tiles.

The check, before `build-graded` may start:

1. The repository pins the approved set: the SHA-256 of its
   `elevation-manifest.json`, in a small file under `releases/`. The run names
   the set it wants; nothing is taken from the bucket's own word.
2. The restored manifest must have that SHA-256, `catalogCells` equal to
   `cells`, no `bounds`, and the policy and method the run asked for.
3. `cells.txt` must hash to the manifest's `cellListSha256`.
4. Every tile is unpacked and hashed and must match its line in `cells.txt`:
   26,475 files, 690 GB unpacked, a few minutes on 24 cores. No tile may be
   missing or extra.
5. Any mismatch fails the stage. The stage then falls back to building the
   tiles, which is today's path.

For restored **raw** tiles nothing new is needed after steps 1 to 3:
`build_elevation.py` finds their receipts, builds nothing, and the opening
already refuses a raw tile that does not match its receipt. For a restored
**opened** set, step 4 is a new small tool, about a day with its tests.

## What it would take

- A bucket in `europe-west4` with uniform access and public access prevented.
- The builder holds no credentials today. It would get a service account
  that can read this one bucket and nothing else. The build that fills the
  bucket would get one that can create objects there and cannot overwrite or
  delete them.
- A `restore` step at the start of the `elevation` stage and an upload step
  after a build whose gate passed, both off unless the run asks for them.
- `provision.sh` gains the service account as an option.

The tiles derive from the Copernicus sources the topography source policy
already approves, and a private bucket shares them with nobody.

## What speaks for and against it now

- No graded graph has shipped. The planet graded at 400 m missed the gate
  on 2026-11-26 in New York and Chicago, so the 400 m set alone will not
  ship.
- The runbook now proposes a hybrid: USGS 3DEP in the United States and
  Copernicus opened at 400 m everywhere else (see
  [USGS 3DEP](../refresh-runbook.md#usgs-3dep-for-the-united-states-on-city-samples)).
  It waits for Chris's approval of 3DEP as a source. **If he approves it,
  the next planet build needs exactly the 400 m opened set**, and a kept
  copy saves that build 2 hours 20 minutes of its elevation stage. The 3DEP
  tiles, up to 494 GB of downloads, would be a third set to keep.
- If the hybrid is not approved and another source is tried, neither
  Copernicus set is needed.
- City samples now judge a method before a planet is built (see
  [Tower-city samples](../refresh-runbook.md#tower-city-samples)), so fewer
  planet builds should be thrown away, and fewer tile sets with them.

## The choice

1. **Do nothing now.** Decide again when a method has passed the gate on a
   planet. That build's tiles would then be uploaded before its builder is
   deleted, so filling the bucket costs no extra build.
2. **Keep the raw and the 400 m opened tiles of the 2026-11-26 builder**, in
   Nearline: about $2.30 a month. This is worth it if the hybrid is
   approved. That builder still held both sets on the afternoon of
   2026-11-26 and deletes itself about 05:40 UTC on 2026-11-27; after that,
   filling the bucket means building the tiles again. The builder has no
   service account, and attaching one means stopping the VM first. So the
   upload would need a bucket and a short-lived credential that Chris issues
   for it.
3. **Keep raw and opened tiles from the first build that passes the gate.**
   Once a graded graph is in production, every monthly refresh needs the
   same tiles, and the cache then pays for itself each month.

My recommendation: 2 if Chris means to approve the hybrid and can act before
the builder is gone, otherwise 1 now and 3 when a graded graph ships. It is
Chris's decision.
