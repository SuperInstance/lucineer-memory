-- Lucineer Memory D1 Schema — Player Saves
-- Additions to the existing schema.sql for the save system.
-- Run this against the lucineer-memory D1 database.
-- Date: 2026-08-02
--
-- This table stores small per-player save data (inventory, era, bond, etc).
-- Large data (build snapshots, terrain) goes to R2 bucket "lucineer-saves".

CREATE TABLE IF NOT EXISTS player_saves (
  player_name TEXT NOT NULL,
  save_key TEXT NOT NULL,
  save_data TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (player_name, save_key)
);

-- Index for fast player lookups
CREATE INDEX IF NOT EXISTS idx_player_saves_player ON player_saves(player_name);
CREATE INDEX IF NOT EXISTS idx_player_saves_key ON player_saves(save_key);
CREATE INDEX IF NOT EXISTS idx_player_saves_updated ON player_saves(updated_at DESC);
