-- LangMem Postgres twin for Waku's semantic memory (your own database).
-- The in-process default needs no setup at all; run this only for the
-- persisted twin (`WAKU_SEMANTIC_STORE=langmem` + `WAKU_LANGMEM_POSTGRES`).
--
-- One row per (prefix, key): the namespace joined with the unit separator
-- (`waku<0x1f>facts`), the value as JSONB, the vector beside it. Shape of the
-- reference implementation, under the port's own table name — the port does
-- NOT read databases written by langgraph's historical PostgresStore, whose
-- migrations this repo never ran (see odd/tasks/nim-langmem-store.md L5).
--
-- Run once on a FRESH database:
--   createdb waku
--   psql waku < sql/init_langmem.sql
--
-- Then point the port at it:
--   export WAKU_SEMANTIC_STORE=langmem
--   export WAKU_LANGMEM_POSTGRES=postgres://user:pass@localhost:5432/waku
--   export OPENAI_API_KEY=sk-...
--
-- created_at/updated_at are ISO-UTC TEXT (not timestamptz), exactly as the
-- reference stores them: fixed-width, so ORDER BY created_at DESC reads
-- newest-first. The embedding width is OpenAI text-embedding-3-small (1536).

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS langmem_store (
    prefix TEXT NOT NULL,
    key TEXT NOT NULL,
    value JSONB NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    embedding VECTOR(1536),
    PRIMARY KEY (prefix, key)
);

-- Native vector search: HNSW over cosine, like the reference. Prefix scans
-- and key lookups read the primary key; no further indexes needed.
CREATE INDEX IF NOT EXISTS langmem_store_embedding_hnsw
    ON langmem_store USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
