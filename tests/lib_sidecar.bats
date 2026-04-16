#!/usr/bin/env bats
# Tests for sidecar helpers in lib.sh.
# §4 sidecar state file + A2.1 (managed_env_values, managed_api_key_helper_value)
# + A2.2 (missing/corrupt refuses, recovery hint).

setup() {
  load 'test_helper/common'
  setup_isolated_home
  SIDECAR="$HOME/.claude/llm-profiles/.state.json"
  mkdir -p "$(dirname "$SIDECAR")"
}

teardown() {
  teardown_isolated_home
}

@test "sidecar_path returns \$HOME/.claude/llm-profiles/.state.json" {
  run bash -c "source '$(cp_script lib.sh)' && sidecar_path"
  assert_success
  assert_output "$SIDECAR"
}

@test "sidecar_read_scope exits 1 when sidecar is missing (A2.2)" {
  run bash -c "source '$(cp_script lib.sh)' && sidecar_read_scope global"
  assert_failure 1
  assert_output --partial "doctor"
}

@test "sidecar_read_scope exits 1 when sidecar is corrupt (A2.2)" {
  printf 'not valid json {{{' > "$SIDECAR"
  run bash -c "source '$(cp_script lib.sh)' && sidecar_read_scope global"
  assert_failure 1
  assert_output --partial "corrupt"
}

@test "sidecar_read_scope returns {} for untracked scope in valid sidecar" {
  printf '{"global": {"active_profile": "foo"}}' > "$SIDECAR"
  run bash -c "source '$(cp_script lib.sh)' && sidecar_read_scope projects"
  assert_success
  # No entry for "projects" — returns empty object as JSON
  assert_output "{}"
}

@test "sidecar_read_scope returns the scope entry as JSON" {
  printf '{"global": {"active_profile": "foo", "managed_env_keys": ["A","B"]}}' > "$SIDECAR"
  run bash -c "source '$(cp_script lib.sh)' && sidecar_read_scope global"
  assert_success
  # jq output is compact by default; check key fields
  assert_output --partial '"active_profile"'
  assert_output --partial '"foo"'
  assert_output --partial '"A"'
}

@test "sidecar_write_scope creates sidecar if missing" {
  [ ! -f "$SIDECAR" ]
  run bash -c "
    source '$(cp_script lib.sh)'
    sidecar_write_scope global '{\"active_profile\":\"anthropic-direct\"}'
  "
  assert_success
  [ -f "$SIDECAR" ]
  run jq -r '.global.active_profile' "$SIDECAR"
  assert_output "anthropic-direct"
}

@test "sidecar_write_scope updates one scope without touching others" {
  printf '{"global": {"active_profile": "foo"}, "projects": {"/repo1": {"active_profile": "bar"}}}' > "$SIDECAR"
  bash -c "
    source '$(cp_script lib.sh)'
    sidecar_write_scope global '{\"active_profile\":\"baz\"}'
  "
  # global was updated
  run jq -r '.global.active_profile' "$SIDECAR"
  assert_output "baz"
  # projects entry preserved
  run jq -r '.projects["/repo1"].active_profile' "$SIDECAR"
  assert_output "bar"
}

@test "sidecar_write_scope produces 0600 mode file" {
  bash -c "
    source '$(cp_script lib.sh)'
    sidecar_write_scope global '{\"active_profile\":\"foo\"}'
  "
  [ -f "$SIDECAR" ]
  mode=$(stat -f '%p' "$SIDECAR" 2>/dev/null || stat -c '%a' "$SIDECAR" 2>/dev/null)
  case "$mode" in
    *600) : ;;
    *) echo "expected mode 0600, got $mode" >&2; false ;;
  esac
}

@test "sidecar_write_scope accepts nested scope key for projects" {
  run bash -c "
    source '$(cp_script lib.sh)'
    sidecar_write_scope 'projects[\"/Users/me/repo\"]' '{\"active_profile\":\"x\"}'
  "
  assert_success
  run jq -r '.projects["/Users/me/repo"].active_profile' "$SIDECAR"
  assert_output "x"
}
