-- Migration number: 0004 adds the hello-bind status rail.

ALTER TABLE users ADD COLUMN status_key_hash TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN status_verified_at INTEGER;
ALTER TABLE launches ADD COLUMN bind_mode TEXT NOT NULL DEFAULT '';

UPDATE launches SET bind_mode = 'brief' WHERE socket_token_hash != '';
