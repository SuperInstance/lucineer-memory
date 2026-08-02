-- Lucineer Memory D1 Schema — Achievement Tracking
-- Additions to the existing schema.sql for the achievement system.
-- Run this against the lucineer-memory D1 database.
-- Date: 2026-08-02

-- ═══════════════════════════════════════════════════════════════════════════
-- ACHIEVEMENTS TABLE
-- ═══════════════════════════════════════════════════════════════════════════
-- Tracks which achievements each player has unlocked.
-- 49 achievements across 5 tiers (matching Magnus's Scrapcraft count).
-- Achievements are hidden from the player (per POLISH_PLAN §5.1) —
-- this table is for persistence and server-side tracking only.

CREATE TABLE IF NOT EXISTS achievements (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  player_name TEXT NOT NULL,
  achievement_id TEXT NOT NULL,
  unlocked_at INTEGER NOT NULL,
  UNIQUE(player_name, achievement_id),
  FOREIGN KEY (player_name) REFERENCES player_profiles(player_name)
);

-- Index for fast lookups
CREATE INDEX IF NOT EXISTS idx_achievements_player ON achievements(player_name);
CREATE INDEX IF NOT EXISTS idx_achievements_achievement_id ON achievements(achievement_id);
CREATE INDEX IF NOT EXISTS idx_achievements_unlocked_at ON achievements(unlocked_at DESC);
