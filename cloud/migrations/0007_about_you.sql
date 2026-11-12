-- "About you": a user-owned profile in short sections, plus suggestions the assistant
-- learns in conversation. Suggestions never change the profile until the user accepts them.
CREATE TABLE profile_sections (
  id TEXT PRIMARY KEY,                 -- basics | work | people | routines | goals | context
  content TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL,
  updated_by TEXT                      -- device id, or 'migration'
);

CREATE TABLE profile_suggestions (
  id TEXT PRIMARY KEY,
  section TEXT NOT NULL,
  content TEXT NOT NULL,
  norm TEXT NOT NULL,                  -- lowercased, whitespace-collapsed content for de-duplication
  source TEXT NOT NULL,                -- 'conversation'
  source_ref TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','dismissed')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX profile_suggestions_status ON profile_suggestions (status, created_at);
CREATE INDEX profile_suggestions_norm ON profile_suggestions (norm);

CREATE TRIGGER cl_prof_i AFTER INSERT ON profile_sections BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('profile', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_prof_u AFTER UPDATE ON profile_sections BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('profile', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_psug_i AFTER INSERT ON profile_suggestions BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('profile_suggestion', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;
CREATE TRIGGER cl_psug_u AFTER UPDATE ON profile_suggestions BEGIN INSERT INTO change_log (entity, entity_id, created_at) VALUES ('profile_suggestion', new.id, CAST(unixepoch('subsec')*1000 AS INTEGER)); END;

INSERT INTO profile_sections (id, content, updated_at) VALUES
  ('basics', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('work', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('people', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('routines', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('goals', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('context', '', CAST(unixepoch('subsec')*1000 AS INTEGER));

-- Carry existing facts into "Anything else", one per line, oldest first, each distinct fact once.
UPDATE profile_sections
SET content = COALESCE((
      SELECT group_concat(c, char(10)) FROM (
        SELECT trim(content) AS c FROM memories
        WHERE kind = 'fact' AND deleted_at IS NULL AND trim(content) != ''
        GROUP BY lower(trim(content)) ORDER BY MIN(created_at)
      )
    ), ''),
    updated_by = 'migration'
WHERE id = 'context'
  AND EXISTS (SELECT 1 FROM memories WHERE kind = 'fact' AND deleted_at IS NULL);

-- The facts now live in the profile; retire the memory rows so they aren't shown or prompted twice.
UPDATE memories SET deleted_at = CAST(unixepoch('subsec')*1000 AS INTEGER), updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER)
WHERE kind = 'fact' AND deleted_at IS NULL;
