# MindDock

**Remember the meeting. Skip the meeting bot.**

MindDock is a small personal meeting memory for conversations captured on your Mac. The idea: a simpler, bot-free alternative to Granola, Fathom, and similar tools. Keep the useful context from each conversation without adding another participant to the call.

## What it does

- Keeps a profile for each person, including company, role, links, and research notes.
- Records your mic and call audio on macOS, transcribes on device, and saves the transcript. No bot joins the call.
- Saves meetings with full transcripts and optional summaries.
- Tracks action items and whether they belong to you or the other person.
- Searches people and past conversations by name, company, summary, or transcript text.
- Exposes a small authenticated API with an [OpenAPI schema](./openapi.json).

## Mac app

The native Mac app lives in [`macos/`](./macos). Once installed in Applications, search **MindDock** in Spotlight and open it. Add a person, then choose **Record meeting**. You can also paste an existing transcript. The first recording asks for macOS microphone, speech recognition, and screen recording permission. Only the transcript is saved; MindDock does not keep the audio.

For a fresh setup, run [`macos/install.sh`](./macos/install.sh) once after filling in `.env`. The app reads its API key from `~/Library/Application Support/MindDock/config.json`.

## Run locally

```bash
bun install
cp .env.example .env
# Fill in the values in .env
bun run db:init
bun dev
```

The API runs at `http://localhost:3000`. Private endpoints use `Authorization: Bearer <MEMORY_API_KEY>`. See [`openapi.json`](./openapi.json) for the routes and request bodies.
