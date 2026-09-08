#!/bin/bash
# Publish settled dsh session transcripts into a flat directory for claude-mem.
#
# Why this exists: the claude-mem worker runs under Bun, whose recursive
# fs.watch does NOT add inotify watches for directories created after the
# watch starts. dsh creates one new directory per session, so live sessions
# are invisible to the watcher. This mirrors *settled* transcripts (untouched
# for SETTLE_SECS) into one stable, flat, already-watched directory, where
# depth-1 create events are delivered reliably.
#
# Hardlinks, not copies: same filesystem, so no extra disk. A settled
# transcript is effectively immutable; if a session resumes and appends, the
# link sees the appends and the watcher's byte offset simply advances.
set -euo pipefail

SRC="$HOME/.dsh/sessions"
DST="$HOME/.dsh/sessions-cmem"
SETTLE_SECS="${DSH_CMEM_SETTLE_SECS:-120}"

# Optional opt-out: one substring pattern per line (blank lines and # comments
# ignored). Any session file whose full path contains a pattern is never
# published, so that workspace's transcripts never reach the memory store.
EXCLUDE_FILE="$HOME/.dsh/cmem-export.exclude"

mkdir -p "$DST"
[ -d "$SRC" ] || exit 0

find "$SRC" -name 'session.v3.jsonl' -type f -mmin +$((SETTLE_SECS/60)) 2>/dev/null | while read -r f; do
  sid=$(basename "$(dirname "$f")")
  target="$DST/$sid.jsonl"
  [ -e "$target" ] && continue

  if [ -f "$EXCLUDE_FILE" ]; then
    skip=0
    while IFS= read -r pat; do
      case "$pat" in ''|\#*) continue ;; esac
      case "$f" in *"$pat"*) skip=1; break ;; esac
    done < "$EXCLUDE_FILE"
    [ "$skip" -eq 1 ] && continue
  fi
  ln -f "$f" "$target" 2>/dev/null || cp -f "$f" "$target"
done
