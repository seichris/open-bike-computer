ALTER TABLE artifacts
    ADD COLUMN reader_requirements_json TEXT;

ALTER TABLE libraries
    ADD COLUMN merge_principal_count INTEGER NOT NULL DEFAULT 1
        CHECK (merge_principal_count BETWEEN 1 AND 8);

-- INSERT OR IGNORE is used to permit two publications to reference one exact
-- immutable artifact. Abort the transaction when either unique artifact
-- identity resolves to different metadata, so a publication event can never
-- finalize after silently losing a conflicting artifact insert race.
CREATE TRIGGER artifacts_exact_identity_guard
BEFORE INSERT ON artifacts
WHEN EXISTS (
    SELECT 1
      FROM artifacts AS existing
     WHERE (
               existing.id = NEW.id
            OR (
                   existing.bucket_slot = NEW.bucket_slot
               AND existing.object_key = NEW.object_key
            )
           )
       AND NOT (
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
           AND existing.state IS NEW.state
           AND existing.reader_requirements_json IS NEW.reader_requirements_json
       )
)
BEGIN
    SELECT RAISE(ABORT, 'artifact identity conflict');
END;
