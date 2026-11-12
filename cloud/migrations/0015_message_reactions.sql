-- Reactions update message metadata and must sync to every paired device.
CREATE TRIGGER cl_msg_meta_u AFTER UPDATE OF meta ON messages BEGIN
  INSERT INTO change_log (entity,entity_id,created_at) VALUES ('message',new.id,CAST(unixepoch('subsec')*1000 AS INTEGER));
END;
