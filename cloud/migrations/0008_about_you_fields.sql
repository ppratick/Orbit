-- About you becomes one page of short fields: Name, Time zone, School and Work,
-- plus longer notes. The old free-text "basics" section is folded into "Anything else".
INSERT OR IGNORE INTO profile_sections (id, content, updated_at) VALUES
  ('name', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('timezone', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('school', '', CAST(unixepoch('subsec')*1000 AS INTEGER));

UPDATE profile_sections
SET content = CASE WHEN content = '' THEN (SELECT content FROM profile_sections WHERE id = 'basics')
                   ELSE (SELECT content FROM profile_sections WHERE id = 'basics') || char(10) || content END,
    updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER), updated_by = 'migration'
WHERE id = 'context' AND (SELECT content FROM profile_sections WHERE id = 'basics') != '';

UPDATE profile_sections SET content = '', updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER)
WHERE id = 'basics' AND content != '';

UPDATE profile_suggestions SET section = 'context' WHERE section = 'basics';
