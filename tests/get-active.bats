#!/usr/bin/env bats
# Tests for scripts/get-active.sh — read active profile from settings
# file + sidecar with drift detection across scopes.
#
# Per §7 (as amended by A5) `/current` and open item #1 ruling: drift is
# reported as data on stdout, not a failure exit code. Exit 0 for
# successful reads (drift or not). Exit 1 only for truly broken sidecar
# state. Exit 2 only for bad arguments / --scope=project outside a repo.

setup() {
  load 'test_helper/common'
  setup_isolated_home
  PROFILES_DIR="$HOME/.claude/llm-profiles"
  GLOBAL_SETTINGS="$HOME/.claude/settings.local.json"
  SIDECAR="$PROFILES_DIR/.state.json"
  mkdir -p "$PROFILES_DIR"
  mkdir -p "$(dirname "$GLOBAL_SETTINGS")"
}

teardown() {
  teardown_isolated_home
}

# ---- helpers ----

get_active() {
  run bash "$(cp_script get-active.sh)" "$@"
}

# write_global_settings <profile-name>  — writes .env.CLAUDE_PROFILES_ACTIVE
# to the global settings.local.json.
write_global_settings() {
  local name="$1"
  if [ -z "$name" ]; then
    printf '{}' > "$GLOBAL_SETTINGS"
  else
    jq -n --arg n "$name" '{env:{CLAUDE_PROFILES_ACTIVE:$n}}' > "$GLOBAL_SETTINGS"
  fi
}

# write_project_settings <repo-path> <profile-name>
write_project_settings() {
  local repo="$1"
  local name="$2"
  mkdir -p "$repo/.claude"
  local f="$repo/.claude/settings.local.json"
  if [ -z "$name" ]; then
    printf '{}' > "$f"
  else
    jq -n --arg n "$name" '{env:{CLAUDE_PROFILES_ACTIVE:$n}}' > "$f"
  fi
}

# write_sidecar_global <profile-name-or-empty>
write_sidecar_global() {
  local name="$1"
  if [ -z "$name" ]; then
    printf '{}' > "$SIDECAR"
  else
    jq -n --arg n "$name" '{global:{active_profile:$n,managed_env_keys:["CLAUDE_PROFILES_ACTIVE"]}}' > "$SIDECAR"
  fi
}

# write_sidecar_both <global-name> <repo-path> <project-name>
write_sidecar_both() {
  local gname="$1"
  local repo="$2"
  local pname="$3"
  jq -n \
    --arg g "$gname" \
    --arg repo "$repo" \
    --arg p "$pname" \
    '{
      global: {active_profile:$g, managed_env_keys:["CLAUDE_PROFILES_ACTIVE"]},
      projects: ($repo | if . == "" then {} else {($repo):{active_profile:$p, managed_env_keys:["CLAUDE_PROFILES_ACTIVE"]}} end)
    }' > "$SIDECAR"
}

# make_repo <path> — creates a git repo rooted at <path>. Prints the
# canonical repo path (resolved via `git rev-parse --show-toplevel`) on
# stdout so sidecar keys match what get-active.sh will look up.
make_repo() {
  local path="$1"
  mkdir -p "$path"
  (cd "$path" && git init -q)
  (cd "$path" && git rev-parse --show-toplevel)
}

# ============================================================
# No active profile / no sidecar
# ============================================================

@test "no sidecar and no settings: exits 1 (sidecar missing per A2.2)" {
  # A2.2 applies: missing sidecar is an error, not silently treated as empty.
  get_active --scope=global
  assert_failure 1
  assert_output --partial "doctor"
}

@test "empty sidecar, no settings: --scope=global reports no active profile, exit 0" {
  write_sidecar_global ""
  get_active --scope=global
  assert_success
  assert_output --partial "no active profile"
}

# ============================================================
# Global happy path
# ============================================================

@test "global profile active, sidecar + settings agree: prints profile name" {
  write_sidecar_global "gateway"
  write_global_settings "gateway"
  get_active --scope=global
  assert_success
  assert_output --partial "gateway"
}

@test "global profile active, only sidecar set (no env in settings): reports profile" {
  write_sidecar_global "gateway"
  write_global_settings ""
  get_active --scope=global
  assert_success
  # Still reports the sidecar's answer — env just isn't materialized yet.
  assert_output --partial "gateway"
}

# ============================================================
# --json output shape
# ============================================================

@test "--json includes scope, active_profile, drift fields" {
  write_sidecar_global "gateway"
  write_global_settings "gateway"
  get_active --scope=global --json
  assert_success
  json="$output"
  run jq -r '.scope' <<< "$json"
  assert_output "global"
  run jq -r '.active_profile' <<< "$json"
  assert_output "gateway"
  run jq -r '.drift.detected' <<< "$json"
  assert_output "false"
}

@test "--json null active_profile when sidecar has no active profile" {
  write_sidecar_global ""
  get_active --scope=global --json
  assert_success
  run jq -r '.active_profile' <<< "$output"
  assert_output "null"
}

# ============================================================
# Drift scenarios — exit 0, drift reported as data
# ============================================================

@test "drift: sidecar says X, settings env has Y — exit 0, drift reported" {
  write_sidecar_global "gateway"
  write_global_settings "direct"  # env disagrees
  get_active --scope=global --json
  assert_success  # exit 0 per open-item ruling
  json="$output"
  run jq -r '.drift.detected' <<< "$json"
  assert_output "true"
  run jq -r '.drift.env_marker' <<< "$json"
  assert_output "direct"
  run jq -r '.drift.sidecar' <<< "$json"
  assert_output "gateway"
}

@test "drift: plain-text output includes a drift warning line" {
  write_sidecar_global "gateway"
  write_global_settings "direct"
  get_active --scope=global
  assert_success
  assert_output --partial "drift"
}

@test "no drift when settings has no env marker and sidecar has profile" {
  # This is not drift — env just isn't materialized (typical for a session
  # that hasn't restarted after a switch). Report as "stale" but not drift.
  write_sidecar_global "gateway"
  write_global_settings ""
  get_active --scope=global --json
  assert_success
  run jq -r '.drift.detected' <<< "$output"
  assert_output "false"
}

# ============================================================
# --scope=project
# ============================================================

@test "--scope=project outside a git repo exits 2 (usage)" {
  write_sidecar_global "gateway"
  cd "$HOME"  # not a repo
  get_active --scope=project
  assert_failure 2
}

@test "--scope=project inside a repo, no project profile active: reports null" {
  REPO="$(make_repo "$HOME/my-repo")"
  write_sidecar_both "gateway" "" ""
  cd "$REPO"
  run bash "$(cp_script get-active.sh)" --scope=project --json
  assert_success
  run jq -r '.active_profile' <<< "$output"
  assert_output "null"
}

@test "--scope=project inside a repo, project profile set: returns project profile" {
  REPO="$(make_repo "$HOME/my-repo")"
  write_sidecar_both "gateway" "$REPO" "project-gw"
  write_project_settings "$REPO" "project-gw"
  cd "$REPO"
  run bash "$(cp_script get-active.sh)" --scope=project --json
  assert_success
  json="$output"
  run jq -r '.active_profile' <<< "$json"
  assert_output "project-gw"
  run jq -r '.scope' <<< "$json"
  assert_output "project"
}

# ============================================================
# --scope=effective precedence
# ============================================================

@test "--scope=effective outside a git repo: falls back to global" {
  write_sidecar_global "gateway"
  write_global_settings "gateway"
  cd "$HOME"
  run bash "$(cp_script get-active.sh)" --scope=effective --json
  assert_success
  json="$output"
  run jq -r '.active_profile' <<< "$json"
  assert_output "gateway"
  run jq -r '.scope' <<< "$json"
  assert_output "global"
}

@test "--scope=effective inside a repo with project profile: project wins" {
  REPO="$(make_repo "$HOME/my-repo")"
  write_sidecar_both "global-gw" "$REPO" "project-gw"
  write_project_settings "$REPO" "project-gw"
  cd "$REPO"
  run bash "$(cp_script get-active.sh)" --scope=effective --json
  assert_success
  json="$output"
  run jq -r '.active_profile' <<< "$json"
  assert_output "project-gw"
  run jq -r '.scope' <<< "$json"
  assert_output "project"
}

@test "--scope=effective inside repo with NO project profile: falls back to global" {
  REPO="$(make_repo "$HOME/my-repo")"
  write_sidecar_both "global-gw" "" ""
  write_global_settings "global-gw"
  cd "$REPO"
  run bash "$(cp_script get-active.sh)" --scope=effective --json
  assert_success
  json="$output"
  run jq -r '.active_profile' <<< "$json"
  assert_output "global-gw"
  run jq -r '.scope' <<< "$json"
  assert_output "global"
}

@test "no flags defaults to --scope=effective" {
  write_sidecar_global "gateway"
  write_global_settings "gateway"
  cd "$HOME"
  run bash "$(cp_script get-active.sh)" --json
  assert_success
  json="$output"
  run jq -r '.scope' <<< "$json"
  assert_output "global"  # effective resolved to global outside a repo
  run jq -r '.active_profile' <<< "$json"
  assert_output "gateway"
}

# ============================================================
# Verbose mode + banner
# ============================================================

@test "--verbose emits banner to stderr" {
  write_sidecar_global "gateway"
  write_global_settings "gateway"
  get_active --scope=global --verbose
  assert_success
  assert_output --partial "paths"
}

# ============================================================
# Error paths
# ============================================================

@test "unknown flag exits 2" {
  write_sidecar_global "gateway"
  get_active --bogus-flag
  assert_failure 2
}

@test "bad --scope value exits 2" {
  write_sidecar_global "gateway"
  get_active --scope=bogus
  assert_failure 2
}

@test "corrupt sidecar exits 1 with recovery hint" {
  printf 'not json {{{' > "$SIDECAR"
  get_active --scope=global
  assert_failure 1
  assert_output --partial "doctor"
}
