/**
 * Tests for lucineer-memory — Persistent key-value memory store
 *
 * Tests routing, auth, validation, and response shapes for all endpoints.
 * Uses mock D1Database and R2Bucket.
 */

import { describe, it, expect, vi } from 'vitest';

// ─── Mock D1Database ───────────────────────────────────

function makeMockD1(overrides: Record<string, unknown> = {}) {
  const _store: Record<string, Record<string, unknown>[]> = {};
  
  return {
    prepare: vi.fn((sql: string) => {
      let _bindings: unknown[] = [];
      const stmt = {
        bind: vi.fn((...args: unknown[]) => { _bindings = args; return stmt; }),
        run: vi.fn(async () => {
          if (overrides._throwOnRun) throw new Error(overrides._throwOnRun as string);
          return { success: true, meta: {} };
        }),
        first: vi.fn(async () => {
          if (overrides._throwOnFirst) throw new Error(overrides._throwOnFirst as string);
          return overrides._firstResult ?? null;
        }),
        all: vi.fn(async () => ({
          results: overrides._allResults ?? [],
          success: true,
          meta: {},
        })),
      };
      return stmt;
    }),
  };
}

function makeMockR2() {
  const _objects: Record<string, string> = {};
  return {
    put: vi.fn(async (key: string, value: string) => { _objects[key] = value; }),
    get: vi.fn(async (key: string) => {
      if (!_objects[key]) return null;
      return {
        text: async () => _objects[key],
      };
    }),
  };
}

function makeMockEnv(overrides: Record<string, unknown> = {}) {
  return {
    DB: makeMockD1(overrides),
    SAVES: makeMockR2(),
    LUCINEER_SHARED_SECRET: 'test-secret',
    ...overrides,
  };
}

function makeRequest(
  method: string,
  path: string,
  body?: unknown,
  headers: Record<string, string> = {}
): Request {
  const url = `https://test.example.com${path}`;
  const init: RequestInit = { method, headers };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers = { 'Content-Type': 'application/json', ...headers };
  }
  return new Request(url, init);
}

const worker = await import('../src/index.ts');

// ─── Tests ─────────────────────────────────────────────

describe('lucineer-memory worker', () => {

  // ─── Health ──────────────────────────────────────────

  describe('GET /api/health', () => {
    it('returns ok status without auth', async () => {
      const req = makeRequest('GET', '/api/health');
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.status).toBe('ok');
      expect(data.service).toBe('lucineer-memory');
    });

    it('also responds at / and /health', async () => {
      for (const path of ['/', '/health']) {
        const req = makeRequest('GET', path);
        const res = await worker.default.fetch(req, makeMockEnv() as any);
        expect(res.status).toBe(200);
        const data = await res.json();
        expect(data.service).toBe('lucineer-memory');
      }
    });
  });

  // ─── Auth ────────────────────────────────────────────

  describe('Authentication', () => {
    it('rejects requests without key', async () => {
      const req = makeRequest('POST', '/api/memory/player', { player_name: 'test' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(401);
    });

    it('rejects wrong key', async () => {
      const req = makeRequest('POST', '/api/memory/player', { player_name: 'test' }, {
        'X-Lucineer-Key': 'wrong',
      });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(401);
    });

    it('returns 500 when secret not set', async () => {
      const req = makeRequest('POST', '/api/memory/player', { player_name: 'test' }, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, makeMockEnv({ LUCINEER_SHARED_SECRET: '' }) as any);
      
      expect(res.status).toBe(500);
    });
  });

  // ─── Player Profiles ─────────────────────────────────

  describe('POST /api/memory/player', () => {
    it('creates/updates a player profile', async () => {
      const req = makeRequest('POST', '/api/memory/player', {
        player_name: 'Alice',
        preferences: { theme: 'dark' },
        bond_level: 3,
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.success).toBe(true);
      expect(data.player_name).toBe('Alice');
    });

    it('rejects empty player_name', async () => {
      const req = makeRequest('POST', '/api/memory/player', {}, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(400);
    });

    it('handles null bond_level (preserves existing via COALESCE)', async () => {
      const req = makeRequest('POST', '/api/memory/player', {
        player_name: 'Alice',
        bond_level: null,
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(200);
    });
  });

  describe('GET /api/memory/player/:name', () => {
    it('returns player profile when found', async () => {
      const env = makeMockEnv({ _firstResult: { player_name: 'Alice', bond_level: 3 } });
      const req = makeRequest('GET', '/api/memory/player/Alice', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.player_name).toBe('Alice');
    });

    it('returns 404 when player not found', async () => {
      const req = makeRequest('GET', '/api/memory/player/Ghost', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(404);
    });
  });

  // ─── Build History ───────────────────────────────────

  describe('POST /api/memory/build', () => {
    it('logs a build', async () => {
      const env = makeMockEnv({ _firstResult: { id: 42 } });
      const req = makeRequest('POST', '/api/memory/build', {
        session_id: 'sess-1',
        player_name: 'Alice',
        description: 'Built a castle',
        command_count: 15,
        location: { x: 100, y: 200 },
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.success).toBe(true);
      expect(data.id).toBe(42);
    });

    it('rejects missing session_id', async () => {
      const req = makeRequest('POST', '/api/memory/build', {
        player_name: 'Alice',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(400);
    });

    it('rejects missing player_name', async () => {
      const req = makeRequest('POST', '/api/memory/build', {
        session_id: 'sess-1',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(400);
    });
  });

  describe('GET /api/memory/builds/:player', () => {
    it('returns build history', async () => {
      const env = makeMockEnv({
        _allResults: [{ id: 1, player_name: 'Alice', description: 'Castle' }],
      });
      const req = makeRequest('GET', '/api/memory/builds/Alice', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.builds).toHaveLength(1);
    });
  });

  // ─── Skills ──────────────────────────────────────────

  describe('POST /api/memory/skill', () => {
    it('saves a new skill', async () => {
      const env = makeMockEnv({ _firstResult: { id: 1 } });
      const req = makeRequest('POST', '/api/memory/skill', {
        name: 'Wall Build',
        description: 'Builds a wall',
        luau_source: 'code here',
        embedding_id: 'skill-wall-build',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.success).toBe(true);
      expect(data.name).toBe('Wall Build');
    });

    it('rejects skill without name', async () => {
      const req = makeRequest('POST', '/api/memory/skill', {
        description: 'test',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(400);
    });
  });

  describe('GET /api/memory/skills/search', () => {
    it('searches skills by keyword', async () => {
      const env = makeMockEnv({
        _allResults: [{ id: 1, name: 'Wall Build', uses_count: 5 }],
      });
      const req = makeRequest('GET', '/api/memory/skills/search?q=wall', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.skills).toHaveLength(1);
    });

    it('returns all skills when no query', async () => {
      const env = makeMockEnv({
        _allResults: [{ id: 1, name: 'Wall Build' }, { id: 2, name: 'Tower Build' }],
      });
      const req = makeRequest('GET', '/api/memory/skills/search', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.skills).toHaveLength(2);
    });
  });

  // ─── Conversations ───────────────────────────────────

  describe('POST /api/memory/conversation', () => {
    it('logs a conversation turn', async () => {
      const env = makeMockEnv({ _firstResult: { id: 99 } });
      const req = makeRequest('POST', '/api/memory/conversation', {
        session_id: 'sess-1',
        player_name: 'Alice',
        role: 'player',
        content: 'Build me a house',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.success).toBe(true);
      expect(data.id).toBe(99);
    });

    it('rejects invalid role', async () => {
      const req = makeRequest('POST', '/api/memory/conversation', {
        session_id: 'sess-1',
        player_name: 'Alice',
        role: 'invalid',
        content: 'test',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(400);
    });

    it('rejects missing fields', async () => {
      const req = makeRequest('POST', '/api/memory/conversation', {
        session_id: 'sess-1',
        role: 'player',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(400);
    });
  });

  // ─── World State ─────────────────────────────────────

  describe('POST /api/memory/world-state', () => {
    it('updates world state', async () => {
      const req = makeRequest('POST', '/api/memory/world-state', {
        session_id: 'sess-1',
        snapshot: { weather: 'rainy', time: 'night' },
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.success).toBe(true);
    });

    it('rejects missing session_id', async () => {
      const req = makeRequest('POST', '/api/memory/world-state', {}, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(400);
    });
  });

  // ─── Achievements ────────────────────────────────────

  describe('POST /api/achievements/unlock', () => {
    it('unlocks an achievement', async () => {
      const req = makeRequest('POST', '/api/achievements/unlock', {
        player_name: 'Alice',
        achievement_id: 'first_build',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.success).toBe(true);
    });

    it('rejects missing player_name', async () => {
      const req = makeRequest('POST', '/api/achievements/unlock', {
        achievement_id: 'first_build',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(400);
    });
  });

  describe('GET /api/achievements/:player', () => {
    it('returns player achievements', async () => {
      const env = makeMockEnv({
        _allResults: [{ achievement_id: 'first_build', unlocked_at: 1700000000 }],
      });
      const req = makeRequest('GET', '/api/achievements/Alice', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.achievements).toHaveLength(1);
    });

    it('returns empty array on missing table', async () => {
      const env = makeMockEnv({ _throwOnRun: 'no such table: achievements' });
      const req = makeRequest('GET', '/api/achievements/Alice', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.achievements).toEqual([]);
    });
  });

  // ─── R2 Save System ──────────────────────────────────

  describe('R2 Save System', () => {
    it('saves snapshot to R2', async () => {
      const req = makeRequest('POST', '/api/save/r2/Alice', {
        data: 'base64encodeddata',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.success).toBe(true);
      expect(data.key).toBe('Alice');
    });

    it('loads snapshot from R2', async () => {
      // First put an object
      const env = makeMockEnv();
      await env.SAVES.put('Alice', 'base64data');
      
      const req = makeRequest('GET', '/api/save/r2/Alice', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.key).toBe('Alice');
    });

    it('returns 404 for missing R2 object', async () => {
      const req = makeRequest('GET', '/api/save/r2/Nonexistent', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(404);
    });
  });

  // ─── D1 Save System ──────────────────────────────────

  describe('D1 Save System', () => {
    it('saves to D1', async () => {
      const req = makeRequest('POST', '/api/save/d1/Alice/slot1', {
        save_data: 'my-save-data',
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.success).toBe(true);
    });

    it('loads all saves for a player', async () => {
      const env = makeMockEnv({
        _allResults: [{ save_key: 'slot1', save_data: 'data1', updated_at: 123 }],
      });
      const req = makeRequest('GET', '/api/save/d1/Alice/all', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.saves).toHaveLength(1);
    });

    it('loads specific save', async () => {
      const env = makeMockEnv({
        _firstResult: { save_data: 'data1' },
      });
      const req = makeRequest('GET', '/api/save/d1/Alice/slot1', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, env as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.save_data).toBe('data1');
    });
  });

  // ─── Era Progression ─────────────────────────────────

  describe('Era Progression', () => {
    it('GET returns default era 0 when no data', async () => {
      const req = makeRequest('GET', '/api/era/Alice', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.current_era).toBe(0);
      expect(data.unlocked_eras).toEqual([0]);
    });

    it('POST saves era progression', async () => {
      const req = makeRequest('POST', '/api/era/Alice', {
        current_era: 2,
        unlocked_eras: [0, 1, 2],
        era_xp: { 0: 100, 1: 50 },
      }, { 'X-Lucineer-Key': 'test-secret' });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      const data = await res.json();
      
      expect(res.status).toBe(200);
      expect(data.success).toBe(true);
    });
  });

  // ─── Invalid JSON ────────────────────────────────────

  describe('Error handling', () => {
    it('returns 400 for invalid JSON body', async () => {
      const req = new Request('https://test.example.com/api/memory/player', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Lucineer-Key': 'test-secret' },
        body: 'not json at all {{{',
      });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(400);
    });

    it('returns 404 for unknown paths', async () => {
      const req = makeRequest('GET', '/api/unknown', undefined, {
        'X-Lucineer-Key': 'test-secret',
      });
      const res = await worker.default.fetch(req, makeMockEnv() as any);
      
      expect(res.status).toBe(404);
    });
  });
});
