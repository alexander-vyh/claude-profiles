#!/usr/bin/env bats
# Tests for scripts/init.sh — bootstraps ~/.claude/llm-profiles/ per
# §7 init row as amended by A5 (true idempotent, never-resurrect seed rule).

setup() {
  load 'test_helper/common'
  setup_isolated_home
  PROFILES_DIR="$HOME/.claude/llm-profiles"
  HELPERS_DIR="$PROFILES_DIR/.helpers"
  SIDECAR="$PROFILES_DIR/.state.json"
}

teardown() {
  teardown_isolated_home
}

init() {
  run bash "$(cp_script init.sh)" "$@"
}

# file_mode is provided by test_helper/common.bash (cross-platform).

# ============================================================
# Fresh init — everything gets created
# ============================================================

@test "fresh init creates profile dir at 0755" {
  init
  assert_success
  [ -d "$PROFILES_DIR" ]
  mode=$(file_mode "$PROFILES_DIR")
  [ "$mode" = "755" ]
}

@test "fresh init creates .helpers/ at 0700" {
  init
  assert_success
  [ -d "$HELPERS_DIR" ]
  mode=$(file_mode "$HELPERS_DIR")
  [ "$mode" = "700" ]
}

@test "fresh init creates .state.json containing empty JSON object" {
  init
  assert_success
  [ -f "$SIDECAR" ]
  run jq -e '. == {}' "$SIDECAR"
  assert_success
}

@test "fresh init creates .state.json at mode 0600" {
  init
  assert_success
  mode=$(file_mode "$SIDECAR")
  [ "$mode" = "600" ]
}

@test "fresh init seeds anthropic-direct.json" {
  init
  assert_success
  [ -f "$PROFILES_DIR/anthropic-direct.json" ]
  name="$(jq -r '.name' "$PROFILES_DIR/anthropic-direct.json")"
  [ "$name" = "anthropic-direct" ]
}

@test "fresh init seeds gateway-example.json" {
  init
  assert_success
  [ -f "$PROFILES_DIR/gateway-example.json" ]
  name="$(jq -r '.name' "$PROFILES_DIR/gateway-example.json")"
  [ "$name" = "gateway-example" ]
}

@test "seed profiles are written at mode 0644" {
  init
  assert_success
  mode=$(file_mode "$PROFILES_DIR/anthropic-direct.json")
  [ "$mode" = "644" ]
  mode=$(file_mode "$PROFILES_DIR/gateway-example.json")
  [ "$mode" = "644" ]
}

@test "seeded profiles pass validate-profile.sh" {
  init
  assert_success
  run bash "$(cp_script validate-profile.sh)" "$PROFILES_DIR/anthropic-direct.json"
  assert_success
  run bash "$(cp_script validate-profile.sh)" "$PROFILES_DIR/gateway-example.json"
  assert_success
}

# ============================================================
# Idempotency — second run is a silent no-op, exit 0
# ============================================================

@test "second init exits 0 (true idempotent)" {
  init
  assert_success
  init
  assert_success
}

@test "second init does not modify seeded profiles (content stable)" {
  init
  assert_success
  orig_direct="$(cat "$PROFILES_DIR/anthropic-direct.json")"
  orig_gw="$(cat "$PROFILES_DIR/gateway-example.json")"
  init
  assert_success
  [ "$(cat "$PROFILES_DIR/anthropic-direct.json")" = "$orig_direct" ]
  [ "$(cat "$PROFILES_DIR/gateway-example.json")" = "$orig_gw" ]
}

@test "second init does not modify .state.json (content stable)" {
  init
  assert_success
  orig_state="$(cat "$SIDECAR")"
  init
  assert_success
  [ "$(cat "$SIDECAR")" = "$orig_state" ]
}

# ============================================================
# A5 "never resurrect" rule — any existing *.json skips seeding
# ============================================================

@test "init with existing user profile skips seeding entirely" {
  mkdir -p "$PROFILES_DIR"
  printf '{"name":"my-custom","auth":{"type":"none"}}' > "$PROFILES_DIR/my-custom.json"
  init
  assert_success
  [ -f "$PROFILES_DIR/my-custom.json" ]
  # Neither seed was installed, because user already has profiles.
  [ ! -f "$PROFILES_DIR/anthropic-direct.json" ]
  [ ! -f "$PROFILES_DIR/gateway-example.json" ]
}

@test "init does NOT resurrect deleted gateway-example.json when anthropic-direct.json is present (A5)" {
  # Simulate state after first init + user deleted gateway-example.json.
  init
  assert_success
  rm -f "$PROFILES_DIR/gateway-example.json"
  [ -f "$PROFILES_DIR/anthropic-direct.json" ]
  [ ! -f "$PROFILES_DIR/gateway-example.json" ]

  init
  assert_success
  # anthropic-direct.json still qualifies as "*.json exists" → skip seeding.
  [ -f "$PROFILES_DIR/anthropic-direct.json" ]
  [ ! -f "$PROFILES_DIR/gateway-example.json" ]
}

@test "init does NOT resurrect deleted anthropic-direct.json when gateway-example.json is present" {
  init
  assert_success
  rm -f "$PROFILES_DIR/anthropic-direct.json"
  [ ! -f "$PROFILES_DIR/anthropic-direct.json" ]
  [ -f "$PROFILES_DIR/gateway-example.json" ]

  init
  assert_success
  [ ! -f "$PROFILES_DIR/anthropic-direct.json" ]
  [ -f "$PROFILES_DIR/gateway-example.json" ]
}

# ============================================================
# Existing state preservation
# ============================================================

@test "existing .state.json with real content is preserved" {
  mkdir -p "$PROFILES_DIR"
  printf '%s' '{"global":{"active_profile":"my-profile"}}' > "$SIDECAR"
  chmod 0600 "$SIDECAR"
  orig="$(cat "$SIDECAR")"

  init
  assert_success
  [ "$(cat "$SIDECAR")" = "$orig" ]
}

@test "existing .helpers/ directory preserved (mode + contents)" {
  mkdir -p "$HELPERS_DIR"
  chmod 0700 "$HELPERS_DIR"
  printf '#!/bin/sh\necho hi' > "$HELPERS_DIR/existing.sh"
  chmod 0700 "$HELPERS_DIR/existing.sh"

  init
  assert_success
  [ -f "$HELPERS_DIR/existing.sh" ]
  [ "$(cat "$HELPERS_DIR/existing.sh")" = "$(printf '#!/bin/sh\necho hi')" ]
}

@test "existing profile dir with non-default mode is not chmod'd by init" {
  # User intentionally set 0700 on their profile dir (shared host, §12 inv 13).
  mkdir -p "$PROFILES_DIR"
  chmod 0700 "$PROFILES_DIR"
  # Seed a user profile so seeding is skipped (otherwise init would add files).
  printf '{"name":"mine","auth":{"type":"none"}}' > "$PROFILES_DIR/mine.json"

  init
  assert_success
  mode=$(file_mode "$PROFILES_DIR")
  [ "$mode" = "700" ]
}
