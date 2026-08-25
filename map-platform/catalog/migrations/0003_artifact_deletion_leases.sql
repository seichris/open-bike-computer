CREATE TABLE artifact_deletion_leases (
    id TEXT PRIMARY KEY,
    artifact_id TEXT NOT NULL UNIQUE REFERENCES artifacts(id) ON DELETE CASCADE,
    channel TEXT NOT NULL CHECK (channel IN ('development', 'production')),
    object_key TEXT NOT NULL,
    byte_count INTEGER NOT NULL CHECK (byte_count > 0),
    sha256 TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state = 'claimed'),
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);

CREATE INDEX artifact_deletion_leases_expiry_idx
    ON artifact_deletion_leases(expires_at, channel);
