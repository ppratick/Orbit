-- File references disappear on other devices when their conversation is removed.
CREATE TRIGGER cl_msg_d AFTER DELETE ON messages BEGIN
  INSERT INTO change_log (entity,entity_id,created_at) VALUES ('message',old.id,CAST(unixepoch('subsec')*1000 AS INTEGER));
END;
-- Repair cached ghosts from deletions made before message tombstones existed.
INSERT INTO change_log (entity,entity_id,created_at)
SELECT DISTINCT 'message', c.entity_id, CAST(unixepoch('subsec')*1000 AS INTEGER)
FROM change_log c LEFT JOIN messages m ON m.id=c.entity_id
WHERE c.entity='message' AND m.id IS NULL;
