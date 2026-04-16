#!/usr/bin/env bash
# get-active.sh [--scope=global|project|effective] [--json] [--verbose]
#
# Reads the active profile name from the sidecar and cross-checks it
# against the CLAUDE_PROFILES_ACTIVE env marker in the target settings
# file. Reports drift as data (open item #1 ruling: READ commands exit 0
# on successful reads; drift surfaces via the JSON `drift` field).
#
# Exit codes per §10:
#   0 — success (including drift detected — drift is data, not failure)
#   1 — sidecar missing or corrupt (from sidecar_read_scope, A2.2)
#   2 — usage error (bad flag, --scope=project outside a git repo)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# ============================================================
# Parse arguments
# ============================================================
scope="effective"
want_json=0
want_verbose=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scope=*)
      scope="${1#--scope=}"
      case "$scope" in
        global|project|effective) ;;
        *) die_usage "unknown scope '$scope' (valid: global, project, effective)" ;;
      esac
      ;;
    --json) want_json=1 ;;
    --verbose) want_verbose=1 ;;
    --*) die_usage "unknown flag: $1" ;;
    *) die_usage "unexpected argument: $1" ;;
  esac
  shift
done

# ============================================================
# Resolve scope → sidecar scope key + target settings path.
# For --scope=effective: prefer project (if in a repo AND has an
# active profile), else global.
# ============================================================

# resolve_repo_root — prints the absolute path to the git repo root,
# or empty if not inside a repo.
resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || true
}

# read_env_marker <settings-path> — reads .env.CLAUDE_PROFILES_ACTIVE
# from a settings file, or empty if file missing / key absent.
read_env_marker() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 0; }
  # Guard against corrupt settings — treat as no marker rather than
  # crashing a read-path script.
  if ! jq empty "$f" 2>/dev/null; then
    printf ''
    return 0
  fi
  jq -r '.env.CLAUDE_PROFILES_ACTIVE // empty' "$f"
}

# read_scope_active <scope-json> — prints the active_profile or empty.
read_scope_active() {
  printf '%s' "$1" | jq -r '.active_profile // empty'
}

# Compute sidecar scope keys and settings path per chosen scope.
repo_root="$(resolve_repo_root)"

case "$scope" in
  global)
    scope_out="global"
    sidecar_key="global"
    settings_path="$HOME/.claude/settings.local.json"
    ;;
  project)
    if [ -z "$repo_root" ]; then
      die_usage "--scope=project requires being inside a git repository"
    fi
    scope_out="project"
    # sidecar key: projects["<abs repo path>"]
    sidecar_key="projects[\"$repo_root\"]"
    settings_path="$repo_root/.claude/settings.local.json"
    ;;
  effective)
    # Try project first if in a repo; fall back to global.
    if [ -n "$repo_root" ]; then
      proj_scope_json="$(sidecar_read_scope "projects[\"$repo_root\"]")" || exit "$CP_EXIT_RUNTIME"
      proj_active="$(read_scope_active "$proj_scope_json")"
      if [ -n "$proj_active" ]; then
        scope_out="project"
        sidecar_key="projects[\"$repo_root\"]"
        settings_path="$repo_root/.claude/settings.local.json"
      else
        scope_out="global"
        sidecar_key="global"
        settings_path="$HOME/.claude/settings.local.json"
      fi
    else
      scope_out="global"
      sidecar_key="global"
      settings_path="$HOME/.claude/settings.local.json"
    fi
    ;;
esac

# ============================================================
# Read sidecar entry for chosen scope (A2.2 handles missing/corrupt).
# Also read the env marker from the target settings file.
# ============================================================
scope_json="$(sidecar_read_scope "$sidecar_key")" || exit "$CP_EXIT_RUNTIME"
active_profile="$(read_scope_active "$scope_json")"
env_marker="$(read_env_marker "$settings_path")"

# Drift detection: env marker and sidecar disagree.
# If the env marker is empty, we treat it as "stale/unmaterialized" —
# not drift. Drift requires two concrete, disagreeing values (A session
# that hasn't been restarted after a switch is the canonical benign case.)
drift_detected="false"
if [ -n "$env_marker" ] && [ -n "$active_profile" ] \
     && [ "$env_marker" != "$active_profile" ]; then
  drift_detected="true"
fi

# ============================================================
# Emit output
# ============================================================

if [ "$want_verbose" -eq 1 ]; then
  printf 'claude-profiles: --verbose output contains paths and env var names. Only use in private.\n' >&2
fi

if [ "$want_json" -eq 1 ]; then
  # Always JSON-null the active_profile if sidecar has none.
  active_json_arg="$active_profile"
  if [ -z "$active_profile" ]; then
    out="$(jq -nc \
      --arg scope "$scope_out" \
      --argjson drift_detected "$drift_detected" \
      --arg env_marker "$env_marker" \
      --arg sidecar "$active_profile" \
      '{
        scope: $scope,
        active_profile: null,
        drift: {
          detected: $drift_detected,
          env_marker: $env_marker,
          sidecar: $sidecar
        }
      }')"
  else
    out="$(jq -nc \
      --arg scope "$scope_out" \
      --arg active "$active_json_arg" \
      --argjson drift_detected "$drift_detected" \
      --arg env_marker "$env_marker" \
      --arg sidecar "$active_profile" \
      '{
        scope: $scope,
        active_profile: $active,
        drift: {
          detected: $drift_detected,
          env_marker: $env_marker,
          sidecar: $sidecar
        }
      }')"
  fi

  if [ "$want_verbose" -eq 1 ]; then
    out="$(printf '%s' "$out" | jq -c \
      --arg settings "$settings_path" \
      --arg sidecar_key "$sidecar_key" \
      '. + {verbose: {settings_path: $settings, sidecar_key: $sidecar_key}}')"
  fi

  printf '%s\n' "$out"
else
  if [ -z "$active_profile" ]; then
    printf '(no active profile) [scope=%s]\n' "$scope_out"
  else
    printf 'active profile: %s [scope=%s]\n' "$active_profile" "$scope_out"
  fi
  if [ "$drift_detected" = "true" ]; then
    printf 'drift: sidecar=%s, env=%s (session may need restart or repair)\n' \
      "$active_profile" "$env_marker"
  fi
  if [ "$want_verbose" -eq 1 ]; then
    printf 'settings file: %s\n' "$settings_path"
    printf 'sidecar scope: %s\n' "$sidecar_key"
  fi
fi

exit "$CP_EXIT_OK"
