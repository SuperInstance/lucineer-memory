-- Lucineer Memory D1 Schema — Persistence Layer (Tubes, Guano, Claw Marks, Grain)
-- Additions to the existing schema.sql for the St. Lazaria persistence model.
-- Run this against the lucineer-memory D1 database.
-- Date: 2026-08-03
--
-- Source design: PERSISTENCE_LAYER_DESIGN.md (Tube/Guano/Claw Marks),
-- CHISEL_PATTERN_DESIGN.md (Grain), INTEGRATED_ARCHITECTURE.md §3 Layer 0.
--
-- Scope note: this migration covers the four stores explicitly requested —
-- Tubes, Guano, Claw Marks, Grain. Lineage (lineage_chains,
-- agent_reproductions) is the fifth Layer-0 component in
-- INTEGRATED_ARCHITECTURE.md's table mapping and is deliberately NOT
-- included here.
--
-- Status per ROADMAP_whats_next.md: this whole layer is ~5% implemented and
-- explicitly filed as "Phase 2 — not needed for MVP." This schema exists so
-- the design is ready to apply when that phase starts; it does not imply
-- these tables should be wired into the live single-agent MVP loop now.
--
-- Convention note: this repo applies schema-*.sql files by hand against D1
-- (no `wrangler d1 migrations` directory/tracking exists yet). This file
-- follows that convention for consistency. If the number of schema files
-- keeps growing, moving to `wrangler d1 migrations create` (numbered,
-- applied-state tracked) is worth doing — see TYPESCRIPT_AUDIT.md.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. TUBES — Persistent session envelope (PERSISTENCE_LAYER_DESIGN.md §1)
-- ═══════════════════════════════════════════════════════════════════════════
-- A Tube is the container that survives after a session ends. It doesn't
-- know what agent it's for — it has shape (context window, tools, model
-- config, permissions, memory bindings) and agents either fit or they don't.

CREATE TABLE IF NOT EXISTS tubes (
  tube_id             TEXT PRIMARY KEY,
  -- TubeShape — the "geology" that determines what can inhabit this tube
  context_window      INTEGER NOT NULL,          -- tokens, the tube's "width"
  tool_registry        TEXT NOT NULL DEFAULT '[]', -- JSON array of tool names
  model_config         TEXT NOT NULL DEFAULT '{}', -- JSON: ModelConfig
  permissions          TEXT NOT NULL DEFAULT '{}', -- JSON: PermissionSet
  memory_bindings       TEXT NOT NULL DEFAULT '[]', -- JSON array of MemoryBinding

  -- Accumulated state — the worn stone, the deepened soil
  soil_depth            REAL NOT NULL DEFAULT 0,   -- accumulated context richness metric

  -- Current state
  current_session_id    TEXT,                      -- NULL when empty (puffin has left)
  cleanliness            TEXT NOT NULL DEFAULT 'fresh'
                          CHECK (cleanliness IN ('fresh', 'settled', 'fossilized')),

  created_at             INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  last_occupied          INTEGER
);

CREATE INDEX IF NOT EXISTS idx_tubes_cleanliness ON tubes(cleanliness);
CREATE INDEX IF NOT EXISTS idx_tubes_last_occupied ON tubes(last_occupied);
CREATE INDEX IF NOT EXISTS idx_tubes_current_session ON tubes(current_session_id);

-- Shape modifications: cumulative, append-only wear from usage patterns.
-- Never updated in place — a tube's shape is the fold of every patch applied
-- to it, in order. This mirrors "the tube doesn't record the bird; the tube
-- is shaped by the bird."
CREATE TABLE IF NOT EXISTS tube_patches (
  patch_id       INTEGER PRIMARY KEY AUTOINCREMENT,
  tube_id        TEXT NOT NULL,
  session_id     TEXT,                     -- session that produced this patch, if any
  patch          TEXT NOT NULL,            -- JSON: the Patch (what changed, and how)
  applied_at     INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),

  FOREIGN KEY (tube_id) REFERENCES tubes(tube_id)
);

CREATE INDEX IF NOT EXISTS idx_tube_patches_tube ON tube_patches(tube_id);
CREATE INDEX IF NOT EXISTS idx_tube_patches_applied ON tube_patches(tube_id, applied_at);

-- Inhabitant history: lightweight per-session summaries, NOT full transcripts.
-- Full session context is R2 ephemeral (flushed on session end); this is the
-- durable index into "who lived here and roughly what happened."
CREATE TABLE IF NOT EXISTS session_records (
  session_id     TEXT PRIMARY KEY,
  tube_id        TEXT NOT NULL,
  agent_id       TEXT,
  started_at     INTEGER NOT NULL,
  ended_at       INTEGER,
  summary        TEXT,                     -- short natural-language summary, not a transcript
  outcome        TEXT CHECK (outcome IN ('completed', 'abandoned', 'errored') OR outcome IS NULL),

  FOREIGN KEY (tube_id) REFERENCES tubes(tube_id)
);

CREATE INDEX IF NOT EXISTS idx_session_records_tube ON session_records(tube_id);
CREATE INDEX IF NOT EXISTS idx_session_records_started ON session_records(started_at);

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. GUANO — Ephemeral output decay pipeline (PERSISTENCE_LAYER_DESIGN.md §2)
-- ═══════════════════════════════════════════════════════════════════════════
-- Only the SOIL tier lands in D1. FRESH and COMPOSTING are R2 (hot/warm
-- buckets, TTL'd); SUBSTRATE is Vectorize; GEOLOGICAL is folded into base
-- context and stops being a tracked record at all. Per
-- INTEGRATED_ARCHITECTURE.md §3: "SOIL: Storage: D1 (structured patterns) +
-- Vectorize (semantic)."

CREATE TABLE IF NOT EXISTS behavioral_patterns (
  pattern_id           TEXT PRIMARY KEY,
  tube_id              TEXT,
  session_id           TEXT,                 -- originating session, if traceable
  pattern_type         TEXT NOT NULL,        -- e.g. 'tool_sequence', 'error_cluster', 'timing'
  description          TEXT NOT NULL,        -- "error rate clusters around context length > 120k"

  occurrence_count     INTEGER NOT NULL DEFAULT 1,
  first_observed       INTEGER NOT NULL,
  last_observed        INTEGER NOT NULL,

  -- Tier within this table's own lifecycle: SOIL patterns that prove
  -- recurrent get promoted to SUBSTRATE (still tracked here, now with an
  -- embedding_id) before eventually being folded into GEOLOGICAL and
  -- deleted from this table entirely.
  tier                 TEXT NOT NULL DEFAULT 'soil'
                        CHECK (tier IN ('soil', 'substrate')),
  embedding_id         TEXT,                  -- Vectorize ref, set once promoted to substrate
  promoted_at          INTEGER,

  -- "The exception: anomalies flagged during composting are preserved as
  -- full entries." Anomalous patterns are exempt from the normal prune-if-
  -- low-recurrence sweep.
  anomaly               INTEGER NOT NULL DEFAULT 0,
  source_summary_ref     TEXT,                 -- R2 key of the COMPOSTING summary this came from

  created_at             INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),

  FOREIGN KEY (tube_id) REFERENCES tubes(tube_id)
);

CREATE INDEX IF NOT EXISTS idx_behavioral_patterns_tube ON behavioral_patterns(tube_id);
CREATE INDEX IF NOT EXISTS idx_behavioral_patterns_type ON behavioral_patterns(pattern_type);
CREATE INDEX IF NOT EXISTS idx_behavioral_patterns_tier ON behavioral_patterns(tier);
CREATE INDEX IF NOT EXISTS idx_behavioral_patterns_anomaly ON behavioral_patterns(anomaly);

-- "Decay is observable. The system tracks what was lost, not just what was
-- kept." One row per cron decay pass, at any tier boundary.
CREATE TABLE IF NOT EXISTS guano_decay_runs (
  run_id                INTEGER PRIMARY KEY AUTOINCREMENT,
  tier_from             TEXT NOT NULL CHECK (tier_from IN ('fresh', 'composting', 'soil', 'substrate')),
  tier_to               TEXT NOT NULL CHECK (tier_to IN ('composting', 'soil', 'substrate', 'geological')),
  records_in            INTEGER NOT NULL,
  records_out           INTEGER NOT NULL,
  anomalies_preserved   INTEGER NOT NULL DEFAULT 0,
  run_at                INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_guano_decay_runs_at ON guano_decay_runs(run_at DESC);

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. CLAW MARKS — Accumulated modifications to shared model parameters
--    (PERSISTENCE_LAYER_DESIGN.md §3)
-- ═══════════════════════════════════════════════════════════════════════════
-- LoRA adapters (grooved marks) are R2 model artifacts, not D1 rows — only
-- their metadata/reinforcement state lives here if/when that category is
-- added. This migration covers the two categories the design doc maps to D1:
-- polished marks (prompt evolution) and fossilized marks (config changes).

CREATE TABLE IF NOT EXISTS prompt_history (
  mark_id              TEXT PRIMARY KEY,
  tube_id              TEXT,
  prompt_text          TEXT NOT NULL,
  version              INTEGER NOT NULL DEFAULT 1,

  -- "Depth — how many sessions contributed to this mark"
  depth                INTEGER NOT NULL DEFAULT 1,
  reinforcements       INTEGER NOT NULL DEFAULT 0,  -- successful sessions using this prompt
  erosions             INTEGER NOT NULL DEFAULT 0,  -- failed sessions against this prompt
  erosion_rate         REAL NOT NULL DEFAULT 0.01,  -- inversely proportional to depth
  reversibility        TEXT NOT NULL DEFAULT 'polished'
                        CHECK (reversibility IN ('polished', 'grooved', 'fossilized')),

  last_reinforced      INTEGER NOT NULL,
  r2_object_key        TEXT,                        -- versioned prompt object in R2

  created_at           INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),

  FOREIGN KEY (tube_id) REFERENCES tubes(tube_id)
);

CREATE INDEX IF NOT EXISTS idx_prompt_history_tube ON prompt_history(tube_id);
CREATE INDEX IF NOT EXISTS idx_prompt_history_reversibility ON prompt_history(reversibility);
CREATE INDEX IF NOT EXISTS idx_prompt_history_last_reinforced ON prompt_history(last_reinforced);

-- "Proposal-based: agent suggests, platform validates, applies after N
-- successes." Config changes start as proposals and only take effect once
-- reinforced — never applied on a single session's say-so.
CREATE TABLE IF NOT EXISTS config_patches (
  patch_id             TEXT PRIMARY KEY,
  tube_id              TEXT,
  substrate_type       TEXT NOT NULL CHECK (substrate_type IN ('weights', 'prompt', 'tools', 'config')),
  proposed_by          TEXT NOT NULL,               -- agent_id that proposed it
  delta                TEXT NOT NULL,                -- JSON: ToolConfigDelta

  status               TEXT NOT NULL DEFAULT 'proposed'
                        CHECK (status IN ('proposed', 'validating', 'applied', 'rejected')),
  success_count        INTEGER NOT NULL DEFAULT 0,
  required_successes   INTEGER NOT NULL DEFAULT 5,

  applied_at           INTEGER,
  created_at           INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),

  FOREIGN KEY (tube_id) REFERENCES tubes(tube_id)
);

CREATE INDEX IF NOT EXISTS idx_config_patches_status ON config_patches(status);
CREATE INDEX IF NOT EXISTS idx_config_patches_tube ON config_patches(tube_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. GRAIN STORES — Tool-usage wisdom (CHISEL_PATTERN_DESIGN.md §2, Appendix A)
-- ═══════════════════════════════════════════════════════════════════════════
-- "D1 table: grain_entries (raw usage records) / D1 table: grain_patterns
-- (distilled wisdom) / Vectorize index: grain_embeddings (semantic search)."
-- Compaction: raw entries TTL 7d, prune patterns below 0.3 confidence,
-- reinforce above 0.7, max 50 patterns per tool+context bucket.

CREATE TABLE IF NOT EXISTS grain_entries (
  entry_id             TEXT PRIMARY KEY,
  tool_name            TEXT NOT NULL,               -- which Chisel-wrapped tool
  agent_id             TEXT NOT NULL,
  tube_id              TEXT,
  era                  INTEGER,

  context              TEXT NOT NULL,                -- JSON: ContextVector (world state at use)
  parameters           TEXT NOT NULL,                -- JSON: ParamSet passed in
  outcome              TEXT NOT NULL CHECK (outcome IN ('success', 'partial', 'failure')),
  outcome_quality      REAL NOT NULL CHECK (outcome_quality BETWEEN 0 AND 1),
  recovery             TEXT,                          -- JSON: Recovery, nullable
  agent_notes          TEXT,

  created_at           INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),

  FOREIGN KEY (tube_id) REFERENCES tubes(tube_id)
);

CREATE INDEX IF NOT EXISTS idx_grain_entries_tool ON grain_entries(tool_name);
CREATE INDEX IF NOT EXISTS idx_grain_entries_agent ON grain_entries(agent_id);
CREATE INDEX IF NOT EXISTS idx_grain_entries_created ON grain_entries(created_at);
-- Compaction sweep scans raw entries older than the 7-day TTL:
CREATE INDEX IF NOT EXISTS idx_grain_entries_tool_created ON grain_entries(tool_name, created_at);

CREATE TABLE IF NOT EXISTS grain_patterns (
  pattern_id           TEXT PRIMARY KEY,
  tool_name            TEXT NOT NULL,
  -- Grouping key for "max 50 patterns per tool per context-bucket" pruning.
  -- A coarse hash/label derived from context_matcher, not the full matcher.
  context_bucket       TEXT NOT NULL DEFAULT '',
  description          TEXT NOT NULL,                -- "torque=0.7 succeeds 89% of the time"
  context_matcher      TEXT NOT NULL,                 -- JSON: ContextFilter
  param_template       TEXT NOT NULL,                 -- JSON: suggested ParamSet

  confidence           REAL NOT NULL DEFAULT 0 CHECK (confidence BETWEEN 0 AND 1),
  success_rate         REAL NOT NULL DEFAULT 0 CHECK (success_rate BETWEEN 0 AND 1),
  supporting_entries   INTEGER NOT NULL DEFAULT 0,    -- count of grain_entries backing this pattern

  era_origin           INTEGER,                        -- which era discovered this
  discovered_by        TEXT NOT NULL DEFAULT '[]',     -- JSON array of agent_ids (chain of hands)
  embedding_id         TEXT,                            -- Vectorize ref (grain_embeddings)

  created_at           INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  updated_at           INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_grain_patterns_tool ON grain_patterns(tool_name);
CREATE INDEX IF NOT EXISTS idx_grain_patterns_confidence ON grain_patterns(confidence DESC);
-- Prune sweep: patterns below min_pattern_confidence (0.3), grouped by bucket:
CREATE INDEX IF NOT EXISTS idx_grain_patterns_bucket ON grain_patterns(tool_name, context_bucket, confidence);

-- ═══════════════════════════════════════════════════════════════════════════
-- SCHEMA METADATA
-- ═══════════════════════════════════════════════════════════════════════════
-- schema_info is also created by schema-analytics.sql. Declared here too
-- (IF NOT EXISTS) so this file has no apply-order dependency on that one.

CREATE TABLE IF NOT EXISTS schema_info (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT OR REPLACE INTO schema_info (key, value) VALUES
  ('persistence_schema_version', '1.0.0'),
  ('persistence_schema_date', '2026-08-03'),
  ('persistence_schema_covers', 'tubes,tube_patches,session_records,behavioral_patterns,guano_decay_runs,prompt_history,config_patches,grain_entries,grain_patterns'),
  ('persistence_schema_excludes', 'lineage_chains,agent_reproductions (not requested in this migration)');
