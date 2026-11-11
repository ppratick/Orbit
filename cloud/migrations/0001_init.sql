-- Orbit core schema. D1 (SQLite) is the source of truth for every device.
-- All timestamps are integer milliseconds since the Unix epoch (UTC).

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('mac','iphone','cli')),
  token_hash TEXT NOT NULL UNIQUE,
  capabilities TEXT NOT NULL DEFAULT '[]',     -- JSON array of capability strings
  push_token TEXT,
  push_env TEXT,                                -- 'sandbox' | 'production'
  last_seen_at INTEGER,
  created_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE TABLE pairing_codes (
  code_hash TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL,
  used_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT 'New conversation',
  archived INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user','assistant','tool_call','tool_result','system')),
  content TEXT NOT NULL DEFAULT '',
  meta TEXT,                                    -- JSON: tool name, call id, arguments, etc.
  device_id TEXT,
  client_msg_id TEXT UNIQUE,                    -- idempotency for client retries
  reply_to TEXT,                                -- assistant replies point at the user message
  created_at INTEGER NOT NULL
);
CREATE INDEX messages_conv ON messages(conversation_id, created_at);

CREATE VIRTUAL TABLE messages_fts USING fts5(content, content='messages', content_rowid='rowid');
CREATE TRIGGER messages_ai AFTER INSERT ON messages WHEN new.role IN ('user','assistant') BEGIN
  INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content);
END;
CREATE TRIGGER messages_ad AFTER DELETE ON messages WHEN old.role IN ('user','assistant') BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
END;

CREATE TABLE memories (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('preference','fact')),
  content TEXT NOT NULL,
  source TEXT NOT NULL,                         -- 'user', 'conversation', 'email', 'heartbeat', ...
  source_ref TEXT,                              -- e.g. message id / email id
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);

CREATE TABLE responsibilities (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'custom',          -- deadline|followup|delivery|return|refund|renewal|research|custom
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','waiting','done','cancelled')),
  notes TEXT NOT NULL DEFAULT '',
  due_at INTEGER,
  next_check_at INTEGER,
  check_interval_min INTEGER,
  data TEXT NOT NULL DEFAULT '{}',
  source TEXT NOT NULL,
  source_ref TEXT,
  dedupe_key TEXT UNIQUE,                       -- prevents heartbeat re-creating the same item
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX responsibilities_check ON responsibilities(status, next_check_at);

CREATE TABLE approvals (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL UNIQUE,
  action TEXT NOT NULL,
  summary TEXT NOT NULL,
  params_hash TEXT NOT NULL,                    -- approval binds to the exact parameters
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','denied','expired')),
  decided_by_device TEXT,
  decided_at INTEGER,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX approvals_status ON approvals(status);

CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  action TEXT NOT NULL,
  target TEXT NOT NULL CHECK (target IN ('cloud','mac','iphone','apple')),  -- apple = any Apple device
  status TEXT NOT NULL CHECK (status IN ('awaiting_approval','queued','leased','succeeded','failed','cancelled','denied')),
  summary TEXT NOT NULL,
  params TEXT NOT NULL,
  params_hash TEXT NOT NULL,
  result TEXT,
  error TEXT,
  idempotency_key TEXT NOT NULL UNIQUE,
  approval_id TEXT,
  conversation_id TEXT,
  responsibility_id TEXT,
  lease_device_id TEXT,
  lease_token TEXT,
  lease_expires_at INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 3,
  not_before INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  completed_at INTEGER
);
CREATE INDEX tasks_queue ON tasks(status, target, not_before);

CREATE TABLE activity (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  summary TEXT NOT NULL,
  data TEXT NOT NULL DEFAULT '{}',
  task_id TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX activity_time ON activity(created_at);

CREATE TABLE notifications (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  category TEXT NOT NULL,                       -- approval|task_done|task_failed|briefing|deadline|email|system
  ref_type TEXT,
  ref_id TEXT,
  dedupe_key TEXT UNIQUE,
  push_status TEXT NOT NULL DEFAULT 'pending',  -- pending|sent|skipped|failed
  push_error TEXT,
  read_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX notifications_time ON notifications(created_at);

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,                       -- google|icloud_mail|github|slack|canvas
  label TEXT NOT NULL,
  identity TEXT,                                -- e-mail address / username (not a secret)
  scopes TEXT,
  secret_ct TEXT NOT NULL,                      -- AES-GCM ciphertext; never sent to the model or clients
  config TEXT NOT NULL DEFAULT '{}',            -- non-secret settings, e.g. Canvas base URL
  status TEXT NOT NULL DEFAULT 'active',        -- active|error|disabled
  last_error TEXT,
  sync_state TEXT NOT NULL DEFAULT '{}',
  last_sync_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(provider, identity)
);

CREATE TABLE email_items (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  provider_msg_id TEXT NOT NULL,
  thread_id TEXT,
  from_addr TEXT,
  subject TEXT,
  snippet TEXT,
  received_at INTEGER,
  triage TEXT,                                  -- JSON classification from the heartbeat
  created_at INTEGER NOT NULL,
  UNIQUE(account_id, provider_msg_id)
);

CREATE TABLE oauth_states (
  state TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  label TEXT,
  expires_at INTEGER NOT NULL
);

CREATE TABLE heartbeat_runs (
  id TEXT PRIMARY KEY,
  started_at INTEGER NOT NULL,
  finished_at INTEGER,
  status TEXT NOT NULL DEFAULT 'running',
  summary TEXT
);

-- Monotonic change feed used for device sync.
CREATE TABLE change_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  entity TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX change_log_entity ON change_log(entity, entity_id);

CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
