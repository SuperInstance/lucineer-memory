# 🧠 Lucineer Memory

Persistent memory system powered by Cloudflare D1.

**Worker:** https://lucineer-memory.casey-digennaro.workers.dev
**Database ID:** 9cf282f9-d171-43b6-9fa3-57c49122b0fe

## API

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | /api/memory/player | Update player profile |
| GET | /api/memory/player/:name | Get player profile |
| POST | /api/memory/build | Log a build |
| GET | /api/memory/builds/:player | Player's build history |
| POST | /api/memory/skill | Save a skill |
| GET | /api/memory/skills/search?q= | Search skills |
| POST | /api/memory/conversation | Log conversation |
| GET | /api/memory/conversations/:session | Session history |

Part of the [Lucineer system](https://github.com/SuperInstance/lucineer-system).
