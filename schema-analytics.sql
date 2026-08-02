-- =============================================================================
-- SLACKWATER ANALYTICS SCHEMA
-- D1 (Cloudflare D1 / SQLite-compatible)
-- =============================================================================
-- This schema supports the MOLT reward function (MOLT_REWARD_FUNCTION.py).
-- Every table here exists to measure what we VALUE:
--   craft, cooperation, continuity, and cognitive efficiency.
--
-- What this schema deliberately does NOT track:
--   - session_duration as a success metric (we store it, but it's not a KPI)
--   - click counts
--   - daily streaks
--   - messages per session as a volume metric
--   - screen time
--
-- "The reward function is a moral act."
-- What we choose to store is what we choose to see.
-- What we choose to see is what we choose to reward.
-- What we choose to reward is what the agent becomes.
-- =============================================================================

-- =============================================================================
-- TABLE: player_sessions
-- =============================================================================
-- A single play session. One row per login-to-logout.
-- Note: duration_seconds is stored for operational purposes (cost analysis,
-- server capacity), NOT as a reward signal. Time-in-game is an engagement
-- metric. We store it because we need it for infrastructure, not because we
-- value it.

CREATE TABLE IF NOT EXISTS player_sessions (
    session_id      TEXT PRIMARY KEY,
    player_id       TEXT NOT NULL,
    join_time       INTEGER NOT NULL,          -- Unix timestamp (seconds)
    leave_time      INTEGER,                    -- NULL if session still active
    duration_seconds INTEGER GENERATED ALWAYS AS (leave_time - join_time) STORED,

    -- Session context
    era_at_start    INTEGER NOT NULL DEFAULT 1,
    era_at_end      INTEGER NOT NULL DEFAULT 1,
    bond_stage_at_start INTEGER NOT NULL DEFAULT 1,
    bond_stage_at_end   INTEGER NOT NULL DEFAULT 1,

    -- Aggregate counts (updated on session end)
    builds_made     INTEGER NOT NULL DEFAULT 0,
    builds_kept     INTEGER NOT NULL DEFAULT 0,
    builds_deleted  INTEGER NOT NULL DEFAULT 0,
    builds_modified INTEGER NOT NULL DEFAULT 0,
    builds_completed INTEGER NOT NULL DEFAULT 0,  -- Gaps filled (Unfinished Rule)
    conversations_had INTEGER NOT NULL DEFAULT 0,
    parts_placed    INTEGER NOT NULL DEFAULT 0,

    -- Server context
    server_id       TEXT,
    platform        TEXT,                        -- "mobile", "desktop", "tablet"

    -- Metadata
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_sessions_player ON player_sessions(player_id);
CREATE INDEX IF NOT EXISTS idx_sessions_join ON player_sessions(join_time);
CREATE INDEX IF NOT EXISTS idx_sessions_player_join ON player_sessions(player_id, join_time);


-- =============================================================================
-- TABLE: build_events
-- =============================================================================
-- Every action taken on a build: creation, modification, deletion, retention
-- across a session boundary, and gap completion. This is the raw signal that
-- feeds measure_build_retention() in the reward function.
--
-- The Unfinished Rule: every Lucineer solo build has exactly one gap.
-- When a player fills that gap, a build_event with action='completed' is logged.
-- This is the single most important behavioral signal in the game.

CREATE TABLE IF NOT EXISTS build_events (
    event_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    build_id        TEXT NOT NULL,
    player_id       TEXT NOT NULL,              -- Who performed the action
    action          TEXT NOT NULL CHECK (
                        action IN ('created', 'modified', 'deleted', 'kept', 'completed', 'abandoned')
                    ),

    -- Build state at time of event
    part_count      INTEGER,                     -- Total parts in build
    era             INTEGER,                      -- Technology era (1-7)
    has_gap         INTEGER DEFAULT 0,            -- Boolean: does build have Unfinished Rule gap?
    gap_filled_by   TEXT,                         -- Player ID who filled the gap (if any)

    -- Attribution
    player_parts    INTEGER DEFAULT 0,            -- Parts placed by player
    agent_parts     INTEGER DEFAULT 0,            -- Parts placed by agent(s)

    -- Positional summary (bounding box)
    min_x           REAL,
    max_x           REAL,
    min_y           REAL,
    max_y           REAL,
    min_z           REAL,
    max_z           REAL,

    -- Context
    session_id      TEXT,
    server_id       TEXT,
    timestamp       INTEGER NOT NULL,             -- Unix timestamp
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),

    -- Relationship to previous event on same build
    previous_event_id INTEGER,

    FOREIGN KEY (session_id) REFERENCES player_sessions(session_id)
);

CREATE INDEX IF NOT EXISTS idx_build_events_build ON build_events(build_id);
CREATE INDEX IF NOT EXISTS idx_build_events_player ON build_events(player_id);
CREATE INDEX IF NOT EXISTS idx_build_events_action ON build_events(action);
CREATE INDEX IF NOT EXISTS idx_build_events_build_ts ON build_events(build_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_build_events_session ON build_events(session_id);


-- =============================================================================
-- TABLE: build_parts
-- =============================================================================
-- Individual parts within builds. Used for craft_quality measurement
-- (structural integrity, material diversity, aesthetic balance).
-- This is granular data — one row per placed part.

CREATE TABLE IF NOT EXISTS build_parts (
    part_id         TEXT PRIMARY KEY,            -- Unique part identifier
    build_id        TEXT NOT NULL,
    placed_by       TEXT NOT NULL,               -- "lucineer", "player:<id>", "agent:<id>"
    part_type       TEXT NOT NULL,               -- e.g., "oak_beam", "tin_sheet"
    material        TEXT NOT NULL,               -- e.g., "wood", "metal", "stone", "glass"

    -- Position and rotation
    pos_x           REAL NOT NULL,
    pos_y           REAL NOT NULL,
    pos_z           REAL NOT NULL,
    rot_x           REAL DEFAULT 0,
    rot_y           REAL DEFAULT 0,
    rot_z           REAL DEFAULT 0,

    -- Flags
    is_gap_filler   INTEGER NOT NULL DEFAULT 0,  -- This part fills an Unfinished Rule gap
    is_deliberate_flaw INTEGER NOT NULL DEFAULT 0, -- Known flaw placed for detection (Stage 1)

    -- Context
    era             INTEGER DEFAULT 1,
    session_id      TEXT,
    server_id       TEXT,
    timestamp       INTEGER NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),

    FOREIGN KEY (build_id) REFERENCES build_events(build_id),
    FOREIGN KEY (session_id) REFERENCES player_sessions(session_id)
);

CREATE INDEX IF NOT EXISTS idx_parts_build ON build_parts(build_id);
CREATE INDEX IF NOT EXISTS idx_parts_placed_by ON build_parts(placed_by);
CREATE INDEX IF NOT EXISTS idx_parts_material ON build_parts(material);
CREATE INDEX IF NOT EXISTS idx_parts_session ON build_parts(session_id);


-- =============================================================================
-- TABLE: conversation_events
-- =============================================================================
-- Every conversation between player and agent. Stores the aggregate metrics
-- for the exchange; individual turns go in conversation_turns.
--
-- conversation_type is the KEY field — it classifies the RELATIONSHIP quality:
--   command      — Player issued a request, no real exchange
--   negotiation  — Substantive back-and-forth (≥3 turns of substance)
--   argument     — Player pushed back on agent's design decision
--   collaboration — Player built alongside, agent commented
--   silence      — Player stood near agent without typing (Slack Tide Stand)
--
-- negotiation_score: 0.0-1.0, computed by the reward function's
-- cooperation_depth measurement. Captures how much genuine collaboration
-- occurred vs. pure command-consume behavior.

CREATE TABLE IF NOT EXISTS conversation_events (
    conversation_id     TEXT PRIMARY KEY,
    player_id           TEXT NOT NULL,
    agent_id            TEXT NOT NULL,           -- "lucineer", "march", "earl", etc.
    session_id          TEXT,

    conversation_type   TEXT NOT NULL CHECK (
                            conversation_type IN ('command', 'negotiation', 'argument',
                                                  'collaboration', 'silence')
                        ),

    -- Conversation metrics
    message_count       INTEGER NOT NULL DEFAULT 0,
    player_messages     INTEGER NOT NULL DEFAULT 0,
    agent_messages      INTEGER NOT NULL DEFAULT 0,
    avg_message_length  REAL,                     -- Average characters per message

    -- Quality metrics (computed by reward function)
    negotiation_score   REAL DEFAULT 0.0,         -- 0.0-1.0: depth of cooperation
    argument_resolved   TEXT,                      -- "won", "lost", "compromised", "unresolved", NULL
    contained_flaw_callout INTEGER DEFAULT 0,      -- Did player spot a deliberate flaw?

    -- Build context (was this conversation about a specific build?)
    related_build_id    TEXT,

    -- Bond progression
    bond_stage_before   INTEGER,
    bond_stage_after    INTEGER,

    -- Timing
    start_time          INTEGER NOT NULL,
    end_time            INTEGER,
    duration_seconds    INTEGER,

    server_id           TEXT,
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),

    FOREIGN KEY (session_id) REFERENCES player_sessions(session_id)
);

CREATE INDEX IF NOT EXISTS idx_conv_player ON conversation_events(player_id);
CREATE INDEX IF NOT EXISTS idx_conv_agent ON conversation_events(agent_id);
CREATE INDEX IF NOT EXISTS idx_conv_session ON conversation_events(session_id);
CREATE INDEX IF NOT EXISTS idx_conv_type ON conversation_events(conversation_type);
CREATE INDEX IF NOT EXISTS idx_conv_player_time ON conversation_events(player_id, start_time);


-- =============================================================================
-- TABLE: conversation_turns
-- =============================================================================
-- Individual messages within conversations. Used for detailed analysis of
-- cooperation patterns, argument quality, and voice consistency.
-- Also the source data for the flaw-callout detection (Stage 1→2 transition).

CREATE TABLE IF NOT EXISTS conversation_turns (
    turn_id             INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id     TEXT NOT NULL,
    turn_index          INTEGER NOT NULL,
    speaker             TEXT NOT NULL,           -- "player" or "agent:<id>"
    content             TEXT NOT NULL,           -- The message (filtered, post-FilterStringAsync)
    content_hash        TEXT,                     -- SHA-256 of content (for dedup analysis)
    char_count          INTEGER,
    word_count          INTEGER,

    -- Agent-specific metadata
    model_version       TEXT,                     -- Which model generated this (for agent turns)
    prompt_version      TEXT,                     -- System prompt version used
    response_time_ms    INTEGER,                  -- Latency (agent turns only)

    -- Flags
    contained_build_command INTEGER DEFAULT 0,    -- Did this message produce a build action?
    safety_filtered     INTEGER DEFAULT 0,        -- Was content modified by safety filter?
    is_flaw_callout     INTEGER DEFAULT 0,        -- Did player identify a deliberate flaw?

    timestamp           INTEGER NOT NULL,
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),

    FOREIGN KEY (conversation_id) REFERENCES conversation_events(conversation_id)
);

CREATE INDEX IF NOT EXISTS idx_turns_conv ON conversation_turns(conversation_id);
CREATE INDEX IF NOT EXISTS idx_turns_speaker ON conversation_turns(speaker);
CREATE INDEX IF NOT EXISTS idx_turns_conv_idx ON conversation_turns(conversation_id, turn_index);


-- =============================================================================
-- TABLE: retention_signals
-- =============================================================================
-- One row per player. Updated by a periodic job (not per-session).
--
-- This table measures RETURN behavior — not engagement, not addiction.
-- day_1_return: did the player come back within 1 day of their first session?
-- day_7_return: within 7 days?
-- day_30_return: within 30 days?
--
-- These are the signals that feed measure_return_rate() in the reward function.
-- They measure curiosity about a character who changes, not compulsion.
-- "He might say something different today."

CREATE TABLE IF NOT EXISTS retention_signals (
    player_id           TEXT PRIMARY KEY,
    first_session_date  TEXT NOT NULL,           -- YYYY-MM-DD of first session
    last_session_date   TEXT,                     -- YYYY-MM-DD of most recent session

    -- Return flags (boolean, updated by periodic job)
    day_1_return        INTEGER DEFAULT 0,
    day_7_return        INTEGER DEFAULT 0,
    day_30_return       INTEGER DEFAULT 0,

    -- Session frequency (NOT a streak — just counts)
    total_sessions      INTEGER DEFAULT 0,
    total_active_days   INTEGER DEFAULT 0,       -- Distinct calendar days with ≥1 real session
    total_builds_ever   INTEGER DEFAULT 0,
    total_gaps_filled   INTEGER DEFAULT 0,       -- Career Unfinished Rule completions

    -- Return quality (anti-addiction signals)
    avg_sessions_per_active_day  REAL DEFAULT 0.0,
    avg_session_gap_days         REAL,            -- Average days between sessions
    longest_gap_days             INTEGER,         -- Longest gap between sessions

    -- Bond arc progression
    max_bond_stage_reached       INTEGER DEFAULT 1,
    max_era_reached              INTEGER DEFAULT 1,

    updated_at          TEXT NOT NULL DEFAULT (datetime('now'))
);


-- =============================================================================
-- TABLE: craft_quality_scores
-- =============================================================================
-- Computed quality scores for builds. Populated by a periodic evaluation job
-- that runs the craft measurement functions from MOLT_REWARD_FUNCTION.py.
--
-- These scores feed measure_craft_quality() in the reward function and also
-- serve as the training signal for RL fine-tuning of build agents.

CREATE TABLE IF NOT EXISTS craft_quality_scores (
    score_id            INTEGER PRIMARY KEY AUTOINCREMENT,
    build_id            TEXT NOT NULL UNIQUE,
    player_id           TEXT NOT NULL,

    -- Sub-scores (each 0.0-1.0)
    structural_integrity    REAL NOT NULL DEFAULT 0.0,
    material_diversity      REAL NOT NULL DEFAULT 0.0,
    aesthetic_balance       REAL NOT NULL DEFAULT 0.0,
    overall_craft_score     REAL NOT NULL DEFAULT 0.0,  -- Weighted combination

    -- Detailed metrics (for analysis and debugging)
    part_count              INTEGER,
    foundation_ratio        REAL,   -- % of parts at ground level
    support_ratio           REAL,   -- % of parts with support below
    com_stability           REAL,   -- Center of mass stability score
    connectivity            REAL,   -- Largest connected component ratio
    num_unique_materials    INTEGER,
    material_entropy        REAL,   -- Normalized Shannon entropy of materials
    symmetry_score          REAL,   -- Bilateral symmetry around centroid
    proportion_ratio        REAL,   -- Height-to-width ratio
    spatial_distribution_cv REAL,   -- Coefficient of variation of inter-part distances

    -- Context
    era                     INTEGER,
    era_material_bonus      REAL,
    overbuild_penalty       REAL DEFAULT 0.0,
    restraint_bonus         REAL DEFAULT 0.0,

    -- Build attribution
    is_jointly_built        INTEGER DEFAULT 0,
    player_part_ratio       REAL,   -- Fraction of parts placed by player

    -- Scoring metadata
    scored_at               TEXT NOT NULL DEFAULT (datetime('now')),
    scoring_version         TEXT DEFAULT '1.0.0',

    FOREIGN KEY (build_id) REFERENCES build_events(build_id)
);

CREATE INDEX IF NOT EXISTS idx_craft_player ON craft_quality_scores(player_id);
CREATE INDEX IF NOT EXISTS idx_craft_score ON craft_quality_scores(overall_craft_score);
CREATE INDEX IF NOT EXISTS idx_craft_structural ON craft_quality_scores(structural_integrity);


-- =============================================================================
-- TABLE: reward_computations
-- =============================================================================
-- Audit log of every reward computation. One row per call to compute_reward().
-- This creates a full record of what the reward function measured and why,
-- enabling debugging, analysis, and training dataset construction.

CREATE TABLE IF NOT EXISTS reward_computations (
    computation_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id          TEXT NOT NULL,
    player_id           TEXT NOT NULL,
    agent_id            TEXT DEFAULT 'lucineer',

    -- Component scores (each 0.0-1.0)
    build_retention     REAL NOT NULL,
    cooperation_depth   REAL NOT NULL,
    return_rate         REAL NOT NULL,
    craft_quality       REAL NOT NULL,
    energy_efficiency   REAL NOT NULL,

    -- Final reward
    reward              REAL NOT NULL,

    -- Weight configuration used (JSON)
    weights_config      TEXT NOT NULL,

    -- Explanation (human-readable, from _generate_explanation)
    explanation         TEXT,

    -- Timestamps
    computed_at         TEXT NOT NULL DEFAULT (datetime('now')),
    session_end_time    INTEGER NOT NULL,

    FOREIGN KEY (session_id) REFERENCES player_sessions(session_id)
);

CREATE INDEX IF NOT EXISTS idx_reward_session ON reward_computations(session_id);
CREATE INDEX IF NOT EXISTS idx_reward_player ON reward_computations(player_id);
CREATE INDEX IF NOT EXISTS idx_reward_score ON reward_computations(reward);


-- =============================================================================
-- TABLE: trajectory_logs
-- =============================================================================
-- MOLT-format trajectory data. Each row is a complete agent decision trace:
-- what the model received as input, what it produced, what happened next.
--
-- This is the training dataset. Per FABLE_5_PRODUCTION_DESIGN.md §5:
-- "Trajectory instrumentation in MOLT's Result format. Every deep-path job
-- already produces (state, prompt, tool calls, outcome). Log them now,
-- shaped as MOLT trajectories, into R2."
--
-- In production, these would be stored as objects in R2 (Cloudflare object
-- storage) rather than D1 rows, because the raw token traces are large.
-- This table serves as an INDEX into R2 objects.

CREATE TABLE IF NOT EXISTS trajectory_logs (
    trajectory_id       TEXT PRIMARY KEY,        -- Unique ID
    session_id          TEXT NOT NULL,
    job_id              TEXT,                     -- Worker job ID
    player_id           TEXT NOT NULL,
    agent_id            TEXT NOT NULL,

    -- Model info
    model_version       TEXT NOT NULL,
    prompt_version      TEXT NOT NULL,

    -- MOLT token-first contract fields
    raw_output_hash     TEXT,                     -- Hash of exact model output
    token_count         INTEGER,
    -- Token IDs and logprobs stored in R2 (too large for D1)
    r2_object_key       TEXT,                     -- R2 object key for full trajectory

    -- Parsed command info
    parsed_commands     TEXT,                     -- JSON array of parsed game commands
    execution_success   INTEGER DEFAULT 0,
    execution_errors    TEXT,                     -- JSON array of error messages

    -- Reward components at trajectory level
    reward_components   TEXT,                     -- JSON dict of reward breakdown
    total_reward        REAL,

    -- Timing
    request_time        INTEGER NOT NULL,         -- When request was sent to model
    response_time       INTEGER,                  -- When response was received
    latency_ms          INTEGER,                  -- response_time - request_time (ms)

    created_at          TEXT NOT NULL DEFAULT (datetime('now')),

    FOREIGN KEY (session_id) REFERENCES player_sessions(session_id)
);

CREATE INDEX IF NOT EXISTS idx_traj_player ON trajectory_logs(player_id);
CREATE INDEX IF NOT EXISTS idx_traj_agent ON trajectory_logs(agent_id);
CREATE INDEX IF NOT EXISTS idx_traj_model ON trajectory_logs(model_version);
CREATE INDEX IF NOT EXISTS idx_traj_session ON trajectory_logs(session_id);


-- =============================================================================
-- TABLE: agent_state_snapshots
-- =============================================================================
-- Periodic snapshots of agent state (bond stage, era, position, activity).
-- Used to reconstruct agent behavior patterns for RL training and to
-- populate the MOLT Env's state representation.

CREATE TABLE IF NOT EXISTS agent_state_snapshots (
    snapshot_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id            TEXT NOT NULL,
    server_id           TEXT NOT NULL,

    -- Agent state
    bond_stage          INTEGER NOT NULL,
    current_era         INTEGER NOT NULL,
    current_activity    TEXT,                     -- "hammering", "idle", "walking", "arguing"
    position_x          REAL,
    position_y          REAL,
    position_z          REAL,

    -- World state (summary)
    active_builds_count INTEGER DEFAULT 0,
    total_parts_in_world INTEGER DEFAULT 0,
    players_present     INTEGER DEFAULT 0,

    -- Conversation state
    active_conversation_player TEXT,              -- Player ID if in conversation

    snapshot_time       INTEGER NOT NULL,
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_snapshots_agent_time ON agent_state_snapshots(agent_id, snapshot_time);
CREATE INDEX IF NOT EXISTS idx_snapshots_server ON agent_state_snapshots(server_id);


-- =============================================================================
-- VIEWS: Analytical convenience views
-- =============================================================================

-- View: player_engagement_quality
-- A denormalized view that joins sessions, builds, and retention to give
-- a quick picture of a player's QUALITY (not engagement volume).
-- NOTE: This intentionally excludes time-in-game metrics.

CREATE VIEW IF NOT EXISTS player_engagement_quality AS
SELECT
    rs.player_id,
    COUNT(DISTINCT rs.session_id) as total_sessions,
    SUM(rs.builds_made) as total_builds,
    SUM(rs.builds_completed) as total_gaps_filled,
    AVG(cqs.overall_craft_score) as avg_craft_score,
    AVG(ce.negotiation_score) as avg_cooperation_score,
    ret.day_1_return,
    ret.day_7_return,
    ret.day_30_return,
    ret.max_bond_stage_reached,
    ret.max_era_reached,
    -- Quality signals only, never raw time metrics
    SUM(rs.builds_kept) as total_builds_kept,
    SUM(rs.builds_deleted) as total_builds_deleted,
    CASE
        WHEN SUM(rs.builds_made) > 0
        THEN CAST(SUM(rs.builds_kept) AS FLOAT) / SUM(rs.builds_made)
        ELSE 0
    END as build_retention_rate,
    CASE
        WHEN SUM(rs.builds_made) > 0
        THEN CAST(SUM(rs.builds_completed) AS FLOAT) / SUM(rs.builds_made)
        ELSE 0
    END as gap_completion_rate
FROM retention_signals ret
LEFT JOIN player_sessions rs ON ret.player_id = rs.player_id
LEFT JOIN craft_quality_scores cqs ON rs.player_id = cqs.player_id
LEFT JOIN conversation_events ce ON rs.player_id = ce.player_id
GROUP BY ret.player_id;


-- View: agent_training_summary
-- Daily rollup of reward computations for monitoring RL training progress.

CREATE VIEW IF NOT EXISTS agent_training_summary AS
SELECT
    DATE(rc.computed_at) as date,
    rc.agent_id,
    COUNT(*) as sessions_evaluated,
    AVG(rc.reward) as avg_reward,
    AVG(rc.build_retention) as avg_build_retention,
    AVG(rc.cooperation_depth) as avg_cooperation,
    AVG(rc.return_rate) as avg_return,
    AVG(rc.craft_quality) as avg_craft,
    AVG(rc.energy_efficiency) as avg_efficiency,
    MIN(rc.reward) as min_reward,
    MAX(rc.reward) as max_reward
FROM reward_computations rc
GROUP BY DATE(rc.computed_at), rc.agent_id
ORDER BY DATE(rc.computed_at) DESC;


-- View: build_quality_distribution
-- Distribution of craft quality scores across all builds, useful for
-- understanding the quality landscape and identifying outliers.

CREATE VIEW IF NOT EXISTS build_quality_distribution AS
SELECT
    cqs.era,
    COUNT(*) as build_count,
    AVG(cqs.overall_craft_score) as avg_craft,
    AVG(cqs.structural_integrity) as avg_structural,
    AVG(cqs.material_diversity) as avg_material,
    AVG(cqs.aesthetic_balance) as avg_aesthetic,
    AVG(cqs.symmetry_score) as avg_symmetry,
    AVG(cqs.part_count) as avg_part_count,
    SUM(CASE WHEN cqs.is_jointly_built = 1 THEN 1 ELSE 0 END) as jointly_built_count
FROM craft_quality_scores cqs
GROUP BY cqs.era
ORDER BY cqs.era;


-- =============================================================================
-- TRIGGERS: Auto-update denormalized counts
-- =============================================================================

-- Trigger: Update session build counts when build events occur
CREATE TRIGGER IF NOT EXISTS trg_update_session_builds
AFTER INSERT ON build_events
FOR EACH ROW
BEGIN
    UPDATE player_sessions
    SET
        builds_made = builds_made + CASE WHEN NEW.action = 'created' THEN 1 ELSE 0 END,
        builds_kept = builds_kept + CASE WHEN NEW.action = 'kept' THEN 1 ELSE 0 END,
        builds_deleted = builds_deleted + CASE WHEN NEW.action = 'deleted' THEN 1 ELSE 0 END,
        builds_modified = builds_modified + CASE WHEN NEW.action = 'modified' THEN 1 ELSE 0 END,
        builds_completed = builds_completed + CASE WHEN NEW.action = 'completed' THEN 1 ELSE 0 END,
        updated_at = datetime('now')
    WHERE session_id = NEW.session_id;
END;

-- Trigger: Update retention signals when sessions end
CREATE TRIGGER IF NOT EXISTS trg_update_retention_on_session_end
AFTER UPDATE OF leave_time ON player_sessions
FOR EACH ROW
WHEN NEW.leave_time IS NOT NULL
BEGIN
    INSERT OR IGNORE INTO retention_signals (player_id, first_session_date, last_session_date, total_sessions)
    VALUES (
        NEW.player_id,
        date(NEW.join_time, 'unixepoch'),
        date(NEW.leave_time, 'unixepoch'),
        1
    );

    UPDATE retention_signals
    SET
        last_session_date = date(NEW.leave_time, 'unixepoch'),
        total_sessions = total_sessions + 1,
        total_active_days = total_active_days + 1,
        updated_at = datetime('now')
    WHERE player_id = NEW.player_id;
END;


-- =============================================================================
-- SCHEMA METADATA
-- =============================================================================

CREATE TABLE IF NOT EXISTS schema_info (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

INSERT OR REPLACE INTO schema_info (key, value) VALUES
    ('schema_version', '1.0.0'),
    ('schema_name', 'slackwater-analytics'),
    ('description', 'Analytics schema for MOLT reward function. Measures craft, cooperation, continuity — never engagement.'),
    ('reward_function_version', '1.0.0'),
    ('created_date', '2026-08-02'),
    ('anti_metrics', 'session_duration,click_count,daily_streak,messages_per_session,parts_placed_count,api_calls_per_player,screen_time');


-- =============================================================================
-- DONE
-- =============================================================================
-- "The reward function is the most creative act in the entire system.
--  More creative than the model architecture. More creative than the prompt.
--  More creative than the environment design. Because the reward function
--  determines what everything else is FOR."
--
-- What we measure: craft, cooperation, continuity, efficiency.
-- What we refuse to measure: engagement, addiction, compulsion, extraction.
-- What we become: a game that values what a craftsman values.
-- =============================================================================
