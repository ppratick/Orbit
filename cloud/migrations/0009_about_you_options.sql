-- About you: add Year and wake/bed times (picked from options); remove Important people,
-- folding anything written there into "Anything else" so nothing is lost.
INSERT OR IGNORE INTO profile_sections (id, content, updated_at) VALUES
  ('year', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('wake', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('bedtime', '', CAST(unixepoch('subsec')*1000 AS INTEGER));

UPDATE profile_sections
SET content = CASE WHEN content = '' THEN (SELECT content FROM profile_sections WHERE id = 'people')
                   ELSE content || char(10) || (SELECT content FROM profile_sections WHERE id = 'people') END,
    updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER), updated_by = 'migration'
WHERE id = 'context' AND (SELECT content FROM profile_sections WHERE id = 'people') != '';

UPDATE profile_sections SET content = '', updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER)
WHERE id = 'people' AND content != '';

UPDATE profile_suggestions SET section = 'context' WHERE section = 'people';
