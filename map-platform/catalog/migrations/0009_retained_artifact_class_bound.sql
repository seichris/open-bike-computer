-- Migration 0008 originally counted only live selection heads. Retained
-- quarantined and tombstoned objects still occupy D1 and R2, so refuse to
-- enable the stronger invariant over an already-unbounded database.
CREATE TABLE migration_0009_retained_class_bound_guard (
    valid INTEGER NOT NULL CHECK (valid = 1)
);
INSERT INTO migration_0009_retained_class_bound_guard(valid)
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM artifacts
     WHERE state <> 'deleted'
     GROUP BY map_entry_id
    HAVING COUNT(DISTINCT generation_class) > 16
) THEN 0 ELSE 1 END;
DROP TABLE migration_0009_retained_class_bound_guard;

DROP TRIGGER IF EXISTS artifacts_live_generation_class_limit;
DROP TRIGGER IF EXISTS artifacts_retained_generation_class_limit;

-- Every retained class consumes capacity. A lease claim deliberately does not
-- free a slot; only confirmation changing the final class row to deleted does.
CREATE TRIGGER artifacts_retained_generation_class_limit
BEFORE INSERT ON artifacts
WHEN NEW.state <> 'deleted'
 AND NOT EXISTS (
        SELECT 1 FROM artifacts existing
         WHERE existing.map_entry_id = NEW.map_entry_id
           AND existing.generation_class = NEW.generation_class
           AND existing.state <> 'deleted'
     )
 AND (
        SELECT COUNT(DISTINCT existing.generation_class)
          FROM artifacts existing
         WHERE existing.map_entry_id = NEW.map_entry_id
           AND existing.state <> 'deleted'
     ) >= 16
BEGIN
    SELECT RAISE(ABORT, 'artifact generation class limit');
END;

-- Keep the invariant authoritative even for maintenance or future code that
-- revives a deleted row, moves it between maps, or changes its class in place.
CREATE TRIGGER artifacts_retained_generation_class_update_limit
BEFORE UPDATE OF state, map_entry_id, generation_class ON artifacts
WHEN NEW.state <> 'deleted'
 AND (
        OLD.state = 'deleted'
        OR OLD.map_entry_id IS NOT NEW.map_entry_id
        OR OLD.generation_class IS NOT NEW.generation_class
     )
 AND NOT EXISTS (
        SELECT 1 FROM artifacts existing
         WHERE existing.id <> OLD.id
           AND existing.map_entry_id = NEW.map_entry_id
           AND existing.generation_class = NEW.generation_class
           AND existing.state <> 'deleted'
     )
 AND (
        SELECT COUNT(DISTINCT existing.generation_class)
          FROM artifacts existing
         WHERE existing.id <> OLD.id
           AND existing.map_entry_id = NEW.map_entry_id
           AND existing.state <> 'deleted'
     ) >= 16
BEGIN
    SELECT RAISE(ABORT, 'artifact generation class limit');
END;
