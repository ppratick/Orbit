-- Preserve existing history in one conversation; retain original conversation rows as archives.
INSERT INTO conversations (id, title, created_at, updated_at)
VALUES ('conv_orbit_primary', 'Orbit',
  COALESCE((SELECT MIN(created_at) FROM conversations), CAST(unixepoch('subsec')*1000 AS INTEGER)),
  COALESCE((SELECT MAX(updated_at) FROM conversations), CAST(unixepoch('subsec')*1000 AS INTEGER)))
ON CONFLICT(id) DO NOTHING;

-- Existing clients must receive relocated messages through incremental sync.
CREATE TRIGGER cl_msg_u AFTER UPDATE OF conversation_id ON messages BEGIN
  INSERT INTO change_log (entity, entity_id, created_at)
  VALUES ('message', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER));
END;
UPDATE messages SET conversation_id = 'conv_orbit_primary'
WHERE conversation_id != 'conv_orbit_primary';
UPDATE tasks SET conversation_id = 'conv_orbit_primary'
WHERE conversation_id IS NOT NULL AND conversation_id != 'conv_orbit_primary';
UPDATE memories SET source_ref = 'conv_orbit_primary'
WHERE source = 'conversation' AND source_ref IN (SELECT id FROM conversations WHERE id != 'conv_orbit_primary');
UPDATE responsibilities SET source_ref = 'conv_orbit_primary'
WHERE source = 'conversation' AND source_ref IN (SELECT id FROM conversations WHERE id != 'conv_orbit_primary');
UPDATE notifications SET ref_id = 'conv_orbit_primary'
WHERE ref_type = 'conversation' AND ref_id != 'conv_orbit_primary';
UPDATE conversations SET archived = 1 WHERE id != 'conv_orbit_primary' AND archived = 0;
