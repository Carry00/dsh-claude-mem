# dsh-claude-mem

Give **DeepSeek Harness (`dsh`)** a persistent, shared memory by wiring it into
[claude-mem](https://github.com/thedotmack/claude-mem) — the same memory store your
Claude Code sessions already write to.

Two independent halves, either usable alone:

| Direction | What it does | Mechanism |
|---|---|---|
| **Read** — dsh → memory | The agent can `search` / `get_observations` over everything ever recorded (Claude Code *and* dsh sessions) | claude-mem's MCP server, registered as a dsh MCP client |
| **Write** — dsh → memory | dsh's own sessions get summarised into observations and become searchable later | claude-mem's transcript watcher, taught the `session.v3.jsonl` schema |

After setup, a dsh session and a Claude Code session share one memory pool. Ask dsh
"what did we decide about X last week?" and it finds work done in Claude Code, and
vice versa.

---

## Reproducing this with an AI agent

This repo is written to be executed by an agent. Point any coding agent (Claude Code,
dsh itself, Codex, Cursor, …) at the clone and say:

> Read `AGENTS.md` in this repo and set up the dsh ↔ claude-mem integration on this machine.

`AGENTS.md` is the machine-facing runbook: preflight checks, exact edits, verification
gates, and the failure modes with their causes. `CLAUDE.md` is a symlink to it.

Doing it by hand instead? Follow [`docs/SETUP.md`](docs/SETUP.md).

---

## Requirements

- `dsh` (DeepSeek Harness) installed, run at least once so `~/.dsh/` exists
- `claude-mem` v13.x installed with its worker running
- Linux with **systemd user services** (`systemctl --user`), or any cron-like scheduler
- `node`, `bash`, `sqlite3`, `python3`

---

## How it works

```
                    ┌──────────────────────────────┐
   READ  ───────────│  claude-mem MCP server       │◀── the same DB Claude Code writes
                    │  (mcp-server.cjs, stdio)     │
                    └──────────────┬───────────────┘
                                   │ mcp__claude_mem__search …
                    ┌──────────────▼───────────────┐
                    │            dsh               │
                    └──────────────┬───────────────┘
                                   │ writes session.v3.jsonl
       ~/.dsh/sessions/<workspace>/<session-id>/session.v3.jsonl
                                   │
                                   │  hardlink, once settled (timer, every 2 min)
                                   ▼
       ~/.dsh/sessions-cmem/<session-id>.jsonl      ← flat, stable, pre-existing dir
                                   │
                    ┌──────────────▼───────────────┐
   WRITE ───────────│  claude-mem transcript watch │──▶ observations, platform_source='dsh'
                    └──────────────────────────────┘
```

### Why the hardlink hop exists

The claude-mem worker runs under **Bun**, and Bun's recursive `fs.watch` does *not*
register watches for directories created *after* the watch starts. dsh creates a new
directory per session, so live sessions are structurally invisible to the watcher —
it is not a race you can win by waiting.

The fix is to publish *settled* transcripts (untouched for N seconds, i.e. the session
has stopped writing) into one **flat directory that already existed** when the watch
started. Depth-1 create events there are delivered reliably.

Hardlinks, not copies: same filesystem, no extra disk, and if the session resumes and
appends, the link sees the appends — the watcher's byte offset simply advances.

Cost: a **2–4 minute delay** between a dsh session going quiet and its memories
appearing. That is the deliberate trade for reliability.

---

## Layout

```
AGENTS.md                    machine-facing runbook (CLAUDE.md → symlink)
docs/SETUP.md                human step-by-step
docs/TRANSCRIPT-FORMAT.md    dsh session.v3.jsonl reference
docs/TROUBLESHOOTING.md      symptom → cause → fix
config/dsh-mcp-client.yml    dsh patch: register claude-mem MCP + plaintext sessions
config/transcript-watch.json claude-mem watcher schema for dsh
scripts/install.sh           idempotent installer
scripts/cmem-export.sh       the hardlink publisher
scripts/verify.sh            end-to-end verification gates
scripts/uninstall.sh         full removal
systemd/                     user service + timer
```

## Privacy

Session transcripts contain whatever you typed and whatever your tools returned.
Before turning this on, read [`docs/PRIVACY.md`](docs/PRIVACY.md) — it covers what is
and is not captured, and how to exclude workspaces.

## License

MIT
