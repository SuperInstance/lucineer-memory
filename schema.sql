-- Lucineer Persistent Memory System - D1 Schema
-- Created: 2026-08-01

-- Player profiles: tracks per-player preferences, bond level, activity
CREATE TABLE IF NOT EXISTS player_profiles (
  player_name TEXT PRIMARY KEY,
  preferences TEXT DEFAULT '{}',  -- JSON blob of player preferences
  bond_level INTEGER DEFAULT 0,
  first_seen TEXT DEFAULT (datetime('now')),
  last_seen TEXT DEFAULT (datetime('now'))
);

-- Build history: records every build/command sequence performed
CREATE TABLE IF NOT EXISTS build_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  player_name TEXT NOT NULL,
  description TEXT,
  command_count INTEGER DEFAULT 0,
  location TEXT DEFAULT '{}',  -- JSON blob of build coordinates/region
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (player_name) REFERENCES player_profiles(player_name)
);

-- Skills: reusable Luau scripts authored by Lucineer or players
CREATE TABLE IF NOT EXISTS skills (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  description TEXT,
  luau_source TEXT,
  embedding_id TEXT,  -- Reference to Vectorize embedding if available
  author TEXT DEFAULT 'lucineer',
  uses_count INTEGER DEFAULT 0,
  created_at TEXT DEFAULT (datetime('now'))
);

-- Conversations: chat history for context and continuity
CREATE TABLE IF NOT EXISTS conversations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  player_name TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('player', 'assistant', 'system')),
  content TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now'))
);

-- World state: snapshots of the Roblox world per session
CREATE TABLE IF NOT EXISTS world_state (
  session_id TEXT PRIMARY KEY,
  snapshot TEXT DEFAULT '{}',  -- JSON blob of world state
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Indexes for fast lookups
CREATE INDEX IF NOT EXISTS idx_build_history_player ON build_history(player_name);
CREATE INDEX IF NOT EXISTS idx_build_history_session ON build_history(session_id);
CREATE INDEX IF NOT EXISTS idx_build_history_created ON build_history(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_conversations_session ON conversations(session_id);
CREATE INDEX IF NOT EXISTS idx_conversations_player ON conversations(player_name);
CREATE INDEX IF NOT EXISTS idx_conversations_created ON conversations(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_skills_name ON skills(name);
CREATE INDEX IF NOT EXISTS idx_skills_uses ON skills(uses_count DESC);
