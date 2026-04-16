#!/usr/bin/env bash
# redact.sh — mask secret-ish fields for display per Amendment A7.
#
# Reads profile-shaped or settings-shaped JSON from stdin (or from a file
# argument) and emits the same JSON with sensitive fields masked.
#
# Redaction table (A7):
#   auth.path (helper_script) -> "~/***"
#   auth.var (env_var)        -> "***_VAR"
#   auth.service (keychain)   -> "***"
#   auth.account (keychain)   -> "***"
#   base_url                  -> "<scheme>://<host>/..."
#   base_url localhost/127.*  -> verbatim
#   apiKeyHelper (top-level)  -> "~/***"
#   extras keys/values        -> verbatim (denylist protects against unsafe keys)
#
# Flags:
#   --verbose / -v   pass input through unchanged; print stderr warning banner.
#
# Exit codes per §10:
#   0 — success
#   2 — usage error (unknown flag)
#   3 — file not found (when file argument given)
#   6 — invalid JSON input
#   7 — missing dependency (jq; enforced by lib.sh)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

verbose=0
file_arg=""

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose|-v)
      verbose=1
      shift
      ;;
    -h|--help)
      cat <<'EOF' >&2
Usage: redact.sh [--verbose|-v] [<file>]
Reads profile-shaped or settings-shaped JSON from stdin (or from <file>) and
emits the same JSON with sensitive fields masked per Amendment A7. Pass
--verbose to disable redaction (stderr warning banner is also printed).
EOF
      exit "$CP_EXIT_OK"
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      if [ -n "$file_arg" ]; then
        die_usage "at most one file argument accepted (got extra: $1)"
      fi
      file_arg="$1"
      shift
      ;;
  esac
done

# If leftover positional after --, treat the first as the file arg.
if [ -n "${1:-}" ] && [ -z "$file_arg" ]; then
  file_arg="$1"
fi

# Load input JSON into a variable.
if [ -n "$file_arg" ]; then
  [ -f "$file_arg" ] || die_not_found "$file_arg"
  input="$(cat "$file_arg")"
else
  input="$(cat)"
fi

# Verify JSON parses.
if ! printf '%s' "$input" | jq empty 2>/dev/null; then
  die_schema "input is not valid JSON"
fi

# --verbose: pass through unchanged; print stderr banner.
if [ "$verbose" -eq 1 ]; then
  printf 'claude-profiles: --verbose disables redaction.\n' >&2
  printf 'This output contains paths and env var names that can be used for reconnaissance.\n' >&2
  printf 'Only use --verbose in private.\n' >&2
  # Pretty-print to match default-mode output shape.
  printf '%s' "$input" | jq '.'
  exit "$CP_EXIT_OK"
fi

# Apply A7 redactions in a single jq expression.
#
# base_url handling: parse scheme + host. For localhost/127.0.0.1, pass
# through verbatim. For everything else, emit "<scheme>://<host>/...". jq
# has no URL parser, so we pattern-match with capture().
printf '%s' "$input" | jq '
  # Redact auth.path
  (if (.auth? // null) != null and (.auth.path? // null) != null
   then .auth.path = "~/***" else . end)

  # Redact auth.var
  | (if (.auth? // null) != null and (.auth.var? // null) != null
     then .auth.var = "***_VAR" else . end)

  # Redact auth.service
  | (if (.auth? // null) != null and (.auth.service? // null) != null
     then .auth.service = "***" else . end)

  # Redact auth.account
  | (if (.auth? // null) != null and (.auth.account? // null) != null
     then .auth.account = "***" else . end)

  # Redact top-level apiKeyHelper (settings-shaped JSON)
  | (if (.apiKeyHelper? // null) != null
     then .apiKeyHelper = "~/***" else . end)

  # Redact base_url to hostname-only, except localhost/127.0.0.1.
  | (if (.base_url? // null) != null and (.base_url | type) == "string"
     then
       (.base_url | capture("^(?<scheme>[a-zA-Z][a-zA-Z0-9+.-]*)://(?<host>[^/:?#]+)(?<rest>.*)$"; "x")) as $u
       | if ($u.host == "localhost" or $u.host == "127.0.0.1")
         then .
         else .base_url = ($u.scheme + "://" + $u.host + "/...")
         end
     else . end)
'
