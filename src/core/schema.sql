PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
PRAGMA synchronous = FULL;
PRAGMA journal_mode = WAL;
BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS expenses (
  id TEXT PRIMARY KEY CHECK(length(id) = 64),
  revision INTEGER NOT NULL CHECK(revision > 0),
  date TEXT NOT NULL,
  amount INTEGER NOT NULL CHECK(amount > 0 AND amount <= 1000000000000),
  currency TEXT NOT NULL CHECK(currency = 'CLP'),
  payee TEXT NOT NULL, account TEXT NOT NULL, category TEXT NOT NULL,
  notes TEXT NOT NULL, reference TEXT NOT NULL, location TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0, 1))
);
CREATE INDEX IF NOT EXISTS expenses_date ON expenses(date, id);
CREATE TABLE IF NOT EXISTS documents (
  hash TEXT PRIMARY KEY,
  data_url TEXT NOT NULL,
  extraction TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS evidence (
  document_hash TEXT PRIMARY KEY REFERENCES documents(hash),
  expense_id TEXT NOT NULL REFERENCES expenses(id)
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS changes (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  expense_id TEXT NOT NULL REFERENCES expenses(id),
  revision INTEGER NOT NULL,
  UNIQUE(expense_id, revision)
);
PRAGMA user_version = 1;
COMMIT;
