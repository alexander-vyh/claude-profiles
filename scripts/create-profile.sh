#!/usr/bin/env bash
# create-profile.sh <name> [--base-url URL] --auth-type TYPE
#                   [--auth-path PATH | --auth-var VAR |
#                    --auth-service SERVICE [--auth-account ACCOUNT]]
#                   [--ttl-ms N] [--extras KEY=VALUE]... [--description TEXT]
#
# Non-interactive profile writer per §7 /add row. Builds a profile JSON
# object from CLI flags, delegates full schema validation to
# validate-profile.sh, then atomically writes to
# ~/.claude/llm-profiles/<name>.json at mode 0644. Does NOT activate the
# profile (apply-profile.sh's job).
#
# Exit codes per §10:
#   0 — success
#   2 — usage error (missing name, unknown flag, bad auth-type combo)
#   4 — profile already exists
#   6 — schema validation failed (forwarded from validate-profile.sh)
#   7 — missing dependency (forwarded from lib.sh)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# ============================================================
# Parse arguments
# ============================================================
name=""
description=""
base_url=""
auth_type=""
auth_path=""
auth_var=""
auth_service=""
auth_account=""
ttl_ms=""
# Parallel arrays for --extras KEY=VALUE (bash 3-compatible: no assoc arrays).
extras_keys=()
extras_values=()

while [ $# -gt 0 ]; do
  case "$1" in
    --description)
      [ $# -ge 2 ] || die_usage "--description requires a value"
      description="$2"; shift 2
      ;;
    --description=*)
      description="${1#--description=}"; shift
      ;;
    --base-url)
      [ $# -ge 2 ] || die_usage "--base-url requires a value"
      base_url="$2"; shift 2
      ;;
    --base-url=*)
      base_url="${1#--base-url=}"; shift
      ;;
    --auth-type)
      [ $# -ge 2 ] || die_usage "--auth-type requires a value"
      auth_type="$2"; shift 2
      ;;
    --auth-type=*)
      auth_type="${1#--auth-type=}"; shift
      ;;
    --auth-path)
      [ $# -ge 2 ] || die_usage "--auth-path requires a value"
      auth_path="$2"; shift 2
      ;;
    --auth-path=*)
      auth_path="${1#--auth-path=}"; shift
      ;;
    --auth-var)
      [ $# -ge 2 ] || die_usage "--auth-var requires a value"
      auth_var="$2"; shift 2
      ;;
    --auth-var=*)
      auth_var="${1#--auth-var=}"; shift
      ;;
    --auth-service)
      [ $# -ge 2 ] || die_usage "--auth-service requires a value"
      auth_service="$2"; shift 2
      ;;
    --auth-service=*)
      auth_service="${1#--auth-service=}"; shift
      ;;
    --auth-account)
      [ $# -ge 2 ] || die_usage "--auth-account requires a value"
      auth_account="$2"; shift 2
      ;;
    --auth-account=*)
      auth_account="${1#--auth-account=}"; shift
      ;;
    --ttl-ms)
      [ $# -ge 2 ] || die_usage "--ttl-ms requires a value"
      ttl_ms="$2"; shift 2
      ;;
    --ttl-ms=*)
      ttl_ms="${1#--ttl-ms=}"; shift
      ;;
    --extras)
      [ $# -ge 2 ] || die_usage "--extras requires KEY=VALUE"
      _extra="$2"; shift 2
      case "$_extra" in
        *=*) : ;;
        *) die_usage "--extras '$_extra' must be KEY=VALUE" ;;
      esac
      _ek="${_extra%%=*}"
      _ev="${_extra#*=}"
      # Reject obviously-bad keys here for a clear usage-level message;
      # validate-profile.sh still enforces denylist + pattern later.
      printf '%s' "$_ek" | grep -Eq '^[A-Z_][A-Z0-9_]*$' \
        || die_usage "--extras key '$_ek' must match ^[A-Z_][A-Z0-9_]*\$"
      extras_keys+=("$_ek")
      extras_values+=("$_ev")
      ;;
    --extras=*)
      _extra="${1#--extras=}"; shift
      case "$_extra" in
        *=*) : ;;
        *) die_usage "--extras '$_extra' must be KEY=VALUE" ;;
      esac
      _ek="${_extra%%=*}"
      _ev="${_extra#*=}"
      printf '%s' "$_ek" | grep -Eq '^[A-Z_][A-Z0-9_]*$' \
        || die_usage "--extras key '$_ek' must match ^[A-Z_][A-Z0-9_]*\$"
      extras_keys+=("$_ek")
      extras_values+=("$_ev")
      ;;
    --*)
      die_usage "unknown flag: $1"
      ;;
    *)
      if [ -z "$name" ]; then
        name="$1"
      else
        die_usage "unexpected positional argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$name" ] || die_usage "create-profile.sh <name> --auth-type TYPE [options]"
[ -n "$auth_type" ] || die_usage "--auth-type is required"

# ============================================================
# Validate flag combinations per auth type. The schema validator
# catches these too, but rejecting here gives a clearer usage-level
# error (exit 2) before we ever touch disk.
# ============================================================
case "$auth_type" in
  none)
    [ -z "$auth_path" ]    || die_usage "--auth-path is not valid with --auth-type=none"
    [ -z "$auth_var" ]     || die_usage "--auth-var is not valid with --auth-type=none"
    [ -z "$auth_service" ] || die_usage "--auth-service is not valid with --auth-type=none"
    [ -z "$auth_account" ] || die_usage "--auth-account is not valid with --auth-type=none"
    ;;
  helper_script)
    [ -n "$auth_path" ]    || die_usage "--auth-type=helper_script requires --auth-path"
    [ -z "$auth_var" ]     || die_usage "--auth-var is not valid with --auth-type=helper_script"
    [ -z "$auth_service" ] || die_usage "--auth-service is not valid with --auth-type=helper_script"
    [ -z "$auth_account" ] || die_usage "--auth-account is not valid with --auth-type=helper_script"
    ;;
  env_var)
    [ -n "$auth_var" ]     || die_usage "--auth-type=env_var requires --auth-var"
    [ -z "$auth_path" ]    || die_usage "--auth-path is not valid with --auth-type=env_var"
    [ -z "$auth_service" ] || die_usage "--auth-service is not valid with --auth-type=env_var"
    [ -z "$auth_account" ] || die_usage "--auth-account is not valid with --auth-type=env_var"
    ;;
  keychain)
    [ -n "$auth_service" ] || die_usage "--auth-type=keychain requires --auth-service"
    [ -z "$auth_path" ]    || die_usage "--auth-path is not valid with --auth-type=keychain"
    [ -z "$auth_var" ]     || die_usage "--auth-var is not valid with --auth-type=keychain"
    ;;
  *)
    die_usage "unknown --auth-type '$auth_type' (valid: none, helper_script, env_var, keychain)"
    ;;
esac

# ============================================================
# Refuse if target profile file already exists.
# ============================================================
target="$(profile_dir)/${name}.json"
if [ -e "$target" ]; then
  printf 'claude-profiles: profile already exists: %s\n' "$name" >&2
  exit "$CP_EXIT_EXISTS"
fi

# ============================================================
# Build the profile JSON in memory via jq. Start with required
# fields and layer optionals. Using --arg for every string value
# keeps all user input out of jq's program syntax.
# ============================================================
profile_json="$(jq -n --arg name "$name" \
                     --arg auth_type "$auth_type" \
                  '{name: $name, auth: {type: $auth_type}}')"

case "$auth_type" in
  helper_script)
    profile_json="$(printf '%s' "$profile_json" \
      | jq --arg p "$auth_path" '.auth.path = $p')"
    ;;
  env_var)
    profile_json="$(printf '%s' "$profile_json" \
      | jq --arg v "$auth_var" '.auth.var = $v')"
    ;;
  keychain)
    profile_json="$(printf '%s' "$profile_json" \
      | jq --arg s "$auth_service" '.auth.service = $s')"
    if [ -n "$auth_account" ]; then
      profile_json="$(printf '%s' "$profile_json" \
        | jq --arg a "$auth_account" '.auth.account = $a')"
    fi
    ;;
esac

if [ -n "$description" ]; then
  profile_json="$(printf '%s' "$profile_json" \
    | jq --arg d "$description" '.description = $d')"
fi

if [ -n "$base_url" ]; then
  profile_json="$(printf '%s' "$profile_json" \
    | jq --arg u "$base_url" '.base_url = $u')"
fi

if [ -n "$ttl_ms" ]; then
  # Schema wants an integer; coerce via jq tonumber and let the validator
  # reject anything non-numeric with a clear schema error.
  profile_json="$(printf '%s' "$profile_json" \
    | jq --arg t "$ttl_ms" '.ttl_ms = ($t | tonumber)')" \
    || die_usage "--ttl-ms must be an integer (got '$ttl_ms')"
fi

if [ "${#extras_keys[@]}" -gt 0 ]; then
  profile_json="$(printf '%s' "$profile_json" | jq '.extras = {}')"
  i=0
  while [ "$i" -lt "${#extras_keys[@]}" ]; do
    profile_json="$(printf '%s' "$profile_json" \
      | jq --arg k "${extras_keys[$i]}" --arg v "${extras_values[$i]}" \
           '.extras[$k] = $v')"
    i=$((i + 1))
  done
fi

# ============================================================
# Write to a temp file, run validate-profile.sh against it. If
# invalid, forward the validator's exit code (typically 6) and
# clean up the temp file so no partial profile lingers.
# ============================================================
# Rule 1 requires the profile's .name field to equal the filename
# basename (minus .json). To let the validator enforce this cleanly
# we stage the file at <name>.json inside a private temp directory,
# then (on success) atomic_write it into the real profile dir.
mkdir -p "$(profile_dir)"
stage_dir="$(mktemp -d "$(profile_dir)/.${name}.stage.XXXXXX")"
stage_path="$stage_dir/${name}.json"
trap 'rm -rf "$stage_dir"' EXIT

printf '%s\n' "$profile_json" > "$stage_path"

validate_script="$(dirname "$0")/validate-profile.sh"
if ! bash "$validate_script" "$stage_path" >&2; then
  # Validator already emitted a descriptive error; forward its exit code.
  # On set -e with `if !`, we lose $? — default to 6 (schema) which is
  # what validate uses for every rule-level error.
  exit "$CP_EXIT_SCHEMA"
fi

# ============================================================
# Valid — atomically install at the real path, mode 0644 per
# §12a invariant 13.
# ============================================================
cat "$stage_path" | atomic_write "$target" 0644
rm -rf "$stage_dir"
trap - EXIT

exit 0
