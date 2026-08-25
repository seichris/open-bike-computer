DROP INDEX IF EXISTS linked_library_codes_claim_credential_idx;

DROP INDEX IF EXISTS shares_owner_idx;
CREATE INDEX shares_owner_pagination_idx
    ON shares(owner_library_id, created_at DESC, id ASC);
