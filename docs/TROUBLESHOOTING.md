# Troubleshooting

Run `./scripts/verify.sh` first — it names the failing gate.

---

## §Watcher — no dsh sessions ever appear

**Watching the real session tree instead of the flat directory.** The single most common
mistake. The claude-mem worker runs under Bun, and Bun's recursive `fs.watch` does not
register inotify watches for directories created *after* the watch starts. dsh creates a
directory per session, so live sessions are structurally invisible. Waiting longer does
not help. `path` must be `~/.dsh/sessions-cmem/*.jsonl`.

**The watched directory did not exist at worker start.** The watch fails silently and
never retries. `mkdir -p ~/.dsh/sessions-cmem`, then restart the worker — in that order.

**The worker was not restarted.** Config is read once at start.

**`~` in the config path.** Not expanded. Use absolute paths.

## §Watcher — long sessions ingest, short ones do not

`"startAtEnd": true`. A file first seen at its end contributes nothing, and short
sessions are already settled by the time they are published, so they are skipped
entirely. Set it to `false`: every published file is complete history, so reading from
byte 0 is correct.

## §Publisher — flat directory stays empty

- No session has been idle for `SETTLE_SECS` (120s) yet. Ongoing sessions are excluded
  by design.
- `systemctl --user is-active dsh-cmem-export.timer` is not `active`.
- A pattern in `~/.dsh/cmem-export.exclude` matches the path.
- dsh is still writing `.jsonl.zstd`; the script only looks for `session.v3.jsonl`.
- Run it by hand and read the error: `bash -x ~/.dsh/cmem-export.sh`.

If `~/.dsh` and the target are on different filesystems, `ln` fails and the script falls
back to `cp` — correct, but then appends to a resumed session are no longer picked up.

## §dsh — every session operation throws

A session root holds exactly one encoding. Any `*.jsonl.zstd` left under
`~/.dsh/sessions` after switching to `compression: none` makes create/open/stat/list
throw. Move the old directory aside:

```bash
mv ~/.dsh/sessions ~/.dsh/sessions-zstd-archive-$(date +%Y%m%d)
mkdir -p ~/.dsh/sessions
```

## §dsh — sessions moved somewhere unexpected

The patch omitted `root:`. A dsh patch replaces the targeted row's **whole** `config`,
so anything not restated is dropped. Keep both `root:` and `compression:`.

## §MCP — `mcp__claude_mem__*` tools absent inside dsh

**`env:` not declared.** dsh's stdio bridge scrubs ambient variable names matching
`/KEY|PASSWORD|SECRET|TOKEN/i` and every `DSH_*` name. `CLAUDE_CONFIG_DIR` and
`CLAUDE_PLUGIN_ROOT` must be listed explicitly in the patch.

**Pointing at the launcher rather than `mcp-server.cjs`.** The launcher in `.mcp.json`
probes for paths that do not resolve under dsh's spawn environment. Use the direct path.

**Wrong plugin root.** Multiple claude-mem versions coexist under `~/.claude` — an
installed marketplace copy and version-pinned cache copies. Prefer marketplace. Confirm
with the handshake in AGENTS.md Gate 0, which prints the version it answers with.

**`node` not on dsh's PATH.** The patch uses a bare `command: node`; give an absolute
path if dsh is launched from an environment without it.

## §MCP — the tool is there but "finds nothing"

Run a positive control before believing it: search a term that certainly exists, such as
a project you have worked on. Agents routinely report a broken pipe or an empty result
set as "nothing found", complete with a confident summary.

## §Sessions ingest but observations are empty

The schema's field paths did not match. dsh's record shapes can shift between versions —
compare a real transcript against [TRANSCRIPT-FORMAT.md](TRANSCRIPT-FORMAT.md):

```bash
python3 -c "
import json,collections
c=collections.Counter()
for l in open('$HOME/.dsh/sessions-cmem/<session>.jsonl'):
    c[json.loads(l).get('type')]+=1
print(c)"
```

If `assistant/message` records are present but replies come out as chain-of-thought, the
`coalesce` order is wrong — `content[0]` is often a `reasoning` block, so
`content[1].text` must be tried first.

## Useful queries

```bash
DB=~/.claude-mem/claude-mem.db
sqlite3 -header -column $DB "select id,content_session_id,project,status,started_at
  from sdk_sessions where platform_source='dsh' order by id desc limit 10;"

sqlite3 -header -column $DB "select o.id,o.type,o.title,o.created_at
  from observations o join sdk_sessions s using(memory_session_id)
  where s.platform_source='dsh' order by o.id desc limit 20;"

cat ~/.claude-mem/transcript-watch-state.json     # per-file byte offsets
ls -la ~/.claude-mem/logs/                        # worker logs
```
