#!/usr/bin/env bats
# Tests for scripts/remove-profile.sh — deletes a profile JSON and its
# plugin-generated helper shim, refusing when the profile is active in
# any sidecar-tracked scope (§7 `/remove` row, §1 Q6).

setup() {
  load 'test_helper/common'
  setup_isolated_home
  PROFILES_DIR="$HOME/.claude/llm-profiles"
  HELPERS_DIR="$PROFILES_DIR/.helpers"
  SIDECAR="$PROFILES_DIR/.state.json"
  mkdir -p "$PROFILES_DIR" "$HELPERS_DIR"

  # Baseline profile that's safe to remove.
  cat > "$PROFILES_DIR/removable.json" << 'EOF'
{
  "name": "removable",
  "auth": { "type": "none" }
}
EOF

  # Baseline empty sidecar — nothing active.
  printf '{}\n' > "$SIDECAR"
}

teardown() {
  teardown_isolated_home
}

remove() {
  run bash "$(cp_script remove-profile.sh)" "$@"
}

# ============================================================
# Happy path
# ============================================================

@test "remove a non-active profile: exit 0 and JSON file deleted" {
  remove removable
  assert_success
  [ ! -f "$PROFILES_DIR/removable.json" ]
}

@test "remove when shim exists at .helpers/<name>.sh: shim also deleted" {
  printf '#!/bin/sh\nprintf secret\n' > "$HELPERS_DIR/removable.sh"
  chmod 0700 "$HELPERS_DIR/removable.sh"
  remove removable
  assert_success
  [ ! -f "$PROFILES_DIR/removable.json" ]
  [ ! -f "$HELPERS_DIR/removable.sh" ]
}

@test "remove when no shim exists: still succeeds (shim deletion optional)" {
  # No shim created; baseline already has none.
  remove removable
  assert_success
  [ ! -f "$PROFILES_DIR/removable.json" ]
}

# ============================================================
# Error paths — existence and usage
# ============================================================

@test "remove non-existent profile: exit 3" {
  remove does-not-exist
  assert_failure 3
}

@test "remove with no argument: exit 2" {
  remove
  assert_failure 2
}

@test "remove with invalid name (uppercase): exit 2" {
  remove BadName
  assert_failure 2
  # File must NOT be touched — there is no such file, but the point is
  # that usage validation is done BEFORE any path construction.
  [ -f "$PROFILES_DIR/removable.json" ]
}

@test "remove with shell metacharacter in name: exit 2" {
  remove 'evil;rm'
  assert_failure 2
  [ -f "$PROFILES_DIR/removable.json" ]
}

@test "remove with path separator in name: exit 2" {
  remove 'a/b'
  assert_failure 2
  [ -f "$PROFILES_DIR/removable.json" ]
}

@test "remove with leading dash in name: exit 2" {
  remove '-removable'
  assert_failure 2
  [ -f "$PROFILES_DIR/removable.json" ]
}

# ============================================================
# Active-profile protection (Q6, exit 5)
# ============================================================

@test "remove refused when profile is globally active: exit 5, file NOT deleted" {
  jq --arg n "removable" '.global = {active_profile: $n, managed_env_keys: [], managed_env_values: {}, managed_api_key_helper: false, managed_api_key_helper_value: "", target_file: "/tmp/fake/settings.local.json"}' \
    "$SIDECAR" > "$SIDECAR.tmp" && mv "$SIDECAR.tmp" "$SIDECAR"
  remove removable
  assert_failure 5
  [ -f "$PROFILES_DIR/removable.json" ]
  assert_output --partial "switch"
}

@test "remove refused when profile is project-active: exit 5, file NOT deleted" {
  jq --arg n "removable" '.projects = {"/Users/alice/repo": {active_profile: $n, managed_env_keys: [], managed_env_values: {}, managed_api_key_helper: false, managed_api_key_helper_value: "", target_file: "/Users/alice/repo/.claude/settings.local.json"}}' \
    "$SIDECAR" > "$SIDECAR.tmp" && mv "$SIDECAR.tmp" "$SIDECAR"
  remove removable
  assert_failure 5
  [ -f "$PROFILES_DIR/removable.json" ]
  assert_output --partial "switch"
}

@test "remove refused when globally-active profile has a shim: shim NOT deleted either" {
  printf '#!/bin/sh\nprintf x\n' > "$HELPERS_DIR/removable.sh"
  chmod 0700 "$HELPERS_DIR/removable.sh"
  jq --arg n "removable" '.global = {active_profile: $n, managed_env_keys: [], managed_env_values: {}, managed_api_key_helper: false, managed_api_key_helper_value: "", target_file: "/tmp/x/settings.local.json"}' \
    "$SIDECAR" > "$SIDECAR.tmp" && mv "$SIDECAR.tmp" "$SIDECAR"
  remove removable
  assert_failure 5
  [ -f "$PROFILES_DIR/removable.json" ]
  [ -f "$HELPERS_DIR/removable.sh" ]
}

@test "remove succeeds when OTHER profile is active (name doesn't match)" {
  # sidecar says 'gateway' is active — we're removing 'removable'
  jq '.global = {active_profile: "gateway", managed_env_keys: [], managed_env_values: {}, managed_api_key_helper: false, managed_api_key_helper_value: "", target_file: "/tmp/x/settings.local.json"}' \
    "$SIDECAR" > "$SIDECAR.tmp" && mv "$SIDECAR.tmp" "$SIDECAR"
  remove removable
  assert_success
  [ ! -f "$PROFILES_DIR/removable.json" ]
}

# ============================================================
# Sidecar best-effort behavior (§13 C7)
# ============================================================

@test "remove with missing sidecar: stderr warning + proceeds" {
  rm -f "$SIDECAR"
  remove removable
  assert_success
  [ ! -f "$PROFILES_DIR/removable.json" ]
  assert_output --partial "sidecar"
}
