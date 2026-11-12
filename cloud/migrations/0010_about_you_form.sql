-- About you as a form: first/last/preferred name, major, and Work as a choice
-- (Student, Part-time, Full-time). Routines and wake/bed times are removed. Anything already
-- written in a retired field moves into "Anything else", labeled, so nothing is lost.
INSERT OR IGNORE INTO profile_sections (id, content, updated_at) VALUES
  ('first_name', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('last_name', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('nickname', '', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('major', '', CAST(unixepoch('subsec')*1000 AS INTEGER));

-- The old single "Name" was what Orbit called you.
UPDATE profile_sections SET content = (SELECT content FROM profile_sections WHERE id = 'name'),
  updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER), updated_by = 'migration'
WHERE id = 'nickname' AND content = '' AND (SELECT content FROM profile_sections WHERE id = 'name') != '';

-- Collect retired text, labeled, into "Anything else".
UPDATE profile_sections
SET content = CASE WHEN content = '' THEN (SELECT group_concat(line, char(10)) FROM (
    SELECT 'Wakes up: ' || content AS line FROM profile_sections WHERE id = 'wake' AND content != ''
    UNION ALL SELECT 'Bedtime: ' || content FROM profile_sections WHERE id = 'bedtime' AND content != ''
    UNION ALL SELECT 'Routines: ' || content FROM profile_sections WHERE id = 'routines' AND content != ''
    UNION ALL SELECT 'Work: ' || content FROM profile_sections
      WHERE id = 'work' AND content != '' AND content NOT IN ('Student', 'Part-time', 'Full-time'))) ELSE content || char(10) || (SELECT group_concat(line, char(10)) FROM (
    SELECT 'Wakes up: ' || content AS line FROM profile_sections WHERE id = 'wake' AND content != ''
    UNION ALL SELECT 'Bedtime: ' || content FROM profile_sections WHERE id = 'bedtime' AND content != ''
    UNION ALL SELECT 'Routines: ' || content FROM profile_sections WHERE id = 'routines' AND content != ''
    UNION ALL SELECT 'Work: ' || content FROM profile_sections
      WHERE id = 'work' AND content != '' AND content NOT IN ('Student', 'Part-time', 'Full-time'))) END,
    updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER), updated_by = 'migration'
WHERE id = 'context' AND (SELECT group_concat(line, char(10)) FROM (
    SELECT 'Wakes up: ' || content AS line FROM profile_sections WHERE id = 'wake' AND content != ''
    UNION ALL SELECT 'Bedtime: ' || content FROM profile_sections WHERE id = 'bedtime' AND content != ''
    UNION ALL SELECT 'Routines: ' || content FROM profile_sections WHERE id = 'routines' AND content != ''
    UNION ALL SELECT 'Work: ' || content FROM profile_sections
      WHERE id = 'work' AND content != '' AND content NOT IN ('Student', 'Part-time', 'Full-time'))) IS NOT NULL;

UPDATE profile_sections SET content = '', updated_at = CAST(unixepoch('subsec')*1000 AS INTEGER)
WHERE content != '' AND (id IN ('name', 'wake', 'bedtime', 'routines')
  OR (id = 'work' AND content NOT IN ('Student', 'Part-time', 'Full-time')));

UPDATE profile_suggestions SET section = 'nickname' WHERE section = 'name';
UPDATE profile_suggestions SET section = 'context' WHERE section IN ('wake', 'bedtime', 'routines', 'work');
