#!/usr/bin/env bats
# Tests for scripts/list-profiles.sh — list all profiles with active markers
# per §7 /list row (as amended by A5) and §8 scripts row.
#
# Default tty output is a table with columns:
#   PROFILE | AUTH | GLOBAL | PROJECT | DRIFT
# --json emits a structured object. Both default modes route each profile's
# JSON through redact.sh before extracting any display field (A5 + A7).
# --verbose disables redaction and prints a stderr warning banner.

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

list_profiles() {
  run bash "$(cp_script list-profiles.sh)" "$@"
}

# write_profile <name> <json-body>
write_profile() {
  local name="$1"
  local body="$2"
  printf '%s' "$body" > "$PROFILES_DIR/${name}.json"
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
      global: (if $g == "" then {} else {active_profile:$g, managed_env_keys:["CLAUDE_PROFILES_ACTIVE"]} end),
      projects: ($repo | if . == "" then {} else {($repo):{active_profile:$p, managed_env_keys:["CLAUDE_PROFILES_ACTIVE"]}} end)
    }' > "$SIDECAR"
}

make_repo() {
  local path="$1"
  mkdir -p "$path"
  (cd "$path" && git init -q)
  (cd "$path" && git rev-parse --show-toplevel)
}

# ============================================================
# Empty / missing state
# ============================================================

@test "empty profile dir: exit 0 with a human-readable 'no profiles' message" {
  # Profile dir exists but contains no *.json files; no sidecar either.
  list_profiles
  assert_success
  assert_output --partial "no profiles"
}

@test "profile dir does not exist: exit 0, treated as empty" {
  rm -rf "$PROFILES_DIR"
  list_profiles
  assert_success
  assert_output --partial "no profiles"
}

@test "single profile, no sidecar: listed with empty GLOBAL/PROJECT markers" {
  # No sidecar. The script must tolerate this (exit 0) and show empty
  # active columns. Sidecar_read_scope refuses on missing, but /list owns
  # its own sidecar-presence check.
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  list_profiles
  assert_success
  assert_output --partial "direct"
  assert_output --partial "none"
}

# ============================================================
# Single profile + global active
# ============================================================

@test "single profile, global active: global column shows marker" {
  write_profile "gateway" '{"name":"gateway","auth":{"type":"helper_script","path":"/Users/alice/tok.sh"}}'
  write_sidecar_global "gateway"
  list_profiles
  assert_success
  assert_output --partial "gateway"
  assert_output --partial "helper_script"
  # Marker for global active (column content is "*")
  assert_output --partial "*"
}

@test "multiple profiles, only one is globally active: only that one is marked" {
  write_profile "gateway" '{"name":"gateway","auth":{"type":"helper_script","path":"/Users/alice/tok.sh"}}'
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  write_sidecar_global "gateway"
  list_profiles --json
  assert_success
  json="$output"
  run jq -r '.profiles[] | select(.name=="gateway") | .global_active' <<< "$json"
  assert_output "true"
  run jq -r '.profiles[] | select(.name=="direct") | .global_active' <<< "$json"
  assert_output "false"
}

# ============================================================
# Project scope
# ============================================================

@test "inside git repo with project active: project column marker appears" {
  REPO="$(make_repo "$HOME/my-repo")"
  write_profile "gateway" '{"name":"gateway","auth":{"type":"helper_script","path":"/Users/alice/tok.sh"}}'
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  write_sidecar_both "gateway" "$REPO" "direct"
  cd "$REPO"
  run bash "$(cp_script list-profiles.sh)" --json
  assert_success
  json="$output"
  run jq -r '.profiles[] | select(.name=="gateway") | .global_active' <<< "$json"
  assert_output "true"
  run jq -r '.profiles[] | select(.name=="direct") | .project_active' <<< "$json"
  assert_output "true"
  run jq -r '.profiles[] | select(.name=="gateway") | .project_active' <<< "$json"
  assert_output "false"
}

@test "outside a git repo: project_active is null in JSON" {
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  write_sidecar_global "direct"
  cd "$HOME"  # not a repo
  run bash "$(cp_script list-profiles.sh)" --json
  assert_success
  run jq -r '.profiles[] | select(.name=="direct") | .project_active' <<< "$output"
  assert_output "null"
}

# ============================================================
# --json output structure
# ============================================================

@test "--json emits top-level 'profiles' array" {
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  write_sidecar_global ""
  list_profiles --json
  assert_success
  run jq -r '.profiles | type' <<< "$output"
  assert_output "array"
}

@test "--json profile entries have name, auth_type, global_active, project_active, drift" {
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  write_sidecar_global "direct"
  list_profiles --json
  assert_success
  json="$output"
  run jq -r '.profiles[0] | has("name") and has("auth_type") and has("global_active") and has("project_active") and has("drift")' <<< "$json"
  assert_output "true"
}

@test "--json: profile with no sidecar state present shows global_active=false" {
  # Sidecar has some OTHER profile active — this one should be false.
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  write_profile "gateway" '{"name":"gateway","auth":{"type":"helper_script","path":"/x.sh"}}'
  write_sidecar_global "gateway"
  list_profiles --json
  assert_success
  run jq -r '.profiles[] | select(.name=="direct") | .global_active' <<< "$output"
  assert_output "false"
}

@test "--json: empty profile dir yields empty profiles array, exit 0" {
  list_profiles --json
  assert_success
  run jq -r '.profiles | length' <<< "$output"
  assert_output "0"
}

# ============================================================
# Redaction (default) via redact.sh
# ============================================================

@test "default output redacts auth.path (helper_script)" {
  write_profile "gateway" '{"name":"gateway","auth":{"type":"helper_script","path":"/Users/alice/secret/token.sh"}}'
  write_sidecar_global ""
  list_profiles
  assert_success
  refute_output --partial "alice"
  refute_output --partial "token.sh"
}

@test "default --json redacts auth.path (helper_script)" {
  write_profile "gateway" '{"name":"gateway","auth":{"type":"helper_script","path":"/Users/alice/secret/token.sh"}}'
  write_sidecar_global ""
  list_profiles --json
  assert_success
  refute_output --partial "alice"
  refute_output --partial "token.sh"
}

@test "default output redacts auth.var (env_var)" {
  write_profile "by-env" '{"name":"by-env","auth":{"type":"env_var","var":"VAULT_TOKEN"}}'
  write_sidecar_global ""
  list_profiles
  assert_success
  refute_output --partial "VAULT_TOKEN"
}

@test "default output redacts auth.service (keychain)" {
  write_profile "kc" '{"name":"kc","auth":{"type":"keychain","service":"company-gateway","account":"alice"}}'
  write_sidecar_global ""
  list_profiles
  assert_success
  refute_output --partial "company-gateway"
  refute_output --partial "alice"
}

@test "base_url redacted to hostname-only in default mode" {
  write_profile "gateway" '{"name":"gateway","base_url":"https://ai.simpli.fi/v1/abc/def","auth":{"type":"none"}}'
  write_sidecar_global ""
  list_profiles --json
  assert_success
  # Output must not leak full path segments.
  refute_output --partial "/v1/abc/def"
}

@test "localhost base_url kept verbatim even in default mode" {
  write_profile "local" '{"name":"local","base_url":"http://localhost:8080/v1","auth":{"type":"none"}}'
  write_sidecar_global ""
  list_profiles --json
  assert_success
  assert_output --partial "http://localhost:8080/v1"
}

# ============================================================
# --verbose
# ============================================================

@test "--verbose shows full auth.path (helper_script)" {
  write_profile "gateway" '{"name":"gateway","auth":{"type":"helper_script","path":"/Users/alice/secret/token.sh"}}'
  write_sidecar_global ""
  list_profiles --verbose
  assert_success
  assert_output --partial "/Users/alice/secret/token.sh"
}

@test "--verbose prints stderr warning banner" {
  write_profile "gateway" '{"name":"gateway","auth":{"type":"helper_script","path":"/Users/alice/secret/token.sh"}}'
  write_sidecar_global ""
  stderr_file="$HOME/stderr"
  run bash -c "bash '$(cp_script list-profiles.sh)' --verbose 2>'$stderr_file'"
  assert_success
  run cat "$stderr_file"
  assert_output --partial "--verbose"
}

@test "--verbose --json passes full base_url through" {
  write_profile "gateway" '{"name":"gateway","base_url":"https://ai.simpli.fi/v1/abc/def","auth":{"type":"none"}}'
  write_sidecar_global ""
  list_profiles --verbose --json
  assert_success
  assert_output --partial "https://ai.simpli.fi/v1/abc/def"
}

# ============================================================
# Invalid JSON files in profile dir
# ============================================================

@test "invalid JSON profile: skipped with stderr warning; valid profiles still listed" {
  write_profile "good" '{"name":"good","auth":{"type":"none"}}'
  printf 'not json {{{' > "$PROFILES_DIR/broken.json"
  write_sidecar_global ""

  stderr_file="$HOME/stderr"
  run bash -c "bash '$(cp_script list-profiles.sh)' 2>'$stderr_file'"
  assert_success
  assert_output --partial "good"
  refute_output --partial "broken"

  run cat "$stderr_file"
  assert_output --partial "broken"
}

@test "invalid JSON profile: --json still emits array containing only valid profiles" {
  write_profile "good" '{"name":"good","auth":{"type":"none"}}'
  printf 'not json {{{' > "$PROFILES_DIR/broken.json"
  write_sidecar_global ""

  # Redirect stderr to a file so we can jq-parse pure stdout — the
  # skip warning goes to stderr and `run` would otherwise merge it in.
  stderr_file="$HOME/stderr"
  run bash -c "bash '$(cp_script list-profiles.sh)' --json 2>'$stderr_file'"
  assert_success
  json="$output"
  run jq -r '.profiles | length' <<< "$json"
  assert_output "1"
  run jq -r '.profiles[0].name' <<< "$json"
  assert_output "good"
}

# ============================================================
# Corrupt sidecar behavior
# ============================================================

@test "corrupt sidecar: exits 1 with recovery hint" {
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  printf 'not json {{{' > "$SIDECAR"
  list_profiles
  assert_failure 1
  assert_output --partial "doctor"
}

# ============================================================
# Bad flags
# ============================================================

@test "unknown flag exits 2" {
  list_profiles --bogus-flag
  assert_failure 2
}

# ============================================================
# Drift column / field
# ============================================================

@test "drift field present in --json (default false when no mismatch)" {
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  write_sidecar_global "direct"
  # Write global settings that agree with sidecar (no drift).
  jq -n '{env:{CLAUDE_PROFILES_ACTIVE:"direct"}}' > "$GLOBAL_SETTINGS"
  list_profiles --json
  assert_success
  run jq -r '.profiles[] | select(.name=="direct") | .drift.global' <<< "$output"
  assert_output "false"
}

@test "drift on global: env marker disagrees with sidecar => drift.global true" {
  write_profile "direct" '{"name":"direct","auth":{"type":"none"}}'
  write_profile "gateway" '{"name":"gateway","auth":{"type":"helper_script","path":"/x.sh"}}'
  write_sidecar_global "gateway"
  jq -n '{env:{CLAUDE_PROFILES_ACTIVE:"direct"}}' > "$GLOBAL_SETTINGS"
  list_profiles --json
  assert_success
  # Drift is reported against the sidecar's active profile — gateway.
  run jq -r '.profiles[] | select(.name=="gateway") | .drift.global' <<< "$output"
  assert_output "true"
}
