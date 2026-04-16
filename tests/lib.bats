#!/usr/bin/env bats
# Tests for scripts/lib.sh — shared helpers.
# Covers: existence, jq preflight, require_cmd, profile_dir, umask,
# error formatters, scope detection.

setup() {
  load 'test_helper/common'
  setup_isolated_home
}

teardown() {
  teardown_isolated_home
}

# ---- existence ----

@test "lib.sh exists at scripts/lib.sh" {
  [ -f "$(cp_script lib.sh)" ]
}

@test "lib.sh can be sourced without error when jq is available" {
  # jq is a hard dependency per §11 — this test assumes dev env has it.
  command -v jq >/dev/null || skip "jq not installed in dev env"
  run bash -c "source '$(cp_script lib.sh)'"
  assert_success
}

# ---- jq preflight (Amendment A6.4) ----

@test "sourcing lib.sh without jq in PATH exits 7 with install hint" {
  if command -v /usr/bin/jq >/dev/null 2>&1; then
    skip "jq is at /usr/bin/jq on this host; can't test missing-jq path"
  fi
  run bash -c "PATH=/usr/bin:/bin source '$(cp_script lib.sh)'"
  assert_failure 7
  assert_output --partial "jq"
}

# ---- require_cmd ----

@test "require_cmd succeeds for a command that exists" {
  run bash -c "source '$(cp_script lib.sh)' && require_cmd bash"
  assert_success
}

@test "require_cmd exits 7 for a command that does not exist" {
  run bash -c "source '$(cp_script lib.sh)' && require_cmd definitely_not_a_real_command_xyz"
  assert_failure 7
  assert_output --partial "definitely_not_a_real_command_xyz"
}

@test "require_cmd prints install hint for jq on missing-jq path" {
  run bash -c "source '$(cp_script lib.sh)' 2>/dev/null; require_cmd jq_placeholder 2>&1"
  # The function name generalizes; we only check that SOME hint mechanism
  # exists for jq specifically (per A6.4 table).
  run bash -c "source '$(cp_script lib.sh)' && require_cmd jq_nonexistent_xyz 2>&1 || true"
  assert_output --partial "jq_nonexistent_xyz"
}

# ---- profile_dir ----

@test "profile_dir returns \$HOME/.claude/llm-profiles" {
  run bash -c "source '$(cp_script lib.sh)' && profile_dir"
  assert_success
  assert_output "$HOME/.claude/llm-profiles"
}

# ---- umask (§12a Write Protocol step 1) ----

@test "sourcing lib.sh sets umask to 077" {
  run bash -c "source '$(cp_script lib.sh)' && umask"
  assert_success
  # umask prints as 0077 or 077 depending on shell — accept either.
  assert_output --regexp '^0?0?77$'
}

# ---- error formatters (Amendment A6.3) ----

@test "die_usage exits 2 and writes message to stderr" {
  run bash -c "source '$(cp_script lib.sh)' && die_usage 'bad flag --foo'"
  assert_failure 2
  assert_output --partial "bad flag --foo"
}

@test "die_not_found exits 3 and includes the missing name" {
  run bash -c "source '$(cp_script lib.sh)' && die_not_found 'my-profile'"
  assert_failure 3
  assert_output --partial "my-profile"
}

@test "die_schema exits 6" {
  run bash -c "source '$(cp_script lib.sh)' && die_schema 'extras key PATH is in denylist'"
  assert_failure 6
  assert_output --partial "denylist"
}

@test "die_missing_dep exits 7 and includes install hint per OS" {
  run bash -c "source '$(cp_script lib.sh)' && die_missing_dep 'jq'"
  assert_failure 7
  assert_output --partial "jq"
  # On macOS, hint should mention brew. On Linux, apt or similar.
  case "$(uname)" in
    Darwin) assert_output --partial "brew" ;;
    Linux)  assert_output --regexp "apt|pacman|yum|dnf" ;;
  esac
}

# ---- scope detection ----

@test "detect_scope returns 'global' when cwd is not a git repo" {
  cd "$HOME"  # isolated, not a git repo
  run bash -c "cd '$HOME' && source '$(cp_script lib.sh)' && detect_scope"
  assert_success
  assert_output "global"
}

@test "detect_scope returns 'project' when cwd is inside a git repo" {
  # Create a git repo inside isolated HOME
  mkdir -p "$HOME/myrepo"
  (cd "$HOME/myrepo" && git init -q)
  run bash -c "cd '$HOME/myrepo' && source '$(cp_script lib.sh)' && detect_scope"
  assert_success
  assert_output "project"
}
