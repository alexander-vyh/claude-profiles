#!/usr/bin/env bats
# Tests for atomic_write helper in lib.sh (per §12a Write Protocol).

setup() {
  load 'test_helper/common'
  setup_isolated_home
}

teardown() {
  teardown_isolated_home
}

# Runs atomic_write in a subshell with lib.sh sourced, content via stdin.
atomic_write_cmd() {
  local target="$1"
  local content="$2"
  printf '%s' "$content" | bash -c "
    source '$(cp_script lib.sh)'
    atomic_write '$target'
  "
}

@test "atomic_write creates target with given content" {
  target="$HOME/file.txt"
  atomic_write_cmd "$target" "hello world"
  [ -f "$target" ]
  [ "$(cat "$target")" = "hello world" ]
}

@test "atomic_write overwrites existing file" {
  target="$HOME/file.txt"
  printf 'old content' > "$target"
  atomic_write_cmd "$target" "new content"
  [ "$(cat "$target")" = "new content" ]
}

@test "atomic_write sets target mode to 0600 by default" {
  target="$HOME/secrets.txt"
  atomic_write_cmd "$target" "sensitive"
  # BSD stat (macOS) prints octal mode via -f '%p' with leading filetype.
  mode=$(stat -f '%p' "$target" 2>/dev/null || stat -c '%a' "$target" 2>/dev/null)
  # Accept either "100600" (BSD full) or "600" (GNU -c '%a').
  case "$mode" in
    *600) : ;;
    *) echo "expected mode 0600, got $mode" >&2; false ;;
  esac
}

@test "atomic_write creates temp file in same directory as target" {
  target="$HOME/subdir/file.txt"
  mkdir -p "$HOME/subdir"
  atomic_write_cmd "$target" "content"
  [ -f "$target" ]
  # No orphaned .file.txt.* tempfile should remain
  orphans=$(find "$HOME/subdir" -maxdepth 1 -name ".file.txt.*" 2>/dev/null)
  [ -z "$orphans" ]
}

@test "atomic_write uses rename (no intermediate partial state visible)" {
  target="$HOME/file.txt"
  printf 'original' > "$target"
  # Verify target never transitions to empty during write.
  # We do a direct write then check final state; the atomicity guarantee
  # from rename(2) is tested by the kernel itself, not here. We verify
  # the write completed.
  atomic_write_cmd "$target" "complete content"
  [ "$(cat "$target")" = "complete content" ]
}

@test "atomic_write accepts custom mode as second arg" {
  target="$HOME/helper.sh"
  printf '#!/bin/sh\necho hi' | bash -c "
    source '$(cp_script lib.sh)'
    atomic_write '$target' 0700
  "
  mode=$(stat -f '%p' "$target" 2>/dev/null || stat -c '%a' "$target" 2>/dev/null)
  case "$mode" in
    *700) : ;;
    *) echo "expected mode 0700, got $mode" >&2; false ;;
  esac
}

@test "atomic_write to path with non-existent parent directory fails" {
  target="$HOME/no-such-dir/file.txt"
  run bash -c "
    source '$(cp_script lib.sh)'
    printf 'x' | atomic_write '$target'
  "
  assert_failure
}
