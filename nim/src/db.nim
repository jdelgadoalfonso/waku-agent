## State database — port of `waku/db.py`.
##
## One SQLite file (`<home>/state.db`) holds everything Waku remembers.
## The schema is carried as individual statements (same tables, columns,
## defaults, FTS5 indexes and sync triggers as the Python `SCHEMA`), applied
## idempotently: every statement uses `IF NOT EXISTS`, and `_migrate` adds
## columns to databases created before they existed.
##
## One deliberate deviation: `connect` creates `home` when missing. Python's
## `connect` does not (callers run `ensure_home` first); a Nim binary invoked
## anywhere should not fail on a missing directory.

import std/os

import db_connector/db_sqlite

const schemaStmts* = [
  """
  CREATE TABLE IF NOT EXISTS calendar_events (
      id INTEGER PRIMARY KEY,
      title TEXT NOT NULL,
      start TEXT NOT NULL,
      "end" TEXT,
      attendees TEXT DEFAULT '',
      notes TEXT DEFAULT '',
      created_at TEXT DEFAULT (datetime('now'))
  )""",
  """
  CREATE TABLE IF NOT EXISTS facts (
      id INTEGER PRIMARY KEY,
      subject TEXT NOT NULL,
      content TEXT NOT NULL,
      source TEXT DEFAULT 'user',
      created_at TEXT DEFAULT (datetime('now')),
      -- Spec 006: 0 while a kept fact still has to reach Waku Memory, and the
      -- scope it goes to there. Every other fact is 1: nothing to send.
      synced INTEGER DEFAULT 1,
      scope TEXT DEFAULT 'global'
  )""",
  """
  CREATE VIRTUAL TABLE IF NOT EXISTS facts_fts USING fts5(
      subject, content, content=facts, content_rowid=id
  )""",
  """
  CREATE TRIGGER IF NOT EXISTS facts_ai AFTER INSERT ON facts BEGIN
      INSERT INTO facts_fts(rowid, subject, content) VALUES (new.id, new.subject, new.content);
  END""",
  """
  CREATE TRIGGER IF NOT EXISTS facts_ad AFTER DELETE ON facts BEGIN
      INSERT INTO facts_fts(facts_fts, rowid, subject, content) VALUES ('delete', old.id, old.subject, old.content);
  END""",
  """
  CREATE TRIGGER IF NOT EXISTS facts_au AFTER UPDATE ON facts BEGIN
      INSERT INTO facts_fts(facts_fts, rowid, subject, content) VALUES ('delete', old.id, old.subject, old.content);
      INSERT INTO facts_fts(rowid, subject, content) VALUES (new.id, new.subject, new.content);
  END""",
  """
  CREATE TABLE IF NOT EXISTS episodes (
      id INTEGER PRIMARY KEY,
      happened_at TEXT NOT NULL,
      summary TEXT NOT NULL,
      created_at TEXT DEFAULT (datetime('now'))
  )""",
  """
  CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts USING fts5(
      summary, content=episodes, content_rowid=id
  )""",
  """
  CREATE TRIGGER IF NOT EXISTS episodes_ai AFTER INSERT ON episodes BEGIN
      INSERT INTO episodes_fts(rowid, summary) VALUES (new.id, new.summary);
  END""",
  """
  CREATE TRIGGER IF NOT EXISTS episodes_ad AFTER DELETE ON episodes BEGIN
      INSERT INTO episodes_fts(episodes_fts, rowid, summary) VALUES ('delete', old.id, old.summary);
  END""",
  """
  CREATE TABLE IF NOT EXISTS scheduled_tasks (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      prompt TEXT NOT NULL,
      agent TEXT DEFAULT 'brief',
      interval_sec INTEGER NOT NULL,
      next_run INTEGER NOT NULL,
      claimed_at INTEGER DEFAULT 0,
      claimed_by TEXT DEFAULT '',
      created_at TEXT DEFAULT (datetime('now'))
  )""",
  """
  CREATE TABLE IF NOT EXISTS chat_log (
      id INTEGER PRIMARY KEY,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      consolidated INTEGER DEFAULT 0,
      session_id TEXT DEFAULT 'default',
      created_at TEXT DEFAULT (datetime('now'))
  )""",
]

proc chatLogColumns*(db: DbConn): seq[string] =
  ## Column names of `chat_log` (for `_migrate` and tests).
  for row in db.getAllRows(sql"PRAGMA table_info(chat_log)"):
    result.add(row[1])

proc factColumns*(db: DbConn): seq[string] =
  ## Column names of `facts` (for `_migrate` and tests).
  for row in db.getAllRows(sql"PRAGMA table_info(facts)"):
    result.add(row[1])

proc scheduledTaskColumns*(db: DbConn): seq[string] =
  ## Column names of `scheduled_tasks` (for `_migrate` and tests).
  for row in db.getAllRows(sql"PRAGMA table_info(scheduled_tasks)"):
    result.add(row[1])

proc migrate*(db: DbConn) =
  ## Additive, idempotent column upgrades for databases created before a
  ## column existed. Port of `waku/db.py` `_migrate`.
  let cols = chatLogColumns(db)
  if "session_id" notin cols:
    db.exec(sql"ALTER TABLE chat_log ADD COLUMN session_id TEXT DEFAULT 'default'")
  if "source" notin cols:
    # which gateway a message came in through (cli / voice / telegram / dashboard)
    db.exec(sql"ALTER TABLE chat_log ADD COLUMN source TEXT DEFAULT 'cli'")
  if "meta" notin cols:
    # per-turn telemetry as JSON on the assistant row
    db.exec(sql"ALTER TABLE chat_log ADD COLUMN meta TEXT")
  let factCols = factColumns(db)
  if "synced" notin factCols:
    # Spec 006. Existing rows default to 1, so the backlog is not re-sent
    # to Waku Memory: the capture shim imports that from memory/<id>.md.
    db.exec(sql"ALTER TABLE facts ADD COLUMN synced INTEGER DEFAULT 1")
  if "scope" notin factCols:
    db.exec(sql"ALTER TABLE facts ADD COLUMN scope TEXT DEFAULT 'global'")
  let taskCols = scheduledTaskColumns(db)
  if "claimed_at" notin taskCols:
    # C2c: the atomic-claim stamp; 0 means free. Rows that predate the
    # claim come back free, so every old task still fires once.
    db.exec(sql"ALTER TABLE scheduled_tasks ADD COLUMN claimed_at INTEGER DEFAULT 0")
  if "claimed_by" notin taskCols:
    # C2c: which tick owner holds the claim; '' means free.
    db.exec(sql"ALTER TABLE scheduled_tasks ADD COLUMN claimed_by TEXT DEFAULT ''")

proc connectDb*(home: string): DbConn =
  ## Open (creating `home` when missing) `<home>/state.db`, wait up to 3s
  ## on locks, and apply the schema plus migrations. Port of `connect`.
  createDir(home)
  result = open(home / "state.db", "", "", "")
  result.exec(sql"PRAGMA busy_timeout=3000")
  for stmt in schemaStmts:
    result.exec(sql(stmt))
  result.migrate()

proc closeDbQuietly*(db: DbConn) =
  ## Close that never raises, for `finally:` blocks (`test_tls` bans
  ## `except` inside `finally` — the swallow shape). Nil-safe so a
  ## `connectDb` that raised before assignment still closes clean.
  if db.isNil:
    return
  try:
    db.close()
  except CatchableError:
    discard
