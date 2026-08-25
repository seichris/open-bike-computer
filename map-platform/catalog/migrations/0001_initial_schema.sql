PRAGMA foreign_keys = ON;

CREATE TABLE libraries (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    revoked_at TEXT,
    schema_version INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE library_credentials (
    credential_hash TEXT PRIMARY KEY,
    library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    last_used_at TEXT NOT NULL,
    revoked_at TEXT
);
CREATE INDEX library_credentials_library_idx
    ON library_credentials(library_id, revoked_at);

CREATE TABLE map_entries (
    id TEXT PRIMARY KEY,
    legacy_map_id TEXT NOT NULL,
    content_receipt TEXT NOT NULL,
    origin_channel TEXT NOT NULL CHECK (origin_channel IN ('development', 'production')),
    canonical_name TEXT NOT NULL,
    source_region_name TEXT,
    bounds_json TEXT,
    renderer TEXT NOT NULL,
    renderer_format_version INTEGER NOT NULL,
    features_json TEXT NOT NULL,
    attribution_json TEXT NOT NULL,
    generated_at TEXT,
    delivery_state TEXT NOT NULL CHECK (delivery_state IN ('development', 'promotion_pending', 'production', 'blocked', 'tombstoned')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX map_entries_delivery_idx
    ON map_entries(delivery_state, updated_at);

CREATE TABLE artifacts (
    id TEXT PRIMARY KEY,
    map_entry_id TEXT NOT NULL REFERENCES map_entries(id) ON DELETE RESTRICT,
    bucket_slot TEXT NOT NULL CHECK (bucket_slot IN ('development', 'production')),
    object_key TEXT NOT NULL,
    format TEXT NOT NULL,
    media_type TEXT NOT NULL,
    filename TEXT NOT NULL,
    byte_count INTEGER NOT NULL CHECK (byte_count > 0),
    sha256 TEXT NOT NULL,
    manifest_receipt TEXT,
    signed_manifest_receipt TEXT,
    signature_key_id TEXT,
    signature_key_sha256 TEXT,
    producer_build_sha256 TEXT,
    producer_image_digest TEXT,
    required_ios_build TEXT,
    required_ios_git_sha TEXT,
    required_ios_build_sha256 TEXT,
    required_firmware_version TEXT,
    required_firmware_build INTEGER,
    required_firmware_git_sha TEXT,
    delivery_tier TEXT NOT NULL CHECK (delivery_tier IN ('development', 'production')),
    state TEXT NOT NULL DEFAULT 'live' CHECK (state IN ('live', 'quarantined', 'tombstoned', 'deleted')),
    created_at TEXT NOT NULL,
    verified_at TEXT NOT NULL,
    UNIQUE(bucket_slot, object_key)
);
CREATE INDEX artifacts_selection_idx
    ON artifacts(map_entry_id, format, delivery_tier, state, created_at);

CREATE TABLE library_maps (
    library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    map_entry_id TEXT NOT NULL REFERENCES map_entries(id) ON DELETE RESTRICT,
    alias TEXT NOT NULL,
    alias_source TEXT NOT NULL CHECK (alias_source IN ('generated', 'creator', 'share', 'user')),
    alias_revision INTEGER NOT NULL DEFAULT 1,
    added_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    source_share_id TEXT,
    PRIMARY KEY(library_id, map_entry_id)
);
CREATE INDEX library_maps_list_idx
    ON library_maps(library_id, updated_at DESC, map_entry_id);

CREATE TABLE shares (
    id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    owner_library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    map_entry_id TEXT NOT NULL REFERENCES map_entries(id) ON DELETE RESTRICT,
    title_snapshot TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT,
    revoked_at TEXT,
    claim_count INTEGER NOT NULL DEFAULT 0 CHECK (claim_count >= 0)
);
CREATE INDEX shares_owner_idx
    ON shares(owner_library_id, created_at DESC);
CREATE INDEX shares_resolve_idx
    ON shares(token_hash, revoked_at, expires_at);

CREATE TABLE share_claims (
    share_id TEXT NOT NULL REFERENCES shares(id) ON DELETE CASCADE,
    recipient_library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    claimed_at TEXT NOT NULL,
    PRIMARY KEY(share_id, recipient_library_id)
);

CREATE TABLE publication_events (
    idempotency_key TEXT PRIMARY KEY,
    publication_id TEXT NOT NULL UNIQUE,
    map_entry_id TEXT NOT NULL REFERENCES map_entries(id) ON DELETE RESTRICT,
    channel TEXT NOT NULL CHECK (channel IN ('development', 'production')),
    body_sha256 TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('finalized', 'quarantined')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX publication_events_map_idx
    ON publication_events(map_entry_id, state);

CREATE TABLE download_grants (
    token_hash TEXT PRIMARY KEY,
    library_id TEXT REFERENCES libraries(id) ON DELETE CASCADE,
    artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
    purpose TEXT NOT NULL CHECK (purpose IN ('library', 'promotion')),
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);
CREATE INDEX download_grants_expiry_idx ON download_grants(expires_at);

CREATE TABLE linked_library_codes (
    code_hash TEXT PRIMARY KEY,
    source_library_id TEXT NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    claimed_at TEXT
);
