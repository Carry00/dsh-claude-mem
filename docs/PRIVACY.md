# What gets captured

Everything here stays on your machine: dsh writes transcripts to `~/.dsh`, the publisher
hardlinks within the same directory, and claude-mem stores observations in a local
SQLite database. Nothing in this integration sends data anywhere.

(claude-mem has its own optional cloud sync, off by default and unrelated to this repo.
If you enable it, your dsh sessions go wherever the rest of your memories go.)

## Read into memory

- **Your prompts** — every `user/message`.
- **Assistant replies** — the visible answer text.
- **Tool calls and their results** — names, arguments, and returned output. This is the
  widest surface: a `read_file` result puts that file's contents into the transcript, and
  a shell command's output goes in verbatim.

## Not read

- **The system prompt**, which lives in `system/message` and `request/header` records —
  neither is mapped by the schema.
- **The assembled per-turn request**: tool definitions and the re-serialised history
  in `request/header`.
- **Session titling requests** (`session/title-llm-request`).

Verified on a live install: no observation contained system-prompt text, and a scan of
published transcripts found no `apiKey` / `authorization` / `token` credential fields.

## The wrinkle worth knowing

dsh emits *synthetic* `user/message` records alongside your real ones — injected
`<system-reminder>` blocks, your workspace's `AGENTS.md` content, and runtime-context
snapshots. They carry `source.kind: "user"`, so the schema reads them like any other
prompt. In practice this means **your workspace instruction files can end up summarised
into memory**. Usually harmless; worth knowing if an `AGENTS.md` contains anything you
would not want indexed.

## Opting a workspace out

Create `~/.dsh/cmem-export.exclude`, one substring per line (`#` comments allowed).
Any session file whose full path contains a pattern is never published, so nothing from
it reaches the memory store:

```
# never index client work
/clients/
# or one specific workspace slug
--home-me-secret-project--
```

Exclusions are checked at publish time. A session already published stays published —
delete its hardlink from `~/.dsh/sessions-cmem/` to stop further appends being read, and
remove any observations already stored via claude-mem's own tooling.

## Deleting the memory of a session

```bash
sqlite3 ~/.claude-mem/claude-mem.db \
  "delete from observations where memory_session_id in
     (select memory_session_id from sdk_sessions
       where platform_source='dsh' and content_session_id='<session-uuid>');"
```

Back up `claude-mem.db` first. `uninstall.sh` deliberately does **not** delete anything
from the database.
