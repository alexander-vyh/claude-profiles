#!/usr/bin/env bash
# init.sh — bootstrap ~/.claude/llm-profiles/ per §7 (Amendment A5).
#
# Behavior (A5, authoritative):
#   - Preflight: lib.sh runs require_cmd jq at source time (exit 7 on missing).
#   - Creates profile_dir at 0755 if missing.
#   - Creates .helpers/ at 0700 if missing.
#   - Creates .state.json with "{}" at 0600 if missing.
#   - Seeds anthropic-direct.json + gateway-example.json ONLY if NO *.json
#     files exist in the profile dir. If any *.json exists (including a
#     single surviving seed after the user deleted the other), seeding is
#     skipped entirely — invariant 12, "never resurrect user-deleted files."
#   - Never overwrites existing files.
#   - Exit 0 on re-run (true idempotent, silent no-op).
#
# Exit codes per §10:
#   0 — success (including no-op)
#   1 — runtime error (permission denied, disk full, etc.)
#   7 — missing dependency (jq; raised by lib.sh at source time)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

target_dir="$(profile_dir)"
helpers_dir="$target_dir/.helpers"
sidecar="$target_dir/.state.json"

# Directory creation is a plain mkdir; atomic_write handles regular files
# only. mkdir's permission bits are governed by umask (077 from lib.sh),
# so we chmod explicitly after creation to hit the §7 / A5 targets.
if [ ! -d "$target_dir" ]; then
  mkdir -p "$target_dir"
  chmod 0755 "$target_dir"
fi

if [ ! -d "$helpers_dir" ]; then
  mkdir "$helpers_dir"
  chmod 0700 "$helpers_dir"
fi

# Sidecar: create only if missing. Use atomic_write per §12a invariant 10
# (all plugin-managed writes follow the Write Protocol).
if [ ! -f "$sidecar" ]; then
  printf '{}' | atomic_write "$sidecar" 0600
fi

# Seed profiles ONLY if NO *.json files exist (A5 "never resurrect").
# The test uses a for-loop over the glob to detect any match without
# relying on `shopt -s nullglob` (portability) — the loop body runs
# zero times if the glob finds no files.
any_json=0
for candidate in "$target_dir"/*.json; do
  if [ -f "$candidate" ]; then
    any_json=1
    break
  fi
done

if [ "$any_json" -eq 0 ]; then
  templates_dir="$(cd "$(dirname "$0")/../templates" && pwd)"

  if [ -f "$templates_dir/profile-anthropic-direct.json" ]; then
    atomic_write "$target_dir/anthropic-direct.json" 0644 \
      < "$templates_dir/profile-anthropic-direct.json"
  fi

  if [ -f "$templates_dir/profile-gateway-example.json" ]; then
    atomic_write "$target_dir/gateway-example.json" 0644 \
      < "$templates_dir/profile-gateway-example.json"
  fi
fi

exit 0
