-- USD payments beside CLP: the currency CHECK becomes a list. SQLite can't
-- change a CHECK in place, so the table is rebuilt (its index and sync
-- triggers with it); evidence, changes and observations keep referring to it
-- by name. Foreign keys are off for the swap, as SQLite's rebuild recipe asks.
PRAGMA foreign_keys=OFF;
BEGIN IMMEDIATE;
CREATE TABLE expenses_v5 (
  id TEXT PRIMARY KEY CHECK(length(id) = 64),
  revision INTEGER NOT NULL CHECK(revision > 0),
  date TEXT NOT NULL,
  amount INTEGER NOT NULL CHECK(amount > 0 AND amount <= 1000000000000),
  currency TEXT NOT NULL CHECK(currency IN ('CLP', 'USD')),
  payee TEXT NOT NULL, account TEXT NOT NULL, category TEXT NOT NULL,
  notes TEXT NOT NULL, reference TEXT NOT NULL, location TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0, 1))
);
INSERT INTO expenses_v5(id,revision,date,amount,currency,payee,account,category,notes,reference,location,deleted)
  SELECT id,revision,date,amount,currency,payee,account,category,notes,reference,location,deleted FROM expenses;
DROP TABLE expenses;
ALTER TABLE expenses_v5 RENAME TO expenses;
CREATE INDEX expenses_date ON expenses(date, id);
CREATE TRIGGER sync_expense_insert AFTER INSERT ON expenses WHEN (SELECT suppress FROM sync_context)=0 BEGIN INSERT INTO sync_pending VALUES('expense',NEW.id) ON CONFLICT(kind,id) DO NOTHING; END;
CREATE TRIGGER sync_expense_update AFTER UPDATE ON expenses WHEN (SELECT suppress FROM sync_context)=0 BEGIN INSERT INTO sync_pending VALUES('expense',NEW.id) ON CONFLICT(kind,id) DO NOTHING; END;
PRAGMA user_version=5;
COMMIT;
PRAGMA foreign_keys=ON;
