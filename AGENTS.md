# Runbook: wire dsh into claude-mem

You are setting up a shared memory between **DeepSeek Harness (`dsh`)** and
**claude-mem** on the machine you are running on. Work through the phases in order.
Do not skip a verification gate — each one catches a failure that is silent otherwise.

Everything here is local to the user's machine. Nothing is sent anywhere.

---

## Phase 0 — Preflight

Run and record the answers. If any is missing, stop and tell the user what to install.

```bash
command -v node bash sqlite3 python3
test -d "$HOME/.dsh"            && echo "dsh home OK"
systemctl --user is-system-running 2>/dev/null   # any output means user systemd exists
```

Locate claude-mem's plugin root and DB. These paths vary by install method, so
**discover them, do not assume**:

```bash
# DB + config dir (respects CLAUDE_MEM_HOME if set)
CM_HOME="${CLAUDE_MEM_HOME:-$HOME/.claude-mem}"
ls "$CM_HOME/claude-mem.db"

# plugin root: the dir containing scripts/mcp-server.cjs
find "$HOME/.claude" -name mcp-server.cjs -path '*claude*mem*' 2>/dev/null
# fallback, for npm/global installs:
find "$HOME/.claude" "$HOME/.local" /usr/lib/node_modules -name mcp-server.cjs 2>/dev/null | head
```

Set these three variables for the rest of the run:

- `CM_HOME`     — e.g. `$HOME/.claude-mem`
- `CM_PLUGIN`   — the directory whose `scripts/mcp-server.cjs` you found
- `CC_CONFIG`   — the Claude config dir, normally `$HOME/.claude`

**Gate 0**: the MCP server must speak. This is the single most useful early check —
if it fails, nothing downstream can work.

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
| CLAUDE_CONFIG_DIR="$CC_CONFIG" CLAUDE_PLUGIN_ROOT="$CM_PLUGIN" \
  timeout 30 node "$CM_PLUGIN/scripts/mcp-server.cjs" 2>/dev/null | head -2
```

Expect a `serverInfo` line naming `claude-mem`, then a `tools/list` result containing
`search` and `get_observations`. Anything else → see `docs/TROUBLESHOOTING.md §MCP`.

---

## Phase 1 — dsh writes plain-text transcripts

dsh may compress sessions to `.jsonl.zstd`. The watcher tails plain text, so switch
the session root to `compression: none`.

**A session root belongs to exactly one encoding.** If any `*.jsonl.zstd` remains under
the root after the switch, dsh's create/open/stat/list calls throw. Archive them first:

```bash
if compgen -G "$HOME/.dsh/sessions/**/*.jsonl.zstd" >/dev/null 2>&1; then
  mv "$HOME/.dsh/sessions" "$HOME/.dsh/sessions-zstd-archive-$(date +%Y%m%d)"
  mkdir -p "$HOME/.dsh/sessions"
fi
```

Then apply the patch layer. Merge `config/dsh-mcp-client.yml` into
`~/.dsh/cordis.patch.yml` (create the file if absent; if it exists, append the entries
rather than overwriting — read it first).

Note the patch semantics: **a patch replaces the targeted row's whole `config`**, which
is why `root:` is restated alongside `compression:`. Dropping it silently relocates the
session root.

**Gate 1**: start a throwaway dsh session, send one message, exit. Then:

```bash
find "$HOME/.dsh/sessions" -name 'session.v3.jsonl' -newermt '-5 min' | head
```

A plain-text `session.v3.jsonl` must exist. If you only see `.jsonl.zstd`, the patch
did not take.

---

## Phase 2 — Read side: claude-mem as a dsh MCP server

The same `config/dsh-mcp-client.yml` file contains the `claude-mem-mcp` insert. Two
details that are load-bearing:

1. **Point at `mcp-server.cjs` directly**, not at the launcher in `.mcp.json`. The
   launcher probes for paths that will not resolve under dsh's spawn environment.
2. **`env:` must be explicit.** dsh's stdio bridge scrubs ambient variables whose names
   match `/KEY|PASSWORD|SECRET|TOKEN/i`, plus every `DSH_*` name. `CLAUDE_CONFIG_DIR`
   and `CLAUDE_PLUGIN_ROOT` survive only because they are declared here.

Substitute your real `CM_PLUGIN` / `CC_CONFIG` for the `__PLACEHOLDER__` values.

**Gate 2**: in a fresh dsh session, ask it:

> Use the `claude_mem` `search` tool to look up "<a word you know exists in memory>".
> Tell me the exact tool name you called and the title of the first result.

It must report a tool named `mcp__claude_mem__search` and return a real title. If the
tool is absent from its toolset, the MCP client did not register — check dsh's logs.

**Do not accept "no results" as a pass.** Run a positive control: search for a term that
certainly exists (any project name you have worked on). An agent will happily report a
broken pipe as "nothing found".

---

## Phase 3 — Write side: the flat publish directory

```bash
mkdir -p "$HOME/.dsh/sessions-cmem"
install -m 755 scripts/cmem-export.sh "$HOME/.dsh/cmem-export.sh"
```

Read `scripts/cmem-export.sh` before installing it. It hardlinks any
`session.v3.jsonl` untouched for `SETTLE_SECS` (default 120) into
`~/.dsh/sessions-cmem/<session-id>.jsonl`, skipping targets that already exist.

Install the timer:

```bash
mkdir -p "$HOME/.config/systemd/user"
cp systemd/dsh-cmem-export.service systemd/dsh-cmem-export.timer "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now dsh-cmem-export.timer
```

No systemd? A cron entry works identically:
`*/2 * * * * $HOME/.dsh/cmem-export.sh`

**Gate 3**: `systemctl --user is-active dsh-cmem-export.timer` → `active`, and after
one interval `ls ~/.dsh/sessions-cmem/` lists your Phase-1 session.

---

## Phase 4 — Teach the watcher the dsh schema

Merge `config/transcript-watch.json` into `$CM_HOME/transcript-watch.json`. If the file
exists, add the `dsh` key under `schemas` and the `dsh` entry to `watches` — **do not
overwrite**, other platforms may already be registered.

Two settings people get wrong:

- **`"path"` must be the flat directory glob**, `~/.dsh/sessions-cmem/*.jsonl` — never
  the real session tree. Watching the tree is the exact failure this design exists to
  avoid (see README, "Why the hardlink hop exists").
- **`"startAtEnd": false`.** With `true`, a file first seen at its end contributes
  nothing, and short sessions — which are already settled by the time they are
  published — are skipped entirely. Every published file is complete history, so
  reading from byte 0 is correct.

Absolute paths only; `~` is not expanded in this file.

Restart the worker so it re-reads the config, then verify the directory exists **before**
the restart — a watch on a missing directory fails silently and never retries:

```bash
test -d "$HOME/.dsh/sessions-cmem" || { echo "create it first"; exit 1; }
claude-mem restart 2>/dev/null || systemctl --user restart claude-mem 2>/dev/null
```

**Gate 4** — the end-to-end proof:

```bash
./scripts/verify.sh
```

It asserts: MCP responds; the timer is active; the flat dir is populated; the watcher
state file holds offsets for `sessions-cmem` paths; and the DB contains
`sdk_sessions` rows with `platform_source='dsh'` plus observations joined to them.

---

## Phase 5 — Report

Tell the user:

- The read direction, with the tool name dsh actually reported in Gate 2.
- The write direction, with the session and observation counts from `verify.sh`.
- The **2–4 minute ingestion delay**, and that a session is only published once it has
  been quiet for `SETTLE_SECS`.
- Point them at `docs/PRIVACY.md` if they have not read it.

Do not report success on any gate you did not actually run.

---

## Failure modes worth knowing before you hit them

| Symptom | Cause |
|---|---|
| Watcher never sees any dsh session | Watching the real session tree; Bun's recursive `fs.watch` ignores dirs created after the watch starts |
| Watch silently inert, no error | Watched directory did not exist when the worker started |
| Short sessions produce no observations | `startAtEnd: true` |
| dsh throws on any session operation | Mixed `.jsonl` and `.jsonl.zstd` under one session root |
| MCP tools absent inside dsh | `env:` not declared; the stdio bridge scrubbed the ambient vars |
| Sessions relocate unexpectedly | Patch omitted `root:` — a patch replaces the whole `config` |
| Config edits appear to do nothing | Worker not restarted; it caches config at start |

Full detail in `docs/TROUBLESHOOTING.md`.
