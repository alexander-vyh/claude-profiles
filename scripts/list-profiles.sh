#!/usr/bin/env bash
# list-profiles.sh [--json] [--verbose]
#
# Lists every profile in profile_dir() with active markers for the global
# scope and (if inside a git repo) the project scope. Per §7 as amended by
# A5, all auth-branch fields and base_url are routed through redact.sh
# (A7) before display. --verbose disables redaction and emits a stderr
# warning banner.
#
# Exit codes per §10:
#   0 — success (including empty profile dir and no sidecar)
#   1 — sidecar corrupt (missing sidecar is NOT an error here — /list is a
#       pure read that tolerates an unbootstrapped profile dir)
#   2 — unknown flag / usage

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# ============================================================
# Parse arguments
# ============================================================
want_json=0
want_verbose=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) want_json=1 ;;
    --verbose) want_verbose=1 ;;
    --*) die_usage "unknown flag: $1" ;;
    *) die_usage "unexpected argument: $1" ;;
  esac
  shift
done

# ============================================================
# Resolve scope context
# ============================================================
pdir="$(profile_dir)"
sidecar="$(sidecar_path)"

repo_root=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi

# read_settings_env_marker <settings-path>
# Reads .env.CLAUDE_PROFILES_ACTIVE from the settings file, or empty if
# the file is missing/corrupt/absent the key. Never crashes on a corrupt
# settings file — /list is a read-only display path.
read_settings_env_marker() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  if ! jq empty "$f" 2>/dev/null; then
    printf ''
    return 0
  fi
  jq -r '.env.CLAUDE_PROFILES_ACTIVE // empty' "$f"
}

# ============================================================
# Read sidecar state (tolerates missing, refuses corrupt)
# ============================================================
sidecar_global_active=""
sidecar_project_active=""

if [ -f "$sidecar" ]; then
  if ! jq empty "$sidecar" 2>/dev/null; then
    printf 'claude-profiles: sidecar state file is corrupt: %s\n' "$sidecar" >&2
    printf '  Run /claude-profiles:doctor --fix to rebuild.\n' >&2
    exit "$CP_EXIT_RUNTIME"
  fi
  sidecar_global_active="$(jq -r '.global.active_profile // empty' "$sidecar")"
  if [ -n "$repo_root" ]; then
    sidecar_project_active="$(jq -r --arg r "$repo_root" '.projects[$r].active_profile // empty' "$sidecar")"
  fi
fi

# Env markers from the actual settings files (for drift detection).
global_settings_path="$HOME/.claude/settings.local.json"
global_env_marker="$(read_settings_env_marker "$global_settings_path")"

project_env_marker=""
if [ -n "$repo_root" ]; then
  project_env_marker="$(read_settings_env_marker "$repo_root/.claude/settings.local.json")"
fi

# Drift helpers: only mark drift when both sides are concrete and
# disagree (matches get-active.sh semantics).
drift_between() {
  local sidecar_val="$1"
  local env_val="$2"
  if [ -n "$sidecar_val" ] && [ -n "$env_val" ] \
       && [ "$sidecar_val" != "$env_val" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

global_drift="$(drift_between "$sidecar_global_active" "$global_env_marker")"
project_drift="false"
if [ -n "$repo_root" ]; then
  project_drift="$(drift_between "$sidecar_project_active" "$project_env_marker")"
fi

# ============================================================
# Iterate profile files and build a JSON array
# ============================================================

# Start with an empty profiles array.
profiles_json='[]'

if [ -d "$pdir" ]; then
  # Use a nullglob-style pattern: if no matches, the loop body does not run.
  shopt -s nullglob
  for f in "$pdir"/*.json; do
    # Skip non-regular files defensively.
    [ -f "$f" ] || continue

    # Parse as JSON first — skip with a stderr warning if broken.
    if ! jq empty "$f" 2>/dev/null; then
      printf 'claude-profiles: skipping invalid JSON profile: %s\n' "$f" >&2
      continue
    fi

    base="$(basename "$f" .json)"

    # Redact (or pass through) the profile JSON. We always drive the
    # display off the redact output so there is a single source of
    # truth for every displayed field.
    if [ "$want_verbose" -eq 1 ]; then
      # Verbose: pass through without invoking redact.sh (redact.sh's
      # --verbose pretty-prints which is fine, but invoking it here
      # would also trigger its stderr banner per profile — we emit our
      # own single banner below).
      display_json="$(jq -c '.' "$f")"
    else
      display_json="$(bash "$(dirname "$0")/redact.sh" "$f" | jq -c '.')"
    fi

    # Active/drift markers against THIS profile's name.
    this_name="$(printf '%s' "$display_json" | jq -r '.name // empty')"
    # If the name field was missing, fall back to filename basename so
    # we still show something — the validator would have flagged this
    # at create time; /list is a display path.
    [ -n "$this_name" ] || this_name="$base"

    if [ "$this_name" = "$sidecar_global_active" ] && [ -n "$sidecar_global_active" ]; then
      ga="true"
      gd="$global_drift"
    else
      ga="false"
      gd="false"
    fi

    if [ -z "$repo_root" ]; then
      # Outside a repo: project_active is null (not applicable).
      pa="null"
      pd="false"
    elif [ "$this_name" = "$sidecar_project_active" ] && [ -n "$sidecar_project_active" ]; then
      pa="true"
      pd="$project_drift"
    else
      pa="false"
      pd="false"
    fi

    # Derive auth_type from the (possibly redacted) JSON. auth.type is
    # never redacted per A7.
    auth_type="$(printf '%s' "$display_json" | jq -r '.auth.type // "unknown"')"

    # Derive a display-safe auth_detail for the table. Uses redacted
    # fields by default, original fields under --verbose.
    auth_detail="$(printf '%s' "$display_json" | jq -r '
      if .auth.type == "helper_script" then (.auth.path // "")
      elif .auth.type == "env_var" then (.auth.var // "")
      elif .auth.type == "keychain" then (.auth.service // "")
      elif .auth.type == "none" then ""
      else "" end
    ')"

    # base_url (already redacted by redact.sh in default mode, verbatim
    # otherwise). null when absent.
    base_url_json="$(printf '%s' "$display_json" | jq -c '.base_url // null')"

    # Append to profiles_json.
    profiles_json="$(printf '%s' "$profiles_json" | jq -c \
      --arg name "$this_name" \
      --arg auth_type "$auth_type" \
      --arg auth_detail "$auth_detail" \
      --argjson base_url "$base_url_json" \
      --argjson ga "$ga" \
      --argjson pa "$pa" \
      --argjson gd "$gd" \
      --argjson pd "$pd" \
      '. + [{
        name: $name,
        auth_type: $auth_type,
        auth_detail: $auth_detail,
        base_url: $base_url,
        global_active: $ga,
        project_active: $pa,
        drift: { global: $gd, project: $pd }
      }]')"
  done
  shopt -u nullglob
fi

# ============================================================
# Emit output
# ============================================================

if [ "$want_verbose" -eq 1 ]; then
  printf 'claude-profiles: --verbose disables redaction.\n' >&2
  printf 'This output contains paths and env var names that can be used for reconnaissance.\n' >&2
  printf 'Only use --verbose in private.\n' >&2
fi

if [ "$want_json" -eq 1 ]; then
  printf '%s' "$profiles_json" | jq '{profiles: .}'
  exit "$CP_EXIT_OK"
fi

# Plain-text mode
count="$(printf '%s' "$profiles_json" | jq 'length')"
if [ "$count" = "0" ]; then
  printf 'no profiles found in %s\n' "$pdir"
  exit "$CP_EXIT_OK"
fi

# Pretty table. AUTH column shows "<type>[:<detail>]" so /list surfaces
# the (already-redacted-by-default) path/var/service for at-a-glance
# identification.
printf '%-24s %-40s %-8s %-8s %-6s\n' "PROFILE" "AUTH" "GLOBAL" "PROJECT" "DRIFT"
printf '%s' "$profiles_json" | jq -r '.[] |
  [
    .name,
    (if (.auth_detail // "") == "" then .auth_type else (.auth_type + ":" + .auth_detail) end),
    (if .global_active then "*" else "" end),
    (if .project_active == true then "*" elif .project_active == null then "-" else "" end),
    (if (.drift.global or .drift.project) then "*" else "" end)
  ] | @tsv' | while IFS=$'\t' read -r name auth_type ga pa dr; do
  printf '%-24s %-40s %-8s %-8s %-6s\n' "$name" "$auth_type" "$ga" "$pa" "$dr"
done

exit "$CP_EXIT_OK"
