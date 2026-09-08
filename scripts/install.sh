#!/usr/bin/env bash
# Idempotent installer for the dsh <-> claude-mem integration.
#
#   ./scripts/install.sh            # apply
#   ./scripts/install.sh --dry-run  # show what would change, touch nothing
#
# It will NOT overwrite an existing ~/.dsh/cordis.patch.yml or an existing
# transcript-watch.json — those it leaves for you (or your agent) to merge by
# hand, printing the exact block to add. Everything else is safe to re-run.
set -euo pipefail

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM_HOME="${CLAUDE_MEM_HOME:-$HOME/.claude-mem}"
CC_CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FLAT="$HOME/.dsh/sessions-cmem"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
run() { if [ "$DRY" -eq 1 ]; then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi; }
die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
say "Preflight"
for c in node bash sqlite3 python3 find; do
  command -v "$c" >/dev/null 2>&1 || die "missing dependency: $c"
done
[ -d "$HOME/.dsh" ]  || die "~/.dsh not found — install and run dsh at least once"
[ -f "$CM_HOME/claude-mem.db" ] || die "claude-mem DB not found at $CM_HOME/claude-mem.db"

if [ -z "${CM_PLUGIN:-}" ]; then
  cands=$(find "$CC_CONFIG" -name mcp-server.cjs 2>/dev/null)
  pick=$(printf '%s\n' "$cands" | grep marketplaces | head -1)
  [ -z "$pick" ] && pick=$(printf '%s\n' "$cands" | head -1)
  [ -n "$pick" ] && CM_PLUGIN=$(dirname "$(dirname "$pick")")
fi
[ -n "${CM_PLUGIN:-}" ] && [ -f "$CM_PLUGIN/scripts/mcp-server.cjs" ] \
  || die "could not locate claude-mem's mcp-server.cjs — set CM_PLUGIN=/path/to/plugin-root"
echo "    plugin root : $CM_PLUGIN"
echo "    claude-mem  : $CM_HOME"
echo "    config dir  : $CC_CONFIG"

# --- compressed session check ------------------------------------------------
say "Checking for compressed sessions"
n_zstd=$(find "$HOME/.dsh/sessions" -name '*.jsonl.zstd' -type f 2>/dev/null | wc -l)
if [ "$n_zstd" -gt 0 ]; then
  arch="$HOME/.dsh/sessions-zstd-archive-$(date +%Y%m%d)"
  echo "    found $n_zstd compressed session(s); a session root may hold only ONE encoding."
  echo "    They must be moved aside or dsh will throw on every session operation."
  run "mv '$HOME/.dsh/sessions' '$arch' && mkdir -p '$HOME/.dsh/sessions'"
  echo "    archived to: $arch"
else
  echo "    none — good"
fi

# --- publisher + timer -------------------------------------------------------
say "Installing the transcript publisher"
run "mkdir -p '$FLAT'"
run "install -m 755 '$HERE/scripts/cmem-export.sh' '$HOME/.dsh/cmem-export.sh'"

if command -v systemctl >/dev/null 2>&1; then
  run "mkdir -p '$HOME/.config/systemd/user'"
  run "cp '$HERE/systemd/dsh-cmem-export.service' '$HERE/systemd/dsh-cmem-export.timer' '$HOME/.config/systemd/user/'"
  run "systemctl --user daemon-reload"
  run "systemctl --user enable --now dsh-cmem-export.timer"
else
  echo "    no systemd — add this to your crontab instead:"
  echo "      */2 * * * * \$HOME/.dsh/cmem-export.sh"
fi

# --- dsh patch layer ---------------------------------------------------------
say "dsh patch layer (~/.dsh/cordis.patch.yml)"
patch_rendered=$(sed -e "s#__CM_PLUGIN__#$CM_PLUGIN#g" -e "s#__CC_CONFIG__#$CC_CONFIG#g" \
                     "$HERE/config/dsh-mcp-client.yml")
if [ -f "$HOME/.dsh/cordis.patch.yml" ]; then
  echo "    already exists — NOT overwriting. Merge these entries into it:"
  echo "-----------------------------------------------------------------"
  printf '%s\n' "$patch_rendered"
  echo "-----------------------------------------------------------------"
elif [ "$DRY" -eq 1 ]; then
  echo "    [dry-run] would write ~/.dsh/cordis.patch.yml"
else
  printf '%s\n' "$patch_rendered" > "$HOME/.dsh/cordis.patch.yml"
  echo "    written"
fi

# --- watcher config ----------------------------------------------------------
say "claude-mem transcript watcher ($CM_HOME/transcript-watch.json)"
watch_rendered=$(sed -e "s#__HOME__#$HOME#g" -e "s#__CM_HOME__#$CM_HOME#g" \
                     "$HERE/config/transcript-watch.json")
if [ -f "$CM_HOME/transcript-watch.json" ]; then
  echo "    already exists — NOT overwriting (other platforms may be registered)."
  echo "    Add the 'dsh' key under \"schemas\" and the 'dsh' entry to \"watches\" from:"
  echo "      $HERE/config/transcript-watch.json"
  echo "    substituting __HOME__=$HOME and __CM_HOME__=$CM_HOME."
elif [ "$DRY" -eq 1 ]; then
  echo "    [dry-run] would write $CM_HOME/transcript-watch.json"
else
  printf '%s\n' "$watch_rendered" > "$CM_HOME/transcript-watch.json"
  echo "    written"
fi

# --- restart -----------------------------------------------------------------
say "Restarting the claude-mem worker"
echo "    (the watched directory must exist first — it does, created above)"
if [ "$DRY" -eq 1 ]; then
  echo "    [dry-run] would restart the worker"
else
  claude-mem restart 2>/dev/null \
    || systemctl --user restart claude-mem 2>/dev/null \
    || echo "    could not restart automatically — restart the claude-mem worker yourself"
fi

say "Done. Now run: ./scripts/verify.sh"
echo "    Gate 2 (the read side) is a human check — see AGENTS.md Phase 2."
echo "    New dsh sessions take 2-4 minutes to appear in memory."
