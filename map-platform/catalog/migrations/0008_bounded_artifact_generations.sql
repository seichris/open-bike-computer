ALTER TABLE artifacts
    ADD COLUMN generation_class TEXT;

ALTER TABLE artifacts
    ADD COLUMN superseded_at TEXT;

ALTER TABLE artifacts
    ADD COLUMN generation_head INTEGER NOT NULL DEFAULT 0
        CHECK (generation_head IN (0, 1));

-- Legacy stream rows used the same descriptor-derived v1 reader contract at
-- grant time. Persist that canonical derivation before classifying them so a
-- new producer build replaces, rather than forks, the legacy generation.
UPDATE artifacts AS artifact
   SET reader_requirements_json = (
       SELECT json_object(
           'schemaVersion', 1,
           'streamFormat', 'bike-map-stream-v1',
           'manifestSchemaVersion', 1,
           'renderer', map_entry.renderer,
           'rendererFormatVersion', map_entry.renderer_format_version,
           'requiredFeatures', json(map_entry.features_json)
       )
         FROM map_entries map_entry
        WHERE map_entry.id = artifact.map_entry_id
   )
 WHERE artifact.format = 'bike-map-stream-v1'
   AND artifact.reader_requirements_json IS NULL;

-- A generation class is the exact delivery/reader/signing contract that one
-- live artifact must continue to satisfy. Producer identities are deliberately
-- excluded so rebuilding the same bytes contract creates a replacement rather
-- than an ever-growing compatibility class.
UPDATE artifacts
   SET generation_class = json_object(
       'schemaVersion', 1,
       'bucketSlot', bucket_slot,
       'deliveryTier', delivery_tier,
       'format', format,
       'signatureKeyId', signature_key_id,
       'signatureKeySha256', signature_key_sha256,
       'readerRequirementsJSON', reader_requirements_json,
       'requiredFirmwareVersion', required_firmware_version,
       'requiredFirmwareBuild', required_firmware_build,
       'requiredFirmwareGitSha', required_firmware_git_sha
   );

UPDATE artifacts AS candidate
   SET generation_head = 1
 WHERE candidate.state = 'live'
   AND NOT EXISTS (
       SELECT 1 FROM artifacts newer
        WHERE newer.map_entry_id = candidate.map_entry_id
          AND newer.generation_class = candidate.generation_class
          AND newer.state = 'live'
          AND (
               newer.created_at > candidate.created_at
               OR (
                    newer.created_at = candidate.created_at
                    AND newer.id > candidate.id
               )
          )
   );

-- Refuse to apply this policy over an already-unbounded database. Operators
-- must explicitly retire excess compatibility classes instead of silently
-- dropping a reader/signing contract during migration.
CREATE TABLE migration_0008_generation_bound_guard (
    valid INTEGER NOT NULL CHECK (valid = 1)
);
INSERT INTO migration_0008_generation_bound_guard(valid)
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM artifacts
     WHERE state = 'live' AND generation_head = 1
     GROUP BY map_entry_id
    HAVING COUNT(DISTINCT generation_class) > 16
) THEN 0 ELSE 1 END;
DROP TABLE migration_0008_generation_bound_guard;

CREATE INDEX artifacts_generation_selection_idx
    ON artifacts(map_entry_id, generation_class, generation_head, state, created_at DESC, id DESC);

CREATE UNIQUE INDEX artifacts_live_generation_head_idx
    ON artifacts(map_entry_id, generation_class)
    WHERE generation_head = 1;

DROP TRIGGER artifacts_exact_identity_guard;

-- State and supersession are lifecycle fields, not immutable object identity.
-- A previously superseded exact object may be verified and made current again;
-- quarantined or zero-reference tombstones remain fail-closed.
CREATE TRIGGER artifacts_exact_identity_guard
BEFORE INSERT ON artifacts
WHEN NEW.generation_class IS NULL
  OR length(NEW.generation_class) NOT BETWEEN 1 AND 8192
  OR EXISTS (
    SELECT 1
      FROM artifacts AS existing
     WHERE (
               existing.id = NEW.id
            OR (
                   existing.bucket_slot = NEW.bucket_slot
               AND existing.object_key = NEW.object_key
            )
           )
       AND (
            NOT (
                   existing.id IS NEW.id
               AND existing.map_entry_id IS NEW.map_entry_id
               AND existing.bucket_slot IS NEW.bucket_slot
               AND existing.object_key IS NEW.object_key
               AND existing.format IS NEW.format
               AND existing.media_type IS NEW.media_type
               AND existing.filename IS NEW.filename
               AND existing.byte_count IS NEW.byte_count
               AND existing.sha256 IS NEW.sha256
               AND existing.manifest_receipt IS NEW.manifest_receipt
               AND existing.signed_manifest_receipt IS NEW.signed_manifest_receipt
               AND existing.signature_key_id IS NEW.signature_key_id
               AND existing.signature_key_sha256 IS NEW.signature_key_sha256
               AND existing.producer_build_sha256 IS NEW.producer_build_sha256
               AND existing.producer_image_digest IS NEW.producer_image_digest
               AND existing.required_ios_build IS NEW.required_ios_build
               AND existing.required_ios_git_sha IS NEW.required_ios_git_sha
               AND existing.required_ios_build_sha256 IS NEW.required_ios_build_sha256
               AND existing.required_firmware_version IS NEW.required_firmware_version
               AND existing.required_firmware_build IS NEW.required_firmware_build
               AND existing.required_firmware_git_sha IS NEW.required_firmware_git_sha
               AND existing.delivery_tier IS NEW.delivery_tier
               AND existing.reader_requirements_json IS NEW.reader_requirements_json
               AND existing.generation_class IS NEW.generation_class
            )
            OR (
                 existing.state <> 'live'
                 AND existing.superseded_at IS NULL
            )
            OR EXISTS (
                 SELECT 1 FROM artifact_deletion_leases lease
                  WHERE lease.artifact_id = existing.id
                    AND lease.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            )
       )
  )
BEGIN
    SELECT RAISE(ABORT, 'artifact identity conflict');
END;

CREATE TRIGGER artifacts_live_generation_class_limit
BEFORE INSERT ON artifacts
WHEN NOT EXISTS (
        SELECT 1 FROM artifacts existing
         WHERE existing.map_entry_id = NEW.map_entry_id
           AND existing.generation_class = NEW.generation_class
           AND existing.generation_head = 1
           AND existing.state = 'live'
     )
 AND (
        SELECT COUNT(DISTINCT existing.generation_class)
          FROM artifacts existing
         WHERE existing.map_entry_id = NEW.map_entry_id
           AND existing.generation_head = 1
           AND existing.state = 'live'
     ) >= 16
BEGIN
    SELECT RAISE(ABORT, 'artifact generation class limit');
END;

-- Collapse legacy duplicate generations immediately when they are not serving
-- a live download or promotion. Protected rows stop being selection heads but
-- remain resolvable by their existing grant until maintenance observes expiry.
UPDATE artifacts AS older
   SET superseded_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
       verified_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
 WHERE older.state IN ('live', 'quarantined')
   AND older.generation_head = 0
   AND EXISTS (
       SELECT 1 FROM artifacts AS replacement
        WHERE replacement.map_entry_id = older.map_entry_id
          AND replacement.generation_class = older.generation_class
          AND replacement.generation_head = 1
          AND replacement.state = 'live'
   )
   AND older.superseded_at IS NULL;

UPDATE artifacts AS older
   SET state = 'tombstoned'
 WHERE older.state IN ('live', 'quarantined')
   AND older.generation_head = 0
   AND older.superseded_at IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM download_grants grant_row
        WHERE grant_row.artifact_id = older.id
          AND grant_row.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
   )
   AND NOT EXISTS (
       SELECT 1 FROM promotion_leases lease
        WHERE lease.source_artifact_id = older.id
          AND lease.state = 'active'
          AND lease.expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
   );
