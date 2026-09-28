# MindDock

**Remember the meeting. Skip the meeting bot.**

MindDock is a small personal meeting memory for conversations captured on your Mac. The idea: a simpler, bot-free alternative to Granola, Fathom, and similar tools. Keep the useful context from each conversation without adding another participant to the call.

## What it does

- Keeps a profile for each person, including company, role, links, and research notes.
- Saves meetings with full transcripts and optional summaries.
- Tracks action items and whether they belong to you or the other person.
- Searches people and past conversations by name, company, summary, or transcript text.
- Exposes a small authenticated API with an [OpenAPI schema](./openapi.json).

MindDock is currently the backend. A macOS recorder can send completed transcripts to it; recording and transcription are not part of this repository yet.

## Run locally

```bash
bun install
cp .env.example .env
# Fill in the values in .env
bun run db:init
bun dev
```

The API runs at `http://localhost:3000`. Private endpoints use `Authorization: Bearer <MEMORY_API_KEY>`. See [`openapi.json`](./openapi.json) for the routes and request bodies.
