#!/usr/bin/env bash
# End-to-end verification of the dsh <-> claude-mem integration.
# Exits non-zero if any gate fails. Read-only: touches nothing.
set -uo pipefail

CM_HOME="${CLAUDE_MEM_HOME:-$HOME/.claude-mem}"
CC_CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DB="$CM_HOME/claude-mem.db"
FLAT="$HOME/.dsh/sessions-cmem"
STATE="$CM_HOME/transcript-watch-state.json"

fail=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- Gate 0: MCP server responds ---------------------------------------------
head_ "Gate 0 — claude-mem MCP server"
# Prefer an installed marketplace plugin over a version-pinned cache copy —
# several versions can coexist under ~/.claude and the cache may be stale.
if [ -z "${CM_PLUGIN:-}" ]; then
  cands=$(find "$CC_CONFIG" -name mcp-server.cjs 2>/dev/null)
  pick=$(printf '%s\n' "$cands" | grep marketplaces | head -1)
  [ -z "$pick" ] && pick=$(printf '%s\n' "$cands" | head -1)
  [ -n "$pick" ] && CM_PLUGIN=$(dirname "$(dirname "$pick")")
fi
CM_PLUGIN="${CM_PLUGIN:-}"
if [ -z "$CM_PLUGIN" ] || [ ! -f "$CM_PLUGIN/scripts/mcp-server.cjs" ]; then
  bad "mcp-server.cjs not found (set CM_PLUGIN=/path/to/plugin-root)"
else
  out=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | CLAUDE_CONFIG_DIR="$CC_CONFIG" CLAUDE_PLUGIN_ROOT="$CM_PLUGIN" \
      timeout 30 node "$CM_PLUGIN/scripts/mcp-server.cjs" 2>/dev/null)
  case "$out" in
    *'"name":"claude-mem"'*) pass "server handshake ($CM_PLUGIN)" ;;
    *) bad "no handshake from mcp-server.cjs" ;;
  esac
  case "$out" in
    *'"name":"search"'*) pass "search tool advertised" ;;
    *) bad "search tool missing from tools/list" ;;
  esac
fi

# --- Gate 1: dsh writes plain text -------------------------------------------
head_ "Gate 1 — plain-text dsh transcripts"
n_plain=$(find "$HOME/.dsh/sessions" -name 'session.v3.jsonl' -type f 2>/dev/null | wc -l)
n_zstd=$(find "$HOME/.dsh/sessions" -name '*.jsonl.zstd' -type f 2>/dev/null | wc -l)
[ "$n_plain" -gt 0 ] && pass "$n_plain plain-text session(s) under ~/.dsh/sessions" \
                     || bad "no session.v3.jsonl found — is compression still on?"
[ "$n_zstd" -eq 0 ] && pass "no .jsonl.zstd mixed into the session root" \
                    || bad "$n_zstd .jsonl.zstd file(s) under the root — dsh will throw; archive them"

# --- Gate 2: publisher --------------------------------------------------------
head_ "Gate 2 — flat publish directory + timer"
[ -d "$FLAT" ] && pass "flat dir exists: $FLAT" || bad "missing $FLAT (watch fails silently without it)"
n_flat=$(ls -1 "$FLAT"/*.jsonl 2>/dev/null | wc -l)
[ "$n_flat" -gt 0 ] && pass "$n_flat published transcript(s)" \
                    || warn "flat dir empty — no session has been quiet for SETTLE_SECS yet"
if command -v systemctl >/dev/null 2>&1; then
  st=$(systemctl --user is-active dsh-cmem-export.timer 2>/dev/null)
  [ "$st" = active ] && pass "dsh-cmem-export.timer active" \
                     || bad "timer not active (got '${st:-none}') — or use cron instead"
else
  warn "no systemctl; confirm your cron entry runs cmem-export.sh"
fi

# --- Gate 3: watcher config + state ------------------------------------------
head_ "Gate 3 — transcript watcher"
if [ -f "$CM_HOME/transcript-watch.json" ]; then
  python3 - "$CM_HOME/transcript-watch.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
w=[x for x in c.get("watches",[]) if x.get("name")=="dsh" or x.get("schema")=="dsh"]
if not w: print("  \033[31mFAIL\033[0m  no 'dsh' watch registered"); sys.exit(1)
w=w[0]
p=w.get("path","")
if "sessions-cmem" in p: print(f"  \033[32mPASS\033[0m  watch path is the flat dir: {p}")
else: print(f"  \033[31mFAIL\033[0m  watch path is not the flat dir: {p}"); sys.exit(1)
if w.get("startAtEnd") is False: print("  \033[32mPASS\033[0m  startAtEnd: false")
else: print("  \033[31mFAIL\033[0m  startAtEnd must be false or short sessions are skipped"); sys.exit(1)
if "dsh" in c.get("schemas",{}): print("  \033[32mPASS\033[0m  dsh schema defined")
else: print("  \033[31mFAIL\033[0m  dsh schema missing"); sys.exit(1)
PY
  [ $? -ne 0 ] && fail=1
else
  bad "missing $CM_HOME/transcript-watch.json"
fi

if [ -f "$STATE" ]; then
  n_off=$(python3 -c "
import json,sys
d=json.load(open('$STATE')).get('offsets',{})
print(sum(1 for k in d if 'sessions-cmem' in k))" 2>/dev/null)
  [ "${n_off:-0}" -gt 0 ] && pass "watcher holds offsets for $n_off published file(s)" \
                          || bad "no sessions-cmem offsets — worker may not have been restarted"
else
  bad "missing watcher state file $STATE"
fi

# --- Gate 4: data actually landed --------------------------------------------
head_ "Gate 4 — memories in the database"
if [ -f "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  n_sess=$(sqlite3 "$DB" "select count(*) from sdk_sessions where platform_source='dsh';" 2>/dev/null)
  n_obs=$(sqlite3 "$DB" "select count(*) from observations o join sdk_sessions s on s.memory_session_id=o.memory_session_id where s.platform_source='dsh';" 2>/dev/null)
  [ "${n_sess:-0}" -gt 0 ] && pass "$n_sess dsh session(s) recorded" \
                           || bad "no sdk_sessions with platform_source='dsh'"
  [ "${n_obs:-0}" -gt 0 ] && pass "$n_obs observation(s) from dsh sessions" \
                          || bad "sessions present but no observations — check the worker log"
else
  bad "cannot read $DB (need sqlite3)"
fi

head_ "Result"
if [ "$fail" -eq 0 ]; then
  echo "  All gates passed. dsh and claude-mem share one memory."
  echo "  Reminder: new sessions take 2-4 minutes to appear."
else
  echo "  Some gates failed — see docs/TROUBLESHOOTING.md"
fi
exit "$fail"
