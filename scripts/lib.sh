#!/usr/bin/env bash
# lib.sh — shared helpers for claude-profiles scripts.
#
# Every script sources this file as its first line. Per §12a (Plugin-Managed
# Write Protocol), this sets umask 077. Per Amendment A6.4, it preflights
# jq. Per Amendment A6.3, it provides one die_* formatter per exit code.

# Plugin-Managed Write Protocol step 1: restrictive umask so any file
# created before an explicit chmod is not world-readable.
umask 077

# Exit codes per §10. Exported so consumer scripts can reference by name.
export CP_EXIT_OK=0
export CP_EXIT_RUNTIME=1
export CP_EXIT_USAGE=2
export CP_EXIT_NOT_FOUND=3
export CP_EXIT_EXISTS=4
export CP_EXIT_LOCKED=5
export CP_EXIT_SCHEMA=6
export CP_EXIT_MISSING_DEP=7
export CP_EXIT_DRIFT=8
export CP_EXIT_RESTART_REQUIRED=9
readonly CP_EXIT_OK CP_EXIT_RUNTIME CP_EXIT_USAGE CP_EXIT_NOT_FOUND \
         CP_EXIT_EXISTS CP_EXIT_LOCKED CP_EXIT_SCHEMA CP_EXIT_MISSING_DEP \
         CP_EXIT_DRIFT CP_EXIT_RESTART_REQUIRED

# Extras denylist per Amendment A1.2. Dangerous env vars that MUST NOT appear
# as keys in a profile's `extras` map. Shared between validate-profile.sh and
# apply-profile.sh (defense-in-depth).
export CP_EXTRAS_DENYLIST="PATH HOME USER SHELL TERM TMPDIR EDITOR VISUAL \
LD_LIBRARY_PATH LD_PRELOAD \
XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR \
NODE_OPTIONS NODE_PATH NODE_EXTRA_CA_CERTS \
PYTHONPATH PYTHONSTARTUP PYTHONDONTWRITEBYTECODE \
RUBYLIB RUBYOPT \
PERL5LIB PERL5OPT \
JAVA_TOOL_OPTIONS _JAVA_OPTIONS MAVEN_OPTS GRADLE_OPTS \
GIT_SSH_COMMAND GIT_EXEC_PATH \
SSL_CERT_FILE SSL_CERT_DIR \
CARGO_HOME GOPATH GOBIN CMAKE_PREFIX_PATH PKG_CONFIG_PATH COMPOSER_HOME \
ANTHROPIC_BASE_URL CLAUDE_PROFILES_ACTIVE CLAUDE_CODE_API_KEY_HELPER_TTL_MS"
readonly CP_EXTRAS_DENYLIST

# is_denylisted <key> — returns 0 if key is in the denylist or matches
# ^LD_ / ^DYLD_ prefixes, else 1.
is_denylisted() {
  local key="$1"
  case "$key" in
    LD_*|DYLD_*) return 0 ;;
  esac
  local entry
  for entry in $CP_EXTRAS_DENYLIST; do
    [ "$key" = "$entry" ] && return 0
  done
  return 1
}

_cp_install_hint() {
  case "$1" in
    jq)
      case "$(uname)" in
        Darwin)
          printf '  Install: brew install jq\n' >&2
          ;;
        Linux)
          printf '  Install: apt install jq (Debian/Ubuntu)\n' >&2
          printf '           dnf install jq (Fedora/RHEL)\n' >&2
          printf '           pacman -S jq (Arch)\n' >&2
          ;;
        *)
          printf '  See https://jqlang.github.io/jq/download/\n' >&2
          ;;
      esac
      ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf 'claude-profiles: required command "%s" not found.\n' "$1" >&2
  _cp_install_hint "$1"
  exit "$CP_EXIT_MISSING_DEP"
}

profile_dir() {
  printf '%s/.claude/llm-profiles' "$HOME"
}

die_usage() {
  printf 'claude-profiles: usage error: %s\n' "$*" >&2
  exit "$CP_EXIT_USAGE"
}

die_not_found() {
  printf 'claude-profiles: profile not found: %s\n' "$*" >&2
  exit "$CP_EXIT_NOT_FOUND"
}

die_schema() {
  printf 'claude-profiles: schema validation error: %s\n' "$*" >&2
  exit "$CP_EXIT_SCHEMA"
}

die_missing_dep() {
  local cmd="$1"
  printf 'claude-profiles: required command "%s" not found.\n' "$cmd" >&2
  _cp_install_hint "$cmd"
  exit "$CP_EXIT_MISSING_DEP"
}

detect_scope() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'project'
  else
    printf 'global'
  fi
}

require_cmd jq
