#!/usr/bin/env bash
# apply-profile.sh <name> [--scope=global] [--accept-drift=overwrite]
#
# Core switch logic per §5 as amended by A3. Applies a profile to
# settings.local.json + sidecar atomically, with drift detection,
# advisory locking, and crash-safe sidecar-first write ordering.
#
# Scope: v0.1.0-rc2 supports global scope + auth types 'none' and
# 'helper_script' (env_var/keychain require render-apikey-helper.sh from
# ads.2). Drift resolution supports overwrite + cancel; incorporate is
# a follow-up.

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# ============================================================
# Parse arguments
# ============================================================
profile_name=""
scope="global"
accept_drift=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope=*) scope="${1#--scope=}" ;;
    --accept-drift=*) accept_drift="${1#--accept-drift=}" ;;
    --*) die_usage "unknown flag: $1" ;;
    *)
      if [ -z "$profile_name" ]; then
        profile_name="$1"
      else
        die_usage "unexpected argument: $1"
      fi
      ;;
  esac
  shift
done

[ -n "$profile_name" ] || die_usage "apply-profile.sh <name> [--scope=global] [--accept-drift=overwrite]"

case "$scope" in
  global) settings_path="$HOME/.claude/settings.local.json" ;;
  project) die_usage "project scope not yet implemented" ;;
  *) die_usage "unknown scope: $scope" ;;
esac

profile_path="$(profile_dir)/${profile_name}.json"
[ -f "$profile_path" ] || die_not_found "$profile_name"

# ============================================================
# Step 0: Preflight — validate the profile (A3 step 0, invariant 9)
# ============================================================
validate_script="$(dirname "$0")/validate-profile.sh"
if ! bash "$validate_script" "$profile_path" >&2; then
  exit "$CP_EXIT_SCHEMA"
fi

# ============================================================
# Step 1: Acquire advisory lock (§12a)
# ============================================================
mkdir -p "$(profile_dir)"
LOCK_DIR="$(profile_dir)/.state.lock"
if ! lock_acquire "$LOCK_DIR"; then
  printf 'claude-profiles: another switch is in progress (lock held)\n' >&2
  exit "$CP_EXIT_RUNTIME"
fi
trap 'lock_release "$LOCK_DIR"' EXIT

# ============================================================
# Step 2: Read target settings file from disk
# ============================================================
mkdir -p "$(dirname "$settings_path")"
if [ -f "$settings_path" ]; then
  settings_content="$(cat "$settings_path")"
  if ! printf '%s' "$settings_content" | jq empty 2>/dev/null; then
    printf 'claude-profiles: settings.local.json is not valid JSON: %s\n' "$settings_path" >&2
    exit "$CP_EXIT_RUNTIME"
  fi
else
  settings_content='{}'
fi

# ============================================================
# Step 3: Read sidecar scope entry (A2.2 handles missing/corrupt)
# ============================================================
if [ -f "$(sidecar_path)" ]; then
  prev_scope_json="$(sidecar_read_scope "$scope")" || exit "$CP_EXIT_RUNTIME"
else
  prev_scope_json='{}'
fi

prev_managed_keys="$(printf '%s' "$prev_scope_json" | jq -r '.managed_env_keys // [] | .[]' 2>/dev/null || true)"
prev_managed_values_json="$(printf '%s' "$prev_scope_json" | jq -c '.managed_env_values // {}')"
prev_managed_api_key_helper="$(printf '%s' "$prev_scope_json" | jq -r '.managed_api_key_helper // false')"
prev_managed_api_key_helper_value="$(printf '%s' "$prev_scope_json" | jq -r '.managed_api_key_helper_value // ""')"

# ============================================================
# Step 4: Drift detection (BEFORE any mutation). Captures both the
# list of drifted keys and their actual on-disk values — the actual
# values are needed by the incorporate path (A4 step 4).
# ============================================================
drift_keys=""
drift_actual_values='{}'
drift_api_key_helper="false"
for key in $prev_managed_keys; do
  expected="$(printf '%s' "$prev_managed_values_json" | jq -r --arg k "$key" '.[$k] // ""')"
  actual="$(printf '%s' "$settings_content" | jq -r --arg k "$key" '.env[$k] // ""')"
  if [ "$expected" != "$actual" ]; then
    drift_keys="$drift_keys $key"
    drift_actual_values="$(printf '%s' "$drift_actual_values" | jq --arg k "$key" --arg v "$actual" '.[$k] = $v')"
  fi
done

if [ "$prev_managed_api_key_helper" = "true" ]; then
  actual_helper="$(printf '%s' "$settings_content" | jq -r '.apiKeyHelper // ""')"
  if [ "$actual_helper" != "$prev_managed_api_key_helper_value" ]; then
    drift_keys="$drift_keys apiKeyHelper"
    drift_api_key_helper="true"
  fi
fi

if [ -n "$drift_keys" ]; then
  case "$accept_drift" in
    overwrite)
      : # proceed; new profile's values win for everything
      ;;
    incorporate)
      if [ "$drift_api_key_helper" = "true" ]; then
        printf 'claude-profiles: apiKeyHelper drift cannot be incorporated via --accept-drift=incorporate.\n' >&2
        printf '  Per-helper confirmation required (A4 step 4). Use --accept-drift=overwrite or revert the apiKeyHelper edit.\n' >&2
        exit "$CP_EXIT_DRIFT"
      fi
      : # proceed; drifted env keys not in new_managed will be re-inserted as unmanaged
      ;;
    *)
      printf 'claude-profiles: drift detected in managed keys:%s\n' "$drift_keys" >&2
      printf '  Re-run with --accept-drift=overwrite to apply the new profile,\n' >&2
      printf '  or --accept-drift=incorporate to preserve unmanaged edits.\n' >&2
      exit "$CP_EXIT_DRIFT"
      ;;
  esac
fi

# ============================================================
# Step 5: Compute new managed set (with denylist defense-in-depth)
# ============================================================
profile_json="$(cat "$profile_path")"
auth_type="$(printf '%s' "$profile_json" | jq -r '.auth.type')"
base_url="$(printf '%s' "$profile_json" | jq -r '.base_url // ""')"
ttl_ms="$(printf '%s' "$profile_json" | jq -r '.ttl_ms // ""')"
extras_keys="$(printf '%s' "$profile_json" | jq -r '.extras // {} | keys[]' 2>/dev/null || true)"

# Verify extras disjoint from denylist (A1.2 defense-in-depth).
for key in $extras_keys; do
  if is_denylisted "$key"; then
    die_schema "extras key '$key' is in EXTRAS_DENYLIST (caught at apply-time)"
  fi
done

# Build the set of keys that WILL be managed by the new profile (names
# only). Needed by step 7 (incorporate) to distinguish drifted keys that
# stay plugin-managed from drifted keys that get demoted to unmanaged.
new_managed_keys_list="CLAUDE_PROFILES_ACTIVE"
if [ -n "$base_url" ] && [ "$base_url" != "null" ]; then
  new_managed_keys_list="$new_managed_keys_list ANTHROPIC_BASE_URL"
fi
if [ -n "$ttl_ms" ] && [ "$ttl_ms" != "null" ]; then
  new_managed_keys_list="$new_managed_keys_list CLAUDE_CODE_API_KEY_HELPER_TTL_MS"
fi
for key in $extras_keys; do
  new_managed_keys_list="$new_managed_keys_list $key"
done

# Resolve helper path for helper_script (Q7: expand ~, fail loud if missing/non-exec).
new_managed_api_key_helper="false"
new_api_key_helper_value=""
case "$auth_type" in
  helper_script)
    helper_path="$(printf '%s' "$profile_json" | jq -r '.auth.path')"
    # shellcheck disable=SC2088  # matching literal tilde in case pattern, not path expansion
    case "$helper_path" in
      "~/"*) helper_path="$HOME/${helper_path:2}" ;;
      "~")   helper_path="$HOME" ;;
    esac
    if [ ! -f "$helper_path" ]; then
      printf 'claude-profiles: helper_script path does not exist: %s\n' "$helper_path" >&2
      exit "$CP_EXIT_RUNTIME"
    fi
    if [ ! -x "$helper_path" ]; then
      printf 'claude-profiles: helper_script path is not executable: %s\n' "$helper_path" >&2
      exit "$CP_EXIT_RUNTIME"
    fi
    new_managed_api_key_helper="true"
    new_api_key_helper_value="$helper_path"
    ;;
  env_var|keychain)
    die_usage "auth.type=$auth_type requires render-apikey-helper.sh (ads.2) — not available in v0.1.0-rc2"
    ;;
  none)
    :
    ;;
  *)
    die_schema "unknown auth.type: $auth_type"
    ;;
esac

# ============================================================
# Step 6: Remove old managed keys from settings
# ============================================================
new_settings="$settings_content"
for key in $prev_managed_keys; do
  new_settings="$(printf '%s' "$new_settings" | jq --arg k "$key" 'if .env then del(.env[$k]) else . end')"
done
if [ "$prev_managed_api_key_helper" = "true" ]; then
  new_settings="$(printf '%s' "$new_settings" | jq 'del(.apiKeyHelper)')"
fi

# ============================================================
# Step 7: Handle drift-incorporated unmanaged keys (A4 step 4).
# For each drifted env key that is NOT in the new profile's managed
# set, re-insert its actual (drifted) value as unmanaged. These survive
# the switch and are excluded from sidecar tracking.
# ============================================================
if [ "$accept_drift" = "incorporate" ] && [ -n "$drift_keys" ]; then
  while IFS= read -r dkey; do
    [ -z "$dkey" ] && continue
    # Is this drifted key in the new managed set?
    in_new_managed=0
    for nmk in $new_managed_keys_list; do
      [ "$nmk" = "$dkey" ] && { in_new_managed=1; break; }
    done
    if [ "$in_new_managed" -eq 0 ]; then
      dvalue="$(printf '%s' "$drift_actual_values" | jq -r --arg k "$dkey" '.[$k]')"
      new_settings="$(printf '%s' "$new_settings" | jq --arg k "$dkey" --arg v "$dvalue" '.env[$k] = $v')"
    fi
  done < <(printf '%s' "$drift_actual_values" | jq -r 'keys[]')
fi

# ============================================================
# Step 8: Write new keys into settings
# Merge order: extras first, plugin-managed keys last (A3 step 5).
# ============================================================
new_managed_values_json='{}'

# Extras first (plugin keys override on conflict per A3 step 5).
for key in $extras_keys; do
  value="$(printf '%s' "$profile_json" | jq -r --arg k "$key" '.extras[$k]')"
  new_settings="$(printf '%s' "$new_settings" | jq --arg k "$key" --arg v "$value" '.env[$k] = $v')"
  new_managed_values_json="$(printf '%s' "$new_managed_values_json" | jq --arg k "$key" --arg v "$value" '.[$k] = $v')"
done

# Plugin-managed keys last.
new_settings="$(printf '%s' "$new_settings" | jq --arg name "$profile_name" '.env.CLAUDE_PROFILES_ACTIVE = $name')"
new_managed_values_json="$(printf '%s' "$new_managed_values_json" | jq --arg name "$profile_name" '.CLAUDE_PROFILES_ACTIVE = $name')"

if [ -n "$base_url" ] && [ "$base_url" != "null" ]; then
  new_settings="$(printf '%s' "$new_settings" | jq --arg v "$base_url" '.env.ANTHROPIC_BASE_URL = $v')"
  new_managed_values_json="$(printf '%s' "$new_managed_values_json" | jq --arg v "$base_url" '.ANTHROPIC_BASE_URL = $v')"
fi

if [ -n "$ttl_ms" ] && [ "$ttl_ms" != "null" ]; then
  new_settings="$(printf '%s' "$new_settings" | jq --arg v "$ttl_ms" '.env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS = $v')"
  new_managed_values_json="$(printf '%s' "$new_managed_values_json" | jq --arg v "$ttl_ms" '.CLAUDE_CODE_API_KEY_HELPER_TTL_MS = $v')"
fi

if [ "$new_managed_api_key_helper" = "true" ]; then
  new_settings="$(printf '%s' "$new_settings" | jq --arg v "$new_api_key_helper_value" '.apiKeyHelper = $v')"
fi

# ============================================================
# Step 9: Atomic sidecar write (FIRST — crash-safe ordering)
# ============================================================
new_managed_keys_json="$(printf '%s' "$new_managed_keys_list" | jq -Rsc 'split(" ") | map(select(length > 0))')"

new_scope_json="$(jq -nc \
  --argjson keys "$new_managed_keys_json" \
  --argjson values "$new_managed_values_json" \
  --arg active "$profile_name" \
  --argjson ak_helper "$new_managed_api_key_helper" \
  --arg ak_helper_val "$new_api_key_helper_value" \
  --arg target "$settings_path" \
  '{
    active_profile: $active,
    managed_env_keys: $keys,
    managed_env_values: $values,
    managed_api_key_helper: $ak_helper,
    managed_api_key_helper_value: $ak_helper_val,
    target_file: $target
  }')"

sidecar_write_scope "$scope" "$new_scope_json" || {
  printf 'claude-profiles: failed to write sidecar\n' >&2
  exit "$CP_EXIT_RUNTIME"
}

# ============================================================
# Step 10: Atomic target write (AFTER sidecar)
# ============================================================
printf '%s\n' "$new_settings" | atomic_write "$settings_path" || {
  printf 'claude-profiles: failed to write settings file\n' >&2
  exit "$CP_EXIT_RUNTIME"
}

# ============================================================
# Step 11: Post-apply stale-env check
# ============================================================
current_env_marker="${CLAUDE_PROFILES_ACTIVE:-}"
if [ "$current_env_marker" != "$profile_name" ]; then
  printf 'claude-profiles: profile switched to "%s". Restart Claude Code to activate.\n' "$profile_name" >&2
  exit "$CP_EXIT_RESTART_REQUIRED"
fi

# Step 12: lock released by trap.
exit "$CP_EXIT_OK"
