-- Scheduled tasks: instructions Orbit carries out on a schedule, delivering results in the chat.
CREATE TABLE schedules (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  instructions TEXT NOT NULL,
  repeat TEXT NOT NULL CHECK (repeat IN ('once','daily','weekdays','weekly','interval')),
  time_of_day TEXT,                 -- 'HH:MM' in the schedule's time zone (daily/weekdays/weekly)
  days TEXT,                        -- weekly: comma-separated weekdays, 0 = Sunday
  interval_hours INTEGER,           -- interval: every N hours
  run_at INTEGER,                   -- once: when (ms)
  timezone TEXT NOT NULL,           -- IANA zone, e.g. America/New_York
  respect_quiet_hours INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','done')),
  next_run_at INTEGER,
  last_run_at INTEGER,
  last_finished_at INTEGER,
  last_status TEXT,                 -- running | ok | needs_approval | failed | deferred
  last_result TEXT,
  last_message_id TEXT,
  run_count INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL,             -- 'user' (app) or 'conversation' (created in chat)
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE INDEX schedules_due ON schedules (status, next_run_at);

CREATE TRIGGER cl_sched_i AFTER INSERT ON schedules BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('schedule', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_sched_u AFTER UPDATE ON schedules BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('schedule', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;

-- Global quiet hours ('HH:MM-HH:MM' in each schedule's zone; empty = none), synced like the profile.
INSERT OR IGNORE INTO profile_sections (id, content, updated_at) VALUES ('quiet_hours', '', CAST(unixepoch('subsec')*1000 AS INTEGER));
