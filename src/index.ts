/**
 * Lucineer Persistent Memory System - Worker API
 * 
 * Provides REST endpoints for player profiles, build history,
 * skills library, conversations, and world state.
 */

export interface Env {
  DB: D1Database;
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

    // Health check
    if (path === "/" || path === "/health") {
      return json({ status: "ok", service: "lucineer-memory", time: new Date().toISOString() });
    }

    try {
      // ─── Player Profiles ───────────────────────────────
      // POST /api/memory/player — update/create player profile
      if (path === "/api/memory/player" && method === "POST") {
        const body = await parseBody(request);
        const playerName = String(body.player_name || "");
        if (!playerName) return error("player_name is required");

        const preferences = JSON.stringify(body.preferences || {});
        const bondLevel = Number(body.bond_level ?? 0);

        await env.DB.prepare(
          `INSERT INTO player_profiles (player_name, preferences, bond_level, first_seen, last_seen)
           VALUES (?, ?, ?, datetime('now'), datetime('now'))
           ON CONFLICT(player_name) DO UPDATE SET
             preferences = excluded.preferences,
             bond_level = excluded.bond_level,
             last_seen = datetime('now')`
        ).bind(playerName, preferences, bondLevel).run();

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

      // ─── 404 ───────────────────────────────────────────
      return error("Not found", 404);

    } catch (err) {
      const message = err instanceof Error ? err.message : "Unknown error";
      return error(message, 500);
    }
  },
};
