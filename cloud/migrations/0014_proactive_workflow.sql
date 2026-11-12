ALTER TABLE schedules ADD COLUMN origin_reason TEXT;
ALTER TABLE schedules ADD COLUMN dedupe_key TEXT;
CREATE UNIQUE INDEX schedules_dedupe ON schedules(dedupe_key) WHERE dedupe_key IS NOT NULL;
