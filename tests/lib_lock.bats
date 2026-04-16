#!/usr/bin/env bats
# Tests for lock helpers in lib.sh (mkdir-based polyfill per §12a).

setup() {
  load 'test_helper/common'
  setup_isolated_home
  LOCKDIR="$HOME/.claude/llm-profiles/.state.lock"
  mkdir -p "$(dirname "$LOCKDIR")"
}

teardown() {
  teardown_isolated_home
}

@test "lock_acquire succeeds when lockdir does not exist" {
  run bash -c "source '$(cp_script lib.sh)' && lock_acquire '$LOCKDIR'"
  assert_success
  [ -d "$LOCKDIR" ]
}

@test "lock_acquire writes PID into lockdir" {
  bash -c "source '$(cp_script lib.sh)' && lock_acquire '$LOCKDIR'"
  [ -f "$LOCKDIR/pid" ]
  pid_content=$(cat "$LOCKDIR/pid")
  # PID should be a positive integer
  case "$pid_content" in
    ''|*[!0-9]*) echo "not a number: $pid_content" >&2; false ;;
    *) [ "$pid_content" -gt 0 ] ;;
  esac
}

@test "lock_release removes the lockdir" {
  bash -c "source '$(cp_script lib.sh)' && lock_acquire '$LOCKDIR'"
  [ -d "$LOCKDIR" ]
  bash -c "source '$(cp_script lib.sh)' && lock_release '$LOCKDIR'"
  [ ! -d "$LOCKDIR" ]
}

@test "lock_acquire fails when another live process holds the lock" {
  # Simulate a live holder by writing the bats runner's own PID
  # (it's alive while this test runs).
  mkdir -p "$LOCKDIR"
  printf '%s' "$$" > "$LOCKDIR/pid"
  run bash -c "source '$(cp_script lib.sh)' && lock_acquire '$LOCKDIR'"
  assert_failure
  # Cleanup
  rmdir "$LOCKDIR" 2>/dev/null || rm -rf "$LOCKDIR"
}

@test "lock_acquire reclaims a stale lock (dead PID)" {
  # Write a PID that almost certainly isn't alive. Use 1 — well, that's init.
  # Use a high random PID that almost certainly doesn't exist.
  mkdir -p "$LOCKDIR"
  # Find a PID that's not live
  for candidate in 999999 888888 777777 666666 555555; do
    if ! kill -0 "$candidate" 2>/dev/null; then
      dead_pid="$candidate"
      break
    fi
  done
  [ -n "${dead_pid:-}" ] || skip "could not find a dead PID"
  printf '%s' "$dead_pid" > "$LOCKDIR/pid"
  run bash -c "source '$(cp_script lib.sh)' && lock_acquire '$LOCKDIR'"
  assert_success
  # The reclaimed lock should have our new shell's PID, not the dead one
  new_pid=$(cat "$LOCKDIR/pid")
  [ "$new_pid" != "$dead_pid" ]
}
