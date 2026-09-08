# dsh `session.v3.jsonl` — what the watcher reads

One JSON object per line, appended live. Path:

```
~/.dsh/sessions/<workspace-slug>/<session-id>/session.v3.jsonl
```

Record types seen in a typical session: `session`, `permission/preset`, `sandbox/mode`,
`approval/policy`, `agent/inbox/spliced`, `turn/start`, `step/start`, `user/message`,
`system/message`, `request/header`, `request/context`, `assistant/message`, `tool/call`,
`tool/result`, `session/title`, `step/end`, `turn/end`.

The schema in `config/transcript-watch.json` maps five of them.

## Header — `session_context`

```json
{"type":"session","version":3,"id":"session-<uuid>","createdAt":1788890283182,
 "cwd":"/path/to/workspace","isSeeded":false,"delegationDepth":0}
```

`cwd` becomes the claude-mem **project** name (basename), which is how dsh work ends up
filed next to Claude Code work in the same project.

## `user/message`

```json
{"type":"user/message","seq":8,"time":...,
 "data":{"content":[{"type":"text","text":"..."}],
         "source":{"kind":"user"},"role":"user","id":"<uuid>"},
 "surfaceOp":"append"}
```

Matched on `data.source.kind == "user"` rather than on `type`, because the same shape
also arrives inside `agent/inbox/spliced` batches.

Note that dsh emits *synthetic* `user/message` records too — injected
`<system-reminder>` blocks, workspace `AGENTS.md` instructions, runtime-context
snapshots. They match this rule and are read. See [PRIVACY.md](PRIVACY.md).

## `assistant/message`

```json
{"type":"assistant/message","seq":17,"time":...,
 "data":{"turn":1,"step":1,
   "message":{"role":"assistant","content":[
     {"type":"reasoning","text":"..."},
     {"type":"text","text":"..."}]}}}
```

`content[0]` is often a `reasoning` block, so the schema coalesces `content[1].text`
first and falls back to `content[0].text` — that ordering matters, or you capture
chain-of-thought instead of the reply.

## `tool/call` / `tool/result`

```json
{"type":"tool/call","data":{"callId":"call_...","name":"mcp__claude_mem__search",
                            "arguments":"{\"query\": \"...\"}"}}

{"type":"tool/result","data":{"message":{"source":{"kind":"tool","callId":"call_..."},
  "content":[{"type":"tool-result","toolCallId":"call_...",
              "content":[{"type":"text","text":"..."}]}]}}}
```

`arguments` is a JSON **string**, not an object. Calls and results are paired by
`callId` / `toolCallId`.

## Deliberately unmapped

`request/header`, `request/context` and `session/title-llm-request` carry the assembled
prompt sent to the model — the full system prompt, tool definitions, and the whole
history re-serialised on every turn. Mapping them would balloon the store and copy the
system prompt into it. They are left out on purpose.
