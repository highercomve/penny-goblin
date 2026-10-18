BEGIN IMMEDIATE;
CREATE TABLE statements (
 hash TEXT PRIMARY KEY CHECK(length(hash)=64),
 name TEXT NOT NULL, data_url TEXT NOT NULL,
 parser TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'queued'
);
CREATE TABLE observations (
 id TEXT PRIMARY KEY CHECK(length(id)=64),
 statement_hash TEXT NOT NULL REFERENCES statements(hash),
 position INTEGER NOT NULL,
 source_json TEXT NOT NULL,
 expense_id TEXT REFERENCES expenses(id),
 ignored INTEGER NOT NULL DEFAULT 0 CHECK(ignored IN (0,1)),
 UNIQUE(statement_hash,position)
);
CREATE INDEX observations_expense ON observations(expense_id);
PRAGMA user_version=2;
COMMIT;
