#!/usr/bin/env bash
# Remove the integration. Leaves your memory database untouched — observations
# already ingested from dsh sessions stay searchable.
set -uo pipefail
CM_HOME="${CLAUDE_MEM_HOME:-$HOME/.claude-mem}"

echo "==> Stopping the publisher timer"
systemctl --user disable --now dsh-cmem-export.timer 2>/dev/null
rm -f "$HOME/.config/systemd/user/dsh-cmem-export.service" \
      "$HOME/.config/systemd/user/dsh-cmem-export.timer"
systemctl --user daemon-reload 2>/dev/null

echo "==> Removing the publisher and its hardlinks"
rm -f "$HOME/.dsh/cmem-export.sh"
rm -rf "$HOME/.dsh/sessions-cmem"   # hardlinks only; the real sessions are untouched

echo "==> Manual steps left to you (they may hold your own edits):"
echo "    - remove the 'dsh' schema and watch from $CM_HOME/transcript-watch.json"
echo "    - remove the claude-mem-mcp / session-persistence-jsonl entries from"
echo "      ~/.dsh/cordis.patch.yml"
echo "    - restart the claude-mem worker"
echo "    Your memory database was NOT modified."
