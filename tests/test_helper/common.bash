#!/usr/bin/env bash
# Common test helper for claude-profiles bats tests.
#
# Every .bats file should `load '../test_helper/common'` in its `setup()`.
# This isolates each test in a fresh HOME so tests never touch the user's
# real ~/.claude/ directory. Mandatory per §5/§12 invariants — the plugin
# writes to real filesystem paths, and tests MUST NOT mutate user state.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# Repo root (directory containing scripts/, lib/, tests/).
# Derived from $BATS_TEST_FILENAME so tests work regardless of cwd.
CP_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
export CP_ROOT

# setup_isolated_home creates a fresh HOME for this test in a tempdir and
# exports it. Teardown removes the tempdir. Call from setup() in each .bats.
setup_isolated_home() {
  CP_TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/cp-test-XXXXXX")"
  export HOME="$CP_TEST_HOME"
  export CP_TEST_HOME
}

teardown_isolated_home() {
  if [ -n "${CP_TEST_HOME:-}" ] && [ -d "$CP_TEST_HOME" ]; then
    rm -rf "$CP_TEST_HOME"
  fi
  unset CP_TEST_HOME
}

# Absolute path to a script in scripts/.
cp_script() {
  printf '%s/scripts/%s' "$CP_ROOT" "$1"
}

# Absolute path to a lib file in lib/.
cp_lib() {
  printf '%s/lib/%s' "$CP_ROOT" "$1"
}
