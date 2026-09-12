-- Keyset scans exclude production, blocked and tombstoned maps.
CREATE INDEX map_entries_auto_promotion_idx ON map_entries(id)
WHERE origin_channel = 'development'
  AND delivery_state IN ('development', 'promotion_pending');
