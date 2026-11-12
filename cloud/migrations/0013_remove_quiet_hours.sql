-- Retire quiet hours without changing existing task instructions or paused tasks.
-- Keep the legacy column/row for compatibility with cached data on older builds.
UPDATE profile_sections SET content = '', updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER) WHERE id = 'quiet_hours';
UPDATE schedules SET respect_quiet_hours = 0,
  next_run_at = CASE WHEN status = 'active' AND deleted_at IS NULL AND
    (last_status = 'deferred' OR (repeat = 'once' AND run_at <= CAST(unixepoch('subsec')*1000 AS INTEGER)))
    THEN CAST(unixepoch('subsec')*1000 AS INTEGER) ELSE next_run_at END,
  last_status = CASE WHEN last_status = 'deferred' THEN NULL ELSE last_status END,
  updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER);
