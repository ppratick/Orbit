-- Record every relevant change in change_log via triggers, so sync can never miss a write
-- and handlers spend no extra D1 queries (Workers Free: 50 queries per invocation).
CREATE TRIGGER cl_conv_i AFTER INSERT ON conversations BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('conversation', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_conv_u AFTER UPDATE ON conversations BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('conversation', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_conv_d AFTER DELETE ON conversations BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('conversation', old.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_msg_i AFTER INSERT ON messages BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('message', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_task_i AFTER INSERT ON tasks BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('task', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_task_u AFTER UPDATE OF status, result, error, lease_device_id ON tasks BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('task', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_apr_i AFTER INSERT ON approvals BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('approval', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_apr_u AFTER UPDATE ON approvals BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('approval', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_mem_i AFTER INSERT ON memories BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('memory', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_mem_u AFTER UPDATE ON memories BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('memory', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_resp_i AFTER INSERT ON responsibilities BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('responsibility', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_resp_u AFTER UPDATE ON responsibilities BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('responsibility', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_ntf_i AFTER INSERT ON notifications BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('notification', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_ntf_u AFTER UPDATE OF read_at ON notifications BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('notification', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_act_i AFTER INSERT ON activity BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('activity', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_acct_i AFTER INSERT ON accounts BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('account', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_acct_u AFTER UPDATE OF label, status, last_error, scopes, config ON accounts BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('account', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_dev_i AFTER INSERT ON devices BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('device', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_dev_u AFTER UPDATE OF name, capabilities, push_token, revoked_at ON devices BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('device', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;

-- Latest calendar/reminder snapshot each Apple device uploads (cloud has no Apple Reminders API).
CREATE TABLE device_context (
  device_id TEXT NOT NULL,
  kind TEXT NOT NULL,           -- 'calendar' | 'reminders'
  payload TEXT NOT NULL,        -- JSON
  captured_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, kind)
);
