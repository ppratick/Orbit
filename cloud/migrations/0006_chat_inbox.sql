-- Serialize work per conversation while accepting new messages immediately.
CREATE TABLE chat_leases (
  conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
  owner_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE TABLE chat_inbox (
  message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','queued','running','steering','done')),
  turn_id TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX chat_inbox_pending ON chat_inbox(conversation_id, state, created_at);
