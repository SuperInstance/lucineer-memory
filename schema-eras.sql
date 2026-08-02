-- Slackwater Technology Era System — D1 Schema
-- Created: 2026-08-02
-- Tables for era progression, player inventory, and craft history

-- Player era progression: tracks which eras each player has unlocked
CREATE TABLE IF NOT EXISTS player_eras (
  player_name TEXT PRIMARY KEY,
  current_era INTEGER DEFAULT 0,
  unlocked_eras TEXT DEFAULT '[0]',      -- JSON array of unlocked era numbers
  era_xp TEXT DEFAULT '{}',              -- JSON object: { "0": 5, "1": 12 }
  updated_at INTEGER DEFAULT (strftime('%s', 'now'))
);

-- Player inventory: stores crafted and gathered materials
CREATE TABLE IF NOT EXISTS player_inventory (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  player_name TEXT NOT NULL,
  item_type TEXT NOT NULL,
  amount INTEGER DEFAULT 1,
  UNIQUE(player_name, item_type),
  FOREIGN KEY (player_name) REFERENCES player_eras(player_name)
);

-- Craft history: log of every recipe a player has crafted
CREATE TABLE IF NOT EXISTS player_crafts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  player_name TEXT NOT NULL,
  recipe_id TEXT NOT NULL,
  crafted_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
  FOREIGN KEY (player_name) REFERENCES player_eras(player_name)
);

-- Indexes for fast lookups
CREATE INDEX IF NOT EXISTS idx_player_eras_current ON player_eras(current_era);
CREATE INDEX IF NOT EXISTS idx_player_inventory_player ON player_inventory(player_name);
CREATE INDEX IF NOT EXISTS idx_player_crafts_player ON player_crafts(player_name);
CREATE INDEX IF NOT EXISTS idx_player_crafts_recipe ON player_crafts(recipe_id);
CREATE INDEX IF NOT EXISTS idx_player_crafts_recent ON player_crafts(player_name, crafted_at DESC);
