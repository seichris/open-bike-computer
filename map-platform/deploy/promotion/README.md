# Automatic development-map promotion

Completed development maps in the production catalog are discovered by a
production-only signed internal endpoint, including maps published before this
feature was deployed. Discovery is keyset-paginated and excludes blocked,
tombstoned, missing/non-live ZIP artifacts and maps already available in production.
Development credentials cannot enumerate candidates or promote them.

The separate scheduler calls the existing `promote-catalog-map` CLI, one map at
a time. That command acquires a catalog lease, verifies the exact source ZIP and
receipts, validates renderer compatibility, converts the existing artifact,
signs with the production key, verifies object storage and finalizes publication.
It does not fetch Geofabrik, regenerate OSM data, change library ownership or
bypass app/device reader requirements. A valid map can still require a newer
app/device firmware; automatic publication does not erase those requirements.

SQLite retry state survives restarts under
`$MAP_PLATFORM_DATA_ROOT/automatic-promotion`. Failed maps back off from one minute
to six hours without starving other maps. Rediscovery preserves backoff. A local
file lock prevents duplicate schedulers on one volume; catalog leases coordinate
other hosts and manual promotion. CLI errors/output are suppressed because they
may contain signed URLs; logs expose only map ID, attempt and safe error category.
Successful publication is idempotent if its response is lost.

## Release and activation

The dedicated Dockerfile puts the scheduling module under `/opt/bicino-promotion`,
outside the qualified converter's hashed `/app` source tree. Its validation stage
requires every `/app` file to match the base, runs the real converter identity
check, and runs both scheduler and existing promotion tests. The original
converter/signer producer identity remains accurate because that code is unchanged.
No API or map-generation worker image is replaced by this candidate.

Run local validation using OrbStack:

```sh
docker build --platform linux/amd64 --target validation -f map-platform/deploy/promotion/Dockerfile .
```

After source review and merge, publish an attested candidate from main:

```sh
gh workflow run map-platform-image.yml --ref main -f release_profile=production-map-promotion
```

This profile never moves `latest` or opens normal worker/control-plane promotions.
Activate only via a separately reviewed digest-pinned deployment manifest after
the production catalog migration `0010` and Worker endpoint are deployed. Supply
production catalog, object-store and signing configuration to the scheduler only;
never put production signing credentials on development servers. Set
`MAP_PLATFORM_AUTO_PROMOTION_ENABLED=1`, persist `/data`, and use a single scheduler
with bounded CPU/memory. Check its `automatic-promotion/heartbeat.json` (allow at
least 1800 seconds for a conversion) and retry/completion logs. Stopping this
service disables automation without deleting maps or rolling back promotions.

Staging and production catalogs remain separate. This discovers development
publications already in the production catalog; it does not copy libraries from
the staging catalog or infer ownership of orphaned historical downloads.

Physical proof requires refreshing regular Bicino's library and successfully
transferring a promoted map to a compatible device. Backend publication alone is
not proof of an iPhone/device transfer.
