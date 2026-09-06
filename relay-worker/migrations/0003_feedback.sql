CREATE TABLE feedback_submissions (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  message TEXT NOT NULL,
  contact TEXT,
  instance_id TEXT,
  mydia_version TEXT,
  source_ip TEXT,
  state TEXT NOT NULL DEFAULT 'unread',
  github_ref TEXT,
  inserted_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX feedback_state_inserted_idx
  ON feedback_submissions (state, inserted_at DESC);
