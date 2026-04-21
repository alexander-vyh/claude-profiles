#!/usr/bin/env bash
# validate-profile.sh <profile-file>
#
# Validates a claude-profiles profile against §2 schema and validation
# rules 1-8 (including Amendments A1.1 keychain field patterns and
# A1.2 extras denylist).
#
# Exit codes per §10:
#   0 — valid
#   2 — usage error (no argument)
#   3 — file not found
#   6 — schema or rule violation
#   7 — missing dependency (jq)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

profile_path="${1:-}"
[ -n "$profile_path" ] || die_usage "validate-profile.sh <profile-file>"
[ -f "$profile_path" ] || die_not_found "$profile_path"

# Parse as JSON. jq -e exits non-zero on parse error.
if ! jq -e '.' "$profile_path" >/dev/null 2>&1; then
  die_schema "not valid JSON: $profile_path"
fi

# Helper: read a jq expression from the profile file.
jqr() {
  jq -r "$1" "$profile_path"
}

jqe() {
  jq -e "$1" "$profile_path" >/dev/null
}

# ---- Required fields ----
jqe 'has("name") and has("auth")' || die_schema "missing required field (name, auth)"

# ---- name field ----
name="$(jqr '.name')"
[ "$(jqr '.name | type')" = "string" ] || die_schema "name must be a string"
printf '%s' "$name" | grep -Eq '^[a-z0-9][a-z0-9-]{0,62}$' \
  || die_schema "name '$name' does not match pattern ^[a-z0-9][a-z0-9-]{0,62}\$"

# Rule 1: name MUST equal filename basename.
filename_base="$(basename "$profile_path" .json)"
[ "$name" = "$filename_base" ] \
  || die_schema "rule 1: name '$name' does not match filename basename '$filename_base'"

# ---- description (optional) ----
if jqe 'has("description")'; then
  [ "$(jqr '.description | type')" = "string" ] \
    || die_schema "description must be a string"
  desc_len="$(jqr '.description | length')"
  [ "$desc_len" -le 200 ] \
    || die_schema "description exceeds 200 chars (got $desc_len)"
fi

# ---- base_url (optional, rule 2) ----
if jqe 'has("base_url") and .base_url != null'; then
  base_url="$(jqr '.base_url')"
  case "$base_url" in
    https://*)
      : # ok
      ;;
    http://localhost|http://localhost:*|http://localhost/*)
      : # ok — rule 2 exception
      ;;
    http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*)
      : # ok — rule 2 exception
      ;;
    http://*)
      die_schema "rule 2: base_url must be https:// (got '$base_url'; http:// allowed only for localhost/127.0.0.1)"
      ;;
    *)
      die_schema "rule 2: base_url must be a URL (got '$base_url')"
      ;;
  esac
fi

# ---- ttl_ms (optional) ----
if jqe 'has("ttl_ms")'; then
  [ "$(jqr '.ttl_ms | type')" = "number" ] \
    || die_schema "ttl_ms must be an integer"
  ttl="$(jqr '.ttl_ms')"
  if [ "$ttl" -lt 1000 ] || [ "$ttl" -gt 86400000 ]; then
    die_schema "ttl_ms must be between 1000 and 86400000 (got $ttl)"
  fi
fi

# ---- auth (required) ----
auth_type="$(jqr '.auth.type // ""')"
case "$auth_type" in
  none)
    # No additional fields allowed.
    extra_keys="$(jqr '.auth | keys | map(select(. != "type")) | .[]' 2>/dev/null || true)"
    [ -z "$extra_keys" ] || die_schema "auth.type=none must have no other fields (got: $extra_keys)"
    ;;
  helper_script)
    jqe '.auth | has("path")' || die_schema "auth.type=helper_script requires 'path'"
    [ "$(jqr '.auth.path | type')" = "string" ] \
      || die_schema "auth.path must be a string"
    # Rule 3: path need NOT exist at validate time (portable profiles).
    ;;
  env_var)
    jqe '.auth | has("var")' || die_schema "auth.type=env_var requires 'var'"
    var="$(jqr '.auth.var')"
    printf '%s' "$var" | grep -Eq '^[A-Z_][A-Z0-9_]*$' \
      || die_schema "auth.var '$var' does not match pattern ^[A-Z_][A-Z0-9_]*\$"
    ;;
  keychain)
    # Rule 6: keychain is macOS-only.
    [ "$(uname)" = "Darwin" ] \
      || die_schema "rule 6: auth.type=keychain is macOS-only"
    jqe '.auth | has("service")' || die_schema "auth.type=keychain requires 'service'"
    # A1.1: service/account regex rejects shell metacharacters.
    service="$(jqr '.auth.service')"
    printf '%s' "$service" | grep -Eq '^[A-Za-z0-9_.-]{1,255}$' \
      || die_schema "A1.1: auth.service '$service' contains disallowed characters (allowed: A-Z a-z 0-9 _ . -)"
    if jqe '.auth | has("account")'; then
      account="$(jqr '.auth.account')"
      printf '%s' "$account" | grep -Eq '^[A-Za-z0-9_.-]{1,255}$' \
        || die_schema "A1.1: auth.account '$account' contains disallowed characters"
    fi
    ;;
  "")
    die_schema "auth.type is required"
    ;;
  *)
    die_schema "unknown auth.type '$auth_type' (valid: none, helper_script, env_var, keychain)"
    ;;
esac

# ---- extras (optional; rules 4, 8 / A1.2) ----
if jqe 'has("extras")'; then
  [ "$(jqr '.extras | type')" = "object" ] \
    || die_schema "extras must be an object"
  # Iterate keys; enforce pattern + denylist.
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    printf '%s' "$key" | grep -Eq '^[A-Z_][A-Z0-9_]*$' \
      || die_schema "extras key '$key' does not match pattern ^[A-Z_][A-Z0-9_]*\$"
    if is_denylisted "$key"; then
      die_schema "extras key '$key' is in EXTRAS_DENYLIST (A1.2): cannot be set via profile"
    fi
    # Values must be strings (schema enforces this but re-check for robustness).
    value_type="$(jq -r --arg k "$key" '.extras[$k] | type' "$profile_path")"
    [ "$value_type" = "string" ] \
      || die_schema "extras.$key value must be a string (got $value_type)"
  done < <(jq -r '.extras | keys[]' "$profile_path" 2>/dev/null)
fi

# ---- Rule 5: unknown top-level keys ----
allowed_keys="name description base_url auth ttl_ms extras"
while IFS= read -r top_key; do
  [ -z "$top_key" ] && continue
  found=0
  for allowed in $allowed_keys; do
    [ "$top_key" = "$allowed" ] && { found=1; break; }
  done
  [ "$found" -eq 1 ] \
    || die_schema "rule 5: unexpected top-level key '$top_key' (allowed: $allowed_keys)"
done < <(jq -r 'keys[]' "$profile_path" 2>/dev/null)

exit 0
