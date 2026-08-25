ALTER TABLE linked_library_codes
    ADD COLUMN claim_credential_hash TEXT;

CREATE UNIQUE INDEX linked_library_codes_claim_credential_idx
    ON linked_library_codes(claim_credential_hash)
    WHERE claim_credential_hash IS NOT NULL;
