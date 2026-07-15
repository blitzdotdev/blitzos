-- Migration number: 0003 adds Layer 2 launch session state.

ALTER TABLE launches ADD COLUMN state TEXT NOT NULL DEFAULT 'launched';
ALTER TABLE launches ADD COLUMN socket_token_hash TEXT NOT NULL DEFAULT '';
ALTER TABLE launches ADD COLUMN session_url TEXT NOT NULL DEFAULT '';
ALTER TABLE launches ADD COLUMN last_event_at INTEGER;
ALTER TABLE launches ADD COLUMN last_status_text TEXT NOT NULL DEFAULT '';
ALTER TABLE launches ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;

CREATE TABLE launch_events (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	launch_id TEXT NOT NULL,
	ts INTEGER NOT NULL,
	kind TEXT NOT NULL,
	payload TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_launch_events_launch_id ON launch_events (launch_id);
