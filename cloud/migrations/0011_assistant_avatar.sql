-- The assistant's avatar: a name (starts as Pat) and a color, synced with the profile.
INSERT OR IGNORE INTO profile_sections (id, content, updated_at) VALUES
  ('assistant_name', 'Pat', CAST(unixepoch('subsec')*1000 AS INTEGER)),
  ('assistant_color', 'blue', CAST(unixepoch('subsec')*1000 AS INTEGER));
