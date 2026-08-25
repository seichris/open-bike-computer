CREATE INDEX library_maps_map_entry_idx
    ON library_maps(map_entry_id, library_id);

CREATE INDEX shares_map_entry_idx
    ON shares(map_entry_id, id);

CREATE INDEX share_claims_recipient_idx
    ON share_claims(recipient_library_id, share_id);

CREATE INDEX linked_library_codes_source_state_idx
    ON linked_library_codes(source_library_id, claimed_at, expires_at, code_hash);
