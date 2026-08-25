CREATE TABLE promotion_leases (
    map_entry_id TEXT PRIMARY KEY REFERENCES map_entries(id) ON DELETE CASCADE,
    lease_id TEXT NOT NULL UNIQUE,
    source_artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE RESTRICT,
    source_object_key TEXT NOT NULL,
    source_byte_count INTEGER NOT NULL CHECK (source_byte_count > 0),
    source_sha256 TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active', 'finalized')),
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    finalized_at TEXT,
    production_publication_id TEXT,
    production_artifact_id TEXT
);

CREATE INDEX promotion_leases_expiry_idx
    ON promotion_leases(state, expires_at);

ALTER TABLE download_grants
    ADD COLUMN promotion_lease_id TEXT
        REFERENCES promotion_leases(lease_id)
        ON UPDATE CASCADE ON DELETE CASCADE;

CREATE INDEX download_grants_promotion_lease_idx
    ON download_grants(promotion_lease_id, expires_at);

ALTER TABLE publication_events
    ADD COLUMN promotion_lease_id TEXT
        REFERENCES promotion_leases(lease_id)
        ON UPDATE CASCADE ON DELETE SET NULL;

CREATE UNIQUE INDEX publication_events_promotion_lease_idx
    ON publication_events(promotion_lease_id)
    WHERE promotion_lease_id IS NOT NULL;

CREATE TRIGGER promotion_publication_requires_live_lease
BEFORE INSERT ON publication_events
WHEN NEW.promotion_lease_id IS NOT NULL
BEGIN
    SELECT CASE WHEN NEW.channel <> 'production' OR NOT EXISTS (
        SELECT 1
          FROM promotion_leases lease
          JOIN artifacts source ON source.id = lease.source_artifact_id
         WHERE lease.lease_id = NEW.promotion_lease_id
           AND lease.map_entry_id = NEW.map_entry_id
           AND lease.state = 'active'
           AND lease.expires_at > NEW.created_at
           AND source.map_entry_id = lease.map_entry_id
           AND source.bucket_slot = 'development'
           AND source.delivery_tier = 'development'
           AND source.format = 'zip-stored-v1'
           AND source.state = 'live'
           AND source.object_key = lease.source_object_key
           AND source.byte_count = lease.source_byte_count
           AND source.sha256 = lease.source_sha256
    ) THEN RAISE(ABORT, 'promotion lease is not active') END;
END;
