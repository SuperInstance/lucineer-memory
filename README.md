# lucineer-memory

**Persistent key-value memory store for player profiles, build history, conversations, world state, and achievements.**

Backed by Cloudflare D1 (SQLite at the edge). Provides structured storage for the Slackwater processor's memory layer — everything the AI needs to remember about a player across sessions.

---

## Architecture

```
Python Processor ──POST /api/memory/*──▶  Worker  ──▶  D1 Database (SQLite)
                                                │
                                      ┌─────────┴──────────┐
                                      │ player_profiles     │
                                      │ build_history       │
                                      │ conversations       │
                                      │ world_state         │
                                      │ skills              │
                                      │ achievements        │
                                      └────────────────────┘
```

### Bindings

| Binding | Type | Purpose |
|---------|------|---------|
| `DB` | D1 Database | SQLite storage (`lucineer-memory`, ID `9cf282f9-...`) |
| `LUCINEER_SHARED_SECRET` | Secret | Shared-secret authentication |

### Wrangler Configuration

```jsonc
{
  "name": "lucineer-memory",
  "main": "src/index.ts",
  "compatibility_date": "2026-07-01",
  "compatibility_flags": ["nodejs_compat"],
  "d1_databases": [{
    "binding": "DB",
    "database_name": "lucineer-memory",
    "database_id": "9cf282f9-d171-43b6-9fa3-57c49122b0fe"
  }]
}
```

---

## Authentication

**Uniform shared-secret auth.** Every endpoint except health checks requires the `X-Lucineer-Key` header matching `LUCINEER_SHARED_SECRET`. Fail-closed: if the secret is unset, returns 500.

---

## Data Model

### `player_profiles`

| Column | Type | Description |
|--------|------|-------------|
| `player_name` | TEXT PRIMARY KEY | Unique player identifier |
| `preferences` | TEXT (JSON) | Serialized player preferences |
| `bond_level` | INTEGER | Relationship depth (0=stranger, increments over time) |
| `first_seen` | TIMESTAMP | First interaction |
| `last_seen` | TIMESTAMP | Most recent activity |

Upsert uses `ON CONFLICT(player_name) DO UPDATE` — preserves `bond_level` via COALESCE when not explicitly provided.

### `build_history`

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment |
| `session_id` | TEXT | Roblox session identifier |
| `player_name` | TEXT | Player who requested the build |
| `description` | TEXT | What was built |
| `command_count` | INTEGER | Number of build commands executed |
| `location` | TEXT (JSON) | Player position at build time |
| `created_at` | TIMESTAMP | When the build occurred |

Build inserts also upsert the player profile to update `last_seen`.

### `conversations`

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment |
| `session_id` | TEXT | Scoped per Roblox session |
| `player_name` | TEXT | Player who spoke |
| `role` | TEXT | `player`, `assistant`, or `system` |
| `content` | TEXT | Message content |
| `created_at` | TIMESTAMP | When the turn occurred |

The processor recalls the last **5 conversation turns** per session for brain pipeline context.

### `world_state`

| Column | Type | Description |
|--------|------|-------------|
| `session_id` | TEXT PK | Roblox session |
| `snapshot` | TEXT (JSON) | Full world state JSON |
| `updated_at` | TIMESTAMP | Last sync |

Upsert on `session_id` conflict — replaces snapshot entirely.

### `skills`

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Auto-increment |
| `name` | TEXT UNIQUE | Skill name (conflict-safe upsert) |
| `description` | TEXT | Human-readable description |
| `luau_source` | TEXT | Full Luau source code |
| `embedding_id` | TEXT | Cross-reference to Vectorize vector ID |
| `author` | TEXT | Creator (default: `lucineer`) |
| `uses_count` | INTEGER | Usage counter |
| `created_at` | TIMESTAMP | Creation time |

### `achievements`

| Column | Type | Description |
|--------|------|-------------|
| `player_name` | TEXT | Player identifier |
| `achievement_id` | TEXT | Achievement identifier |
| `unlocked_at` | INTEGER | Unix timestamp |

Composite uniqueness on `(player_name, achievement_id)` — `ON CONFLICT DO NOTHING` makes unlock idempotent.

---

## Session Scoping

Conversations are **session-scoped** — keyed by `session_id` which maps to a Roblox server instance (`{PlaceId}-{JobId}`). This means:

- **Within a session:** Full conversation recall (last N turns) is available to the brain pipeline.
- **Across sessions:** Player profiles and build history persist (keyed by `player_name`), but conversation context resets.
- **Cross-session memory:** Bond level, preferences, and build count survive session boundaries. A returning player keeps their relationship depth with Lucineer.

---

## API Reference

### Health

#### `GET /api/health` | `GET /` | `GET /health`
```json
{ "status": "ok", "service": "lucineer-memory", "time": "2026-08-02T20:58:00Z" }
```

### Player Profiles

#### `POST /api/memory/player`
Upsert player profile. Updates `preferences` and `bond_level`; sets `first_seen`/`last_seen`.

**Request:** `{ "player_name": "string", "preferences": {}, "bond_level": 0 }`

#### `GET /api/memory/player/:name`
Returns full profile row or 404.

### Build History

#### `POST /api/memory/build`
Log a build. Also upserts player profile `last_seen`.

**Request:** `{ "session_id": "...", "player_name": "...", "description": "...", "command_count": 8, "location": {"x":0,"y":0,"z":0} }`

#### `GET /api/memory/builds/:player?limit=5`
Returns recent builds for a player, ordered by `created_at DESC`. Max limit: 200.

### Skills

#### `POST /api/memory/skill`
Upsert a skill in D1 (separate from Vectorize embeddings). Conflict-safe on `name`.

#### `GET /api/memory/skills/search?q=castle&limit=20`
Keyword search across `name` and `description` using `LIKE %query%`. Ordered by `uses_count DESC`.

#### `GET /api/memory/skills/:idOrName`
Fetch full skill record including `luau_source`. Accepts numeric ID or exact name.

### Conversations

#### `POST /api/memory/conversation`
Log a conversation turn.

**Request:** `{ "session_id": "...", "player_name": "...", "role": "player|assistant|system", "content": "..." }`

#### `GET /api/memory/conversations/:session_id?limit=5`
Returns conversation turns for a session, ordered chronologically (`ASC`). Max limit: 500.

### World State

#### `POST /api/memory/world-state`
Upsert world state snapshot for a session.

#### `GET /api/memory/world-state/:session_id`
Returns stored snapshot or 404.

### Achievements

#### `POST /api/achievements/unlock`
Record an achievement unlock. Idempotent via `ON CONFLICT DO NOTHING`.

#### `GET /api/achievements/:player`
Returns all achievements for a player, ordered by `unlocked_at ASC`.

---

## Processor Integration

The `process_v2.py` processor integrates with this service in three phases per job:

```
1. RECALL   → GET player profile, recent builds, recent conversations
              → Construct context string for brain pipeline

2. PROCESS  → Run template match or brain.py with memory context
              → Apply Nemotron content safety check

3. PERSIST  → POST player profile (upsert last_seen)
              → POST build history (description, command count)
              → POST conversation turns (player message + assistant reply)
```

The recall phase provides the brain with:
- Bond level (affects Lucineer's warmth and familiarity)
- Player preferences
- Last 3 build descriptions
- Last 5 conversation turns (player + assistant, truncated to 120 chars)

---

## File Layout

```
src/
└── index.ts        # Worker: router, auth middleware, all D1 queries
wrangler.jsonc      # Cloudflare Workers + D1 configuration
```

---

## Production

**URL:** `https://lucineer-memory.casey-digennaro.workers.dev`

```bash
npx wrangler d1 create lucineer-memory
npx wrangler d1 execute lucineer-memory --file=schema.sql
npx wrangler deploy
npx wrangler secret put LUCINEER_SHARED_SECRET
```

---

## Related Repositories

| Repository | Role |
|-----------|------|
| [lucineer-worker](../lucineer-worker) | Job relay, hosts the processor daemon |
| [lucineer-vector](../lucineer-vector) | Semantic skill search (Vectorize) |
| [lucineer-brain](../lucineer-brain) | Multi-model pipeline consuming memory context |
| [lucineer-roblox](../lucineer-roblox) | Roblox client (indirect consumer via processor) |

---

## License

MIT
