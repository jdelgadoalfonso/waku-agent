-- Postgres + pgvector setup for Waku's semantic memory (any Postgres, not
-- just Supabase). Slim on purpose: extension + table + indexes only.
--
-- What this deliberately LEAVES OUT from sql/init_supabase.sql:
--   * the `match_chunks` RPC — the Nim port emits
--     `ORDER BY embedding <=> $1::vector LIMIT $2` directly, so there is no
--     function to install and no migration to re-run;
--   * the Row Level Security policies — those call `auth.jwt()`, which only
--     exists on Supabase. This is your own database; its access control is
--     yours (connection string, roles, firewall), not this file's.
--
-- Run once on a FRESH database:
--   createdb waku
--   psql waku < sql/init_postgres.sql
--
-- Then point the port at it:
--   export WAKU_SEMANTIC_STORE=postgres
--   export DATABASE_URL=postgres://user:pass@localhost:5432/waku
--   export OPENAI_API_KEY=sk-...
--
-- The embedding width is OpenAI text-embedding-3-small (1536). A different
-- model needs a different column — vectors do not truncate.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS rag_chunks (
    id BIGSERIAL PRIMARY KEY,
    chunk_id TEXT NOT NULL UNIQUE,
    source TEXT NOT NULL,
    text TEXT NOT NULL,
    embedding VECTOR(1536),
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Vector similarity index (IVFFlat, cosine) plus the B-tree indexes the
-- dashboard's listing and the id/chunk_id lookups read.
CREATE INDEX IF NOT EXISTS rag_chunks_vec_idx
    ON rag_chunks USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX IF NOT EXISTS rag_chunks_src_idx ON rag_chunks (source);
CREATE INDEX IF NOT EXISTS rag_chunks_chunk_id_idx ON rag_chunks (chunk_id);
CREATE INDEX IF NOT EXISTS rag_chunks_created_at_idx ON rag_chunks (created_at DESC);
