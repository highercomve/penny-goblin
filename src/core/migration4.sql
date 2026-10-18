BEGIN IMMEDIATE;
CREATE TABLE sync_resolutions(
 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
 kind TEXT NOT NULL,id TEXT NOT NULL,
 local_payload TEXT NOT NULL,remote_payload TEXT NOT NULL,
 choice TEXT NOT NULL,created_at INTEGER NOT NULL DEFAULT(unixepoch())
);
ALTER TABLE sync_client ADD COLUMN last_success INTEGER NOT NULL DEFAULT 0;
PRAGMA user_version=4;
COMMIT;
