/**
 * Lucineer Persistent Memory System — Worker API
 *
 * Provides REST endpoints for player profiles, build history,
 * skills library, conversations, and world state.
 *
 * Phase 1 Day 1: Uniform shared-secret auth. Every endpoint except
 * /api/health requires X-Lucineer-Key matching LUCINEER_SHARED_SECRET.
 */

export interface Env {
  DB: D1Database;
  /** R2 bucket for large save data (build snapshots, terrain, legacy builds). */
  SAVES: R2Bucket;
  /** Shared secret — must match X-Lucineer-Key header on all non-health routes. */
  LUCINEER_SHARED_SECRET: string;
}

// ─── Helpers ──────────────────────────────────────────────

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function error(message: string, status = 400): Response {
  return json({ error: message }, status);
}

// ─── Auth Middleware ─────────────────────────────────────

/**
 * Uniform auth check: every non-health endpoint must pass through this.
 * Reads X-Lucineer-Key header and compares to LUCINEER_SHARED_SECRET.
 * Returns null if authorized, or a 401 Response if not.
 */
function requireAuth(request: Request, env: Env): Response | null {
  const key = request.headers.get("X-Lucineer-Key");
  const expected = env.LUCINEER_SHARED_SECRET;
  if (!expected) {
    // Fail-closed: if the secret isn't configured, nothing works.
    return json({ error: "Server misconfigured: LUCINEER_SHARED_SECRET not set" }, 500);
  }
  if (!key || key !== expected) {
    return json({ error: "Unauthorized" }, 401);
  }
  return null; // authorized
}

async function parseBody(request: Request): Promise<Record<string, unknown>> {
  try {
    return await request.json() as Record<string, unknown>;
  } catch {
    throw new Error("Invalid JSON body");
  }
}

// ─── Router ───────────────────────────────────────────────

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;

    // ─── Health check — the ONLY endpoint that skips auth ───
    if (path === "/api/health" && method === "GET") {
      return json({
        status: "ok",
        service: "lucineer-memory",
        time: new Date().toISOString(),
      });
    }

    // Also accept legacy health paths
    if ((path === "/" || path === "/health") && method === "GET") {
      return json({
        status: "ok",
        service: "lucineer-memory",
        time: new Date().toISOString(),
      });
    }

    // ─── Auth gate — every endpoint below requires the shared secret ───
    const authFailure = requireAuth(request, env);
    if (authFailure) return authFailure;

    try {
      // ─── Player Profiles ───────────────────────────────
      // POST /api/memory/player — update/create player profile
      if (path === "/api/memory/player" && method === "POST") {
        const body = await parseBody(request);
        const playerName = String(body.player_name || "");
        if (!playerName) return error("player_name is required");

        const preferences = JSON.stringify(body.preferences || {});
        // COALESCE: if bond_level is null/undefined, preserve existing value.
        // This fixes the bug where omitting bond_level silently reset it to 0.
        const bondLevelRaw = body.bond_level;
        const bondLevel = bondLevelRaw === undefined || bondLevelRaw === null
          ? null
          : Number(bondLevelRaw);

        await env.DB.prepare(
          `INSERT INTO player_profiles (player_name, preferences, bond_level, first_seen, last_seen)
           VALUES (?, ?, ?, datetime('now'), datetime('now'))
           ON CONFLICT(player_name) DO UPDATE SET
             preferences = excluded.preferences,
             bond_level = COALESCE(?, player_profiles.bond_level),
             last_seen = datetime('now')`
        ).bind(playerName, preferences, bondLevel, bondLevel).run();

        return json({ success: true, player_name: playerName });
      }

      // GET /api/memory/player/:name — get player profile
      if (path.startsWith("/api/memory/player/") && method === "GET") {
        const playerName = decodeURIComponent(path.split("/api/memory/player/")[1]);
        if (!playerName) return error("player name is required");

        const result = await env.DB.prepare(
          `SELECT * FROM player_profiles WHERE player_name = ?`
        ).bind(playerName).first();

        if (!result) return error("player not found", 404);
        return json(result);
      }

      // ─── Build History ─────────────────────────────────
      // POST /api/memory/build — log a build
      if (path === "/api/memory/build" && method === "POST") {
        const body = await parseBody(request);
        const sessionId = String(body.session_id || "");
        const playerName = String(body.player_name || "");
        if (!sessionId || !playerName) return error("session_id and player_name are required");

        const description = String(body.description || "");
        const commandCount = Number(body.command_count ?? 0);
        const location = JSON.stringify(body.location || {});

        const result = await env.DB.prepare(
          `INSERT INTO build_history (session_id, player_name, description, command_count, location, created_at)
           VALUES (?, ?, ?, ?, ?, datetime('now'))
           RETURNING id`
        ).bind(sessionId, playerName, description, commandCount, location).first();

        // Update player's last_seen
        await env.DB.prepare(
          `INSERT INTO player_profiles (player_name, first_seen, last_seen)
           VALUES (?, datetime('now'), datetime('now'))
           ON CONFLICT(player_name) DO UPDATE SET last_seen = datetime('now')`
        ).bind(playerName).run();

        return json({ success: true, id: result?.id });
      }

      // GET /api/memory/builds/:player — get player's build history
      if (path.startsWith("/api/memory/builds/") && method === "GET") {
        const playerName = decodeURIComponent(path.split("/api/memory/builds/")[1]);
        if (!playerName) return error("player name is required");

        const limit = Math.min(Number(url.searchParams.get("limit") || 50), 200);
        const results = await env.DB.prepare(
          `SELECT * FROM build_history WHERE player_name = ? ORDER BY created_at DESC LIMIT ?`
        ).bind(playerName, limit).all();

        return json({ builds: results.results });
      }

      // ─── Skills ────────────────────────────────────────
      // POST /api/memory/skill — save a new skill
      if (path === "/api/memory/skill" && method === "POST") {
        const body = await parseBody(request);
        const name = String(body.name || "");
        if (!name) return error("skill name is required");

        const description = String(body.description || "");
        const luauSource = String(body.luau_source || "");
        const embeddingId = String(body.embedding_id || "");
        const author = String(body.author || "lucineer");

        const result = await env.DB.prepare(
          `INSERT INTO skills (name, description, luau_source, embedding_id, author, uses_count, created_at)
           VALUES (?, ?, ?, ?, ?, 0, datetime('now'))
           ON CONFLICT(name) DO UPDATE SET
             description = excluded.description,
             luau_source = excluded.luau_source,
             embedding_id = excluded.embedding_id
           RETURNING id`
        ).bind(name, description, luauSource, embeddingId, author).first();

        return json({ success: true, id: result?.id, name });
      }

      // GET /api/memory/skills/search?q= — search skills by keyword
      if (path === "/api/memory/skills/search" && method === "GET") {
        const q = url.searchParams.get("q") || "";
        const limit = Math.min(Number(url.searchParams.get("limit") || 20), 100);

        let results;
        if (q) {
          results = await env.DB.prepare(
            `SELECT id, name, description, author, uses_count, created_at 
             FROM skills 
             WHERE name LIKE ? OR description LIKE ?
             ORDER BY uses_count DESC, created_at DESC
             LIMIT ?`
          ).bind(`%${q}%`, `%${q}%`, limit).all();
        } else {
          results = await env.DB.prepare(
            `SELECT id, name, description, author, uses_count, created_at 
             FROM skills 
             ORDER BY uses_count DESC, created_at DESC 
             LIMIT ?`
          ).bind(limit).all();
        }

        return json({ skills: results.results });
      }

      // GET /api/memory/skills/:id — get full skill with source
      if (path.startsWith("/api/memory/skills/") && !path.includes("/search") && method === "GET") {
        const idOrName = decodeURIComponent(path.split("/api/memory/skills/")[1]);
        const result = await env.DB.prepare(
          `SELECT * FROM skills WHERE id = ? OR name = ?`
        ).bind(isNaN(Number(idOrName)) ? 0 : Number(idOrName), idOrName).first();

        if (!result) return error("skill not found", 404);
        return json(result);
      }

      // ─── Conversations ─────────────────────────────────
      // POST /api/memory/conversation — log a conversation turn
      if (path === "/api/memory/conversation" && method === "POST") {
        const body = await parseBody(request);
        const sessionId = String(body.session_id || "");
        const playerName = String(body.player_name || "");
        const role = String(body.role || "");
        const content = String(body.content || "");

        if (!sessionId || !playerName || !role || !content) {
          return error("session_id, player_name, role, and content are required");
        }
        if (!["player", "assistant", "system"].includes(role)) {
          return error("role must be 'player', 'assistant', or 'system'");
        }

        const result = await env.DB.prepare(
          `INSERT INTO conversations (session_id, player_name, role, content, created_at)
           VALUES (?, ?, ?, ?, datetime('now'))
           RETURNING id`
        ).bind(sessionId, playerName, role, content).first();

        return json({ success: true, id: result?.id });
      }

      // GET /api/memory/conversations/:session — get session history
      if (path.startsWith("/api/memory/conversations/") && method === "GET") {
        const sessionId = decodeURIComponent(path.split("/api/memory/conversations/")[1]);
        if (!sessionId) return error("session id is required");

        const limit = Math.min(Number(url.searchParams.get("limit") || 100), 500);
        const results = await env.DB.prepare(
          `SELECT * FROM conversations WHERE session_id = ? ORDER BY created_at ASC LIMIT ?`
        ).bind(sessionId, limit).all();

        return json({ conversations: results.results });
      }

      // ─── World State ───────────────────────────────────
      // POST /api/memory/world-state — update world state snapshot
      if (path === "/api/memory/world-state" && method === "POST") {
        const body = await parseBody(request);
        const sessionId = String(body.session_id || "");
        if (!sessionId) return error("session_id is required");

        const snapshot = JSON.stringify(body.snapshot || {});

        await env.DB.prepare(
          `INSERT INTO world_state (session_id, snapshot, updated_at)
           VALUES (?, ?, datetime('now'))
           ON CONFLICT(session_id) DO UPDATE SET
             snapshot = excluded.snapshot,
             updated_at = datetime('now')`
        ).bind(sessionId, snapshot).run();

        return json({ success: true, session_id: sessionId });
      }

      // GET /api/memory/world-state/:session — get world state
      if (path.startsWith("/api/memory/world-state/") && method === "GET") {
        const sessionId = decodeURIComponent(path.split("/api/memory/world-state/")[1]);
        if (!sessionId) return error("session id is required");

        const result = await env.DB.prepare(
          `SELECT * FROM world_state WHERE session_id = ?`
        ).bind(sessionId).first();

        if (!result) return error("world state not found", 404);
        return json(result);
      }

      // ─── Achievements ─────────────────────────────────
      // POST /api/achievements/unlock — record an achievement unlock
      if (path === "/api/achievements/unlock" && method === "POST") {
        const body = await parseBody(request);
        const playerName = String(body.player_name || "");
        const achievementId = String(body.achievement_id || "");
        if (!playerName || !achievementId) {
          return error("player_name and achievement_id are required");
        }
        const unlockedAt = Number(body.unlocked_at ?? Math.floor(Date.now() / 1000));

        try {
          await env.DB.prepare(
            `INSERT INTO achievements (player_name, achievement_id, unlocked_at)
             VALUES (?, ?, ?)
             ON CONFLICT(player_name, achievement_id) DO NOTHING`
          ).bind(playerName, achievementId, unlockedAt).run();
          return json({ success: true, player_name: playerName, achievement_id: achievementId });
        } catch (err) {
          const message = err instanceof Error ? err.message : "Unknown error";
          if (message.includes("no such table")) {
            return error("Achievements table not created. Run schema-achievements.sql.", 500);
          }
          return error(message, 500);
        }
      }

      // GET /api/achievements/:player — get all achievements for a player
      if (path.startsWith("/api/achievements/") && method === "GET") {
        const playerName = decodeURIComponent(path.split("/api/achievements/")[1]);
        if (!playerName) return error("player name is required");

        try {
          const results = await env.DB.prepare(
            `SELECT achievement_id, unlocked_at FROM achievements WHERE player_name = ? ORDER BY unlocked_at ASC`
          ).bind(playerName).all();

          return json({ achievements: results.results || [] });
        } catch (err) {
          const message = err instanceof Error ? err.message : "Unknown error";
          if (message.includes("no such table")) {
            return json({ achievements: [] });
          }
          return error(message, 500);
        }
      }

      // ─── Save System: R2 Build Snapshots ──────────────

      // POST /api/save/r2/:playerName — save build snapshot to R2
      if (path.startsWith("/api/save/r2/") && method === "POST") {
        const r2Key = decodeURIComponent(path.split("/api/save/r2/")[1]);
        if (!r2Key) return error("R2 key (playerName or path) is required");

        const body = await parseBody(request);
        // Accept base64-encoded snapshot in "data" or "save_data"
        const data = String(body.data || body.save_data || "");
        if (!data) return error("data (base64-encoded snapshot) is required");

        await env.SAVES.put(r2Key, data);
        return json({ success: true, key: r2Key });
      }

      // GET /api/save/r2/:playerName — load build snapshot from R2
      if (path.startsWith("/api/save/r2/") && method === "GET") {
        const r2Key = decodeURIComponent(path.split("/api/save/r2/")[1]);
        if (!r2Key) return error("R2 key (playerName or path) is required");

        const object = await env.SAVES.get(r2Key);
        if (!object) return error("not found", 404);
        const text = await object.text();
        return json({ data: text, key: r2Key });
      }

      // ─── Save System: D1 Key-Value Store ───────────────

      // POST /api/save/d1/:playerName/:key — upsert a save value
      if (path.startsWith("/api/save/d1/") && method === "POST") {
        const parts = path.split("/api/save/d1/")[1].split("/");
        const playerName = decodeURIComponent(parts[0] || "");
        const saveKey = parts[1] || "";
        if (!playerName || !saveKey) return error("playerName and key are required");

        const body = await parseBody(request);
        const saveData = String(body.save_data ?? body.data ?? "");
        if (!saveData) return error("save_data is required");

        await env.DB.prepare(
          `INSERT INTO player_saves (player_name, save_key, save_data, updated_at)
           VALUES (?, ?, ?, ?)
           ON CONFLICT(player_name, save_key) DO UPDATE SET
             save_data = excluded.save_data,
             updated_at = excluded.updated_at`
        ).bind(playerName, saveKey, saveData, Math.floor(Date.now() / 1000)).run();

        return json({ success: true, player_name: playerName, key: saveKey });
      }

      // GET /api/save/d1/:playerName/all — batch load all saves for a player
      if (path.match(/^\/api\/save\/d1\/[^/]+\/all$/) && method === "GET") {
        const playerName = decodeURIComponent(
          path.split("/api/save/d1/")[1].replace(/\/all$/, "")
        );
        if (!playerName) return error("player name is required");

        const results = await env.DB.prepare(
          `SELECT save_key, save_data, updated_at FROM player_saves WHERE player_name = ?`
        ).bind(playerName).all();

        return json({ saves: results.results || [] });
      }

      // GET /api/save/d1/:playerName/:key — read a specific save value
      if (path.startsWith("/api/save/d1/") && method === "GET") {
        const parts = path.split("/api/save/d1/")[1].split("/");
        const playerName = decodeURIComponent(parts[0] || "");
        const saveKey = parts[1] || "";
        if (!playerName || !saveKey) return error("playerName and key are required");

        const result = await env.DB.prepare(
          `SELECT save_data FROM player_saves WHERE player_name = ? AND save_key = ?`
        ).bind(playerName, saveKey).first();

        if (!result) return error("not found", 404);
        return json({ save_data: result.save_data, player_name: playerName, key: saveKey });
      }

      // ─── Era Progression ───────────────────────────────

      // GET /api/era/:playerName — load era progression data
      if (path.startsWith("/api/era/") && method === "GET") {
        const playerName = decodeURIComponent(path.split("/api/era/")[1]);
        if (!playerName) return error("player name is required");

        // Try the dedicated player_eras table first
        let eraResult;
        try {
          eraResult = await env.DB.prepare(
            `SELECT current_era, unlocked_eras, era_xp, updated_at
             FROM player_eras WHERE player_name = ?`
          ).bind(playerName).first();
        } catch {
          // player_eras table might not exist yet — fall back to player_saves
        }

        if (eraResult) {
          return json({
            player_name: playerName,
            current_era: eraResult.current_era,
            unlocked_eras: eraResult.unlocked_eras
              ? JSON.parse(eraResult.unlocked_eras as string)
              : [0],
            era_xp: eraResult.era_xp
              ? JSON.parse(eraResult.era_xp as string)
              : {},
            updated_at: eraResult.updated_at,
          });
        }

        // Fallback: check player_saves for an era key
        const saveResult = await env.DB.prepare(
          `SELECT save_data FROM player_saves WHERE player_name = ? AND save_key = 'era'`
        ).bind(playerName).first();

        if (saveResult) {
          const eraData = JSON.parse(saveResult.save_data as string);
          return json({
            player_name: playerName,
            ...eraData,
          });
        }

        // Default: era 0, nothing unlocked beyond starting era
        return json({
          player_name: playerName,
          current_era: 0,
          unlocked_eras: [0],
          era_xp: {},
        });
      }

      // POST /api/era/:playerName — save era progression data
      if (path.startsWith("/api/era/") && method === "POST") {
        const playerName = decodeURIComponent(path.split("/api/era/")[1]);
        if (!playerName) return error("player name is required");

        const body = await parseBody(request);
        const currentEra = Number(body.current_era ?? 0);
        const unlockedEras = JSON.stringify(body.unlocked_eras ?? [0]);
        const eraXp = JSON.stringify(body.era_xp ?? {});
        const now = Math.floor(Date.now() / 1000);

        // Try player_eras table first
        try {
          await env.DB.prepare(
            `INSERT INTO player_eras (player_name, current_era, unlocked_eras, era_xp, updated_at)
             VALUES (?, ?, ?, ?, ?)
             ON CONFLICT(player_name) DO UPDATE SET
               current_era = excluded.current_era,
               unlocked_eras = excluded.unlocked_eras,
               era_xp = excluded.era_xp,
               updated_at = excluded.updated_at`
          ).bind(playerName, currentEra, unlockedEras, eraXp, now).run();
          return json({ success: true, player_name: playerName });
        } catch {
          // player_eras table might not exist — fall back to player_saves
        }

        // Fallback: store as a player_saves entry
        const eraData = JSON.stringify({
          current_era: currentEra,
          unlocked_eras: body.unlocked_eras ?? [0],
          era_xp: body.era_xp ?? {},
        });

        await env.DB.prepare(
          `INSERT INTO player_saves (player_name, save_key, save_data, updated_at)
           VALUES (?, 'era', ?, ?)
           ON CONFLICT(player_name, save_key) DO UPDATE SET
             save_data = excluded.save_data,
             updated_at = excluded.updated_at`
        ).bind(playerName, eraData, now).run();

        return json({ success: true, player_name: playerName });
      }

      // ─── 404 ───────────────────────────────────────────
      return error("Not found", 404);

    } catch (err) {
      const message = err instanceof Error ? err.message : "Unknown error";
      // parseBody errors are client errors (400), not server errors (500)
      const status = message.includes("Invalid JSON") ? 400 : 500;
      return error(message, status);
    }
  },
};
