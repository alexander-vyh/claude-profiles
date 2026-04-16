#!/usr/bin/env bats
# Tests for scripts/doctor.sh — diagnostic + repair per §7, §8, and
# Amendment A5 (/doctor row). Covers schema checks, helper checks
# (executable bit only per invariant 8), sidecar integrity, drift,
# reachability probes, and --fix repair paths.

setup() {
  load 'test_helper/common'
  setup_isolated_home
  PROFILES_DIR="$HOME/.claude/llm-profiles"
  HELPERS_DIR="$PROFILES_DIR/.helpers"
  SETTINGS="$HOME/.claude/settings.local.json"
  SIDECAR="$PROFILES_DIR/.state.json"
}

teardown() {
  teardown_isolated_home
}

doctor() {
  run bash "$(cp_script doctor.sh)" "$@"
}

# Bootstrap a clean system with only our gateway profile + its helper.
# Avoid init.sh seeds — the gateway-example seed has a deliberately
# unresolved helper path and would always fail the helper check.
clean_gateway_setup() {
  mkdir -p "$PROFILES_DIR" "$HELPERS_DIR" "$(dirname "$SETTINGS")"
  chmod 0700 "$HELPERS_DIR"

  cat > "$PROFILES_DIR/gateway.json" << 'EOF'
{
  "name": "gateway",
  "base_url": "https://ai.simpli.fi",
  "auth": { "type": "helper_script", "path": "~/helper.sh" },
  "ttl_ms": 300000,
  "extras": { "LLM_GATEWAY": "1" }
}
EOF

  printf '#!/bin/sh\necho test-key\n' > "$HOME/helper.sh"
  chmod +x "$HOME/helper.sh"

  # Apply gateway (ignore exit 9 — the restart-required signal).
  bash "$(cp_script apply-profile.sh)" gateway >/dev/null 2>&1 || true
}

write_profile() {
  local name="$1"
  local json="$2"
  printf '%s' "$json" > "$PROFILES_DIR/$name.json"
}

# ============================================================
# Argument validation
# ============================================================

@test "doctor: unknown flag exits 2" {
  mkdir -p "$PROFILES_DIR"
  doctor --bogus
  assert_failure 2
}

@test "doctor: --help prints usage and exits 0" {
  doctor --help
  assert_success
}

# ============================================================
# Fresh / absent profile_dir — should not crash
# ============================================================

@test "doctor on bare system (no profile_dir): does not crash" {
  # No profile dir created.
  doctor
  # Accept either success (nothing to check) or runtime (1) — must not crash.
  [ "$status" -le 1 ]
}

# ============================================================
# Clean system (init + apply gateway) — everything OK
# ============================================================

@test "doctor on clean setup reports PROFILES section" {
  clean_gateway_setup
  doctor
  assert_output --partial "PROFILES"
}

@test "doctor on clean setup reports SIDECAR section" {
  clean_gateway_setup
  doctor
  assert_output --partial "SIDECAR"
}

@test "doctor on clean setup exits 0" {
  clean_gateway_setup
  doctor
  assert_success
}

@test "doctor --json on clean setup emits valid JSON with checks array" {
  clean_gateway_setup
  doctor --json
  assert_success
  # Must parse as JSON and have a .checks array
  echo "$output" | jq -e '.checks | type == "array"' >/dev/null
}

# ============================================================
# Schema check — invalid profile JSON
# ============================================================

@test "doctor reports schema failure for invalid profile" {
  clean_gateway_setup
  # Create a broken profile: invalid auth.type
  write_profile "broken" '{"name": "broken", "auth": {"type": "magic"}}'
  doctor
  assert_output --partial "broken"
}

@test "doctor --json flags schema fail for invalid profile" {
  clean_gateway_setup
  write_profile "broken" '{"name": "broken", "auth": {"type": "magic"}}'
  doctor --json
  # A schema-fail status for the broken profile must be present
  echo "$output" | jq -e '.checks | map(select(.category == "schema" and .profile == "broken" and .status == "fail")) | length > 0' >/dev/null
}

# ============================================================
# Helper check — helper_script branch
# ============================================================

@test "doctor reports missing helper for helper_script profile" {
  clean_gateway_setup
  # Remove the helper
  rm -f "$HOME/helper.sh"
  doctor
  assert_output --partial "helper"
}

@test "doctor --json reports helper-script missing" {
  clean_gateway_setup
  rm -f "$HOME/helper.sh"
  doctor --json
  echo "$output" | jq -e '.checks | map(select(.category == "helper" and .status == "fail")) | length > 0' >/dev/null
}

@test "doctor reports non-executable helper" {
  clean_gateway_setup
  chmod -x "$HOME/helper.sh"
  doctor --json
  echo "$output" | jq -e '.checks | map(select(.category == "helper" and .status == "fail")) | length > 0' >/dev/null
}

# ============================================================
# Helper check — env_var shim drift / missing
# ============================================================

@test "doctor reports missing env_var shim" {
  clean_gateway_setup
  write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN" }
  }'
  # Shim never rendered
  doctor --json
  echo "$output" | jq -e '.checks | map(select(.category == "helper" and .profile == "vault" and .status == "fail")) | length > 0' >/dev/null
}

@test "doctor reports drifted env_var shim" {
  clean_gateway_setup
  write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN" }
  }'
  # Render the shim, then corrupt it
  bash "$(cp_script render-apikey-helper.sh)" "$PROFILES_DIR/vault.json" >/dev/null
  printf '#!/bin/sh\necho tampered\n' > "$HELPERS_DIR/vault.sh"
  chmod 0700 "$HELPERS_DIR/vault.sh"
  doctor --json
  echo "$output" | jq -e '.checks | map(select(.category == "helper" and .profile == "vault" and .status == "fail")) | length > 0' >/dev/null
}

# ============================================================
# Sidecar integrity
# ============================================================

@test "doctor reports missing sidecar" {
  clean_gateway_setup
  rm -f "$SIDECAR"
  doctor --json
  echo "$output" | jq -e '.checks | map(select(.category == "sidecar" and .status == "fail")) | length > 0' >/dev/null
}

@test "doctor reports corrupt sidecar" {
  clean_gateway_setup
  printf 'not json {{{' > "$SIDECAR"
  doctor --json
  echo "$output" | jq -e '.checks | map(select(.category == "sidecar" and .status == "fail")) | length > 0' >/dev/null
}

# ============================================================
# Drift detection
# ============================================================

@test "doctor detects drift in managed env key and exits 8" {
  clean_gateway_setup
  # User hand-edits ANTHROPIC_BASE_URL
  jq '.env.ANTHROPIC_BASE_URL = "https://hacked.example.com"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  doctor
  assert_failure 8
  assert_output --partial "drift"
}

@test "doctor --json reports drift" {
  clean_gateway_setup
  jq '.env.ANTHROPIC_BASE_URL = "https://hacked.example.com"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  doctor --json
  echo "$output" | jq -e '.checks | map(select(.category == "drift" and .status == "fail")) | length > 0' >/dev/null
}

# ============================================================
# Curl reachability probe (A5)
# ============================================================

@test "doctor reports reachability SKIPPED when curl is absent" {
  clean_gateway_setup
  # Scrub PATH so curl is not found — but keep essentials.
  # Use a dedicated bin dir with only the bare minimum.
  scrubbed="$CP_TEST_HOME/scrubbed-bin"
  mkdir -p "$scrubbed"
  for cmd in bash sh jq mv rm cat cp ls mkdir rmdir chmod find grep sed basename dirname date env printf readlink diff mktemp uname; do
    cmd_path=$(command -v "$cmd" 2>/dev/null) || continue
    ln -s "$cmd_path" "$scrubbed/$cmd" 2>/dev/null || true
  done
  PATH="$scrubbed" run bash "$(cp_script doctor.sh)"
  [[ "$output" == *"SKIPPED"* ]]
}

# ============================================================
# Orphan cleanup (--fix)
# ============================================================

@test "doctor detects orphaned shim for deleted profile" {
  clean_gateway_setup
  # Render a shim for a profile, then delete the profile
  write_profile "ghost" '{
    "name": "ghost",
    "auth": { "type": "env_var", "var": "GHOST_TOKEN" }
  }'
  bash "$(cp_script render-apikey-helper.sh)" "$PROFILES_DIR/ghost.json" >/dev/null
  [ -f "$HELPERS_DIR/ghost.sh" ]
  rm -f "$PROFILES_DIR/ghost.json"
  # Shim is now orphan
  doctor --json
  echo "$output" | jq -e '.checks | map(select(.category == "orphan" and .status == "warn")) | length > 0' >/dev/null
}

@test "doctor --fix removes orphaned shim" {
  clean_gateway_setup
  write_profile "ghost" '{
    "name": "ghost",
    "auth": { "type": "env_var", "var": "GHOST_TOKEN" }
  }'
  bash "$(cp_script render-apikey-helper.sh)" "$PROFILES_DIR/ghost.json" >/dev/null
  rm -f "$PROFILES_DIR/ghost.json"
  doctor --fix
  [ ! -f "$HELPERS_DIR/ghost.sh" ]
}

# ============================================================
# --fix: sidecar rebuild from env marker (A2.2)
# ============================================================

@test "doctor --fix rebuilds missing sidecar from env marker" {
  clean_gateway_setup
  # Delete sidecar
  rm -f "$SIDECAR"
  # Set env marker to signal what profile was active
  CLAUDE_PROFILES_ACTIVE=gateway run bash "$(cp_script doctor.sh)" --fix
  # Sidecar should be rebuilt
  [ -f "$SIDECAR" ]
  run jq -r '.global.active_profile' "$SIDECAR"
  assert_output "gateway"
}

@test "doctor --fix rebuilds corrupt sidecar from env marker" {
  clean_gateway_setup
  printf 'not json {{{' > "$SIDECAR"
  CLAUDE_PROFILES_ACTIVE=gateway run bash "$(cp_script doctor.sh)" --fix
  [ -f "$SIDECAR" ]
  run jq -r '.global.active_profile' "$SIDECAR"
  assert_output "gateway"
}

@test "doctor --fix refuses env drift (needs command-layer AskUserQuestion)" {
  clean_gateway_setup
  # Hand-edit managed key
  jq '.env.ANTHROPIC_BASE_URL = "https://hacked.example.com"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  doctor --fix
  # Drift requires interactive confirmation — exits 8, output references drift
  assert_failure 8
  assert_output --partial "drift"
}

# ============================================================
# --fix: re-render broken shim
# ============================================================

@test "doctor --fix regenerates drifted env_var shim" {
  clean_gateway_setup
  write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN" }
  }'
  bash "$(cp_script render-apikey-helper.sh)" "$PROFILES_DIR/vault.json" >/dev/null
  # Tamper the shim
  printf '#!/bin/sh\necho tampered\n' > "$HELPERS_DIR/vault.sh"
  doctor --fix
  # Shim should match the correct template structure again
  grep -q 'VAULT_TOKEN' "$HELPERS_DIR/vault.sh"
  ! grep -q 'tampered' "$HELPERS_DIR/vault.sh"
}

# ============================================================
# --fix: orphan temp files
# ============================================================

@test "doctor --fix removes orphaned temp files" {
  clean_gateway_setup
  # Plant an orphaned temp file
  touch "$PROFILES_DIR/.state.json.XXXabc"
  touch "$PROFILES_DIR/.gateway.json.XXXabc"
  doctor --fix
  [ ! -e "$PROFILES_DIR/.state.json.XXXabc" ]
  [ ! -e "$PROFILES_DIR/.gateway.json.XXXabc" ]
}

@test "doctor --fix on clean system is a no-op (exit 0)" {
  clean_gateway_setup
  doctor --fix
  assert_success
}
