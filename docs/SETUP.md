# Manual setup

The agent-facing version, with the reasoning behind each step, is [`../AGENTS.md`](../AGENTS.md).
This is the same thing for a human doing it by hand.

If you just want it done: `./scripts/install.sh` (add `--dry-run` first to see the plan),
then `./scripts/verify.sh`.

---

## 0. Find your paths

```bash
CM_HOME="${CLAUDE_MEM_HOME:-$HOME/.claude-mem}"      # DB + config
CC_CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"      # Claude config dir
CM_PLUGIN=$(dirname "$(dirname "$(find "$CC_CONFIG" -name mcp-server.cjs | grep marketplaces | head -1)")")
echo "$CM_HOME"; echo "$CC_CONFIG"; echo "$CM_PLUGIN"
```

Several claude-mem versions can coexist under `~/.claude` (an installed marketplace copy
plus version-pinned cache copies). Prefer the marketplace one.

## 1. Plain-text transcripts

If `find ~/.dsh/sessions -name '*.jsonl.zstd'` returns anything, move the whole
`sessions` directory aside and recreate it empty. A session root holds exactly one
encoding; a mixed root makes every dsh session operation throw.

Then put `config/dsh-mcp-client.yml` at `~/.dsh/cordis.patch.yml`, substituting
`__CM_PLUGIN__` and `__CC_CONFIG__`. Merge, don't overwrite, if the file exists.

`root:` is restated in that patch on purpose — a dsh patch replaces the targeted row's
entire `config`, so anything you omit is lost.

## 2. Read side

That same file registers claude-mem's MCP server as a dsh MCP client. Start a dsh
session and confirm it can call `mcp__claude_mem__search`.

Ask it to search a term you *know* is in your memory, and to report the exact tool name
and the first result's title. A term with no hits proves nothing — an agent will report
a broken pipe as "no results found".

## 3. Publisher

```bash
mkdir -p ~/.dsh/sessions-cmem
install -m 755 scripts/cmem-export.sh ~/.dsh/cmem-export.sh
cp systemd/dsh-cmem-export.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dsh-cmem-export.timer
```

Cron equivalent: `*/2 * * * * $HOME/.dsh/cmem-export.sh`

Tunables: `DSH_CMEM_SETTLE_SECS` (default 120) and `~/.dsh/cmem-export.exclude`
(see [PRIVACY.md](PRIVACY.md)).

## 4. Watcher

Merge `config/transcript-watch.json` into `$CM_HOME/transcript-watch.json`, substituting
`__HOME__` and `__CM_HOME__`. Absolute paths only — `~` is not expanded there.

Two things to get right:

- `path` points at `~/.dsh/sessions-cmem/*.jsonl`, **not** the real session tree.
- `startAtEnd` is `false`, or short sessions produce nothing.

Make sure `~/.dsh/sessions-cmem` exists, **then** restart the worker
(`claude-mem restart`). A watch on a missing directory fails silently and never retries.

## 5. Verify

```bash
./scripts/verify.sh
```

Then start a dsh session, say something distinctive, exit, wait 2–4 minutes, and search
for it from Claude Code.
