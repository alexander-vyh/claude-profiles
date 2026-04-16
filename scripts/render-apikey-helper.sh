#!/usr/bin/env bash
# render-apikey-helper.sh <profile-path>
#
# Renders the per-profile helper shim from a template into
# ~/.claude/llm-profiles/.helpers/<name>.sh at mode 0700, per §3 Cases
# B & C and §9 Templates, observing Amendments A1.1 (defense-in-depth
# regex), A1.3 (no raw template substitution; single-quote keychain
# values; re-parse after write) and A1.4 (empty-output hardening).
#
# Behavior:
#   auth:none          — nothing to render; exit 0 silently.
#   auth:helper_script — nothing to render; exit 0 silently.
#   auth:env_var       — render helper-env-var.sh.tmpl  (A1.3, A1.4)
#   auth:keychain      — render helper-keychain.sh.tmpl (A1.1, A1.3, A1.4)
#
# Exit codes per §10:
#   0 — success (shim rendered, or no shim needed)
#   2 — usage error
#   3 — profile file not found
#   6 — schema / pattern violation (defense-in-depth at render time)
#   7 — missing dependency (jq — via lib.sh)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# ============================================================
# Parse arguments
# ============================================================
profile_path="${1:-}"
[ -n "$profile_path" ] || die_usage "render-apikey-helper.sh <profile-path>"
[ -f "$profile_path" ] || die_not_found "$profile_path"

# ============================================================
# Read profile
# ============================================================
if ! jq -e '.' "$profile_path" >/dev/null 2>&1; then
  die_schema "not valid JSON: $profile_path"
fi

name="$(jq -r '.name' "$profile_path")"
auth_type="$(jq -r '.auth.type // ""' "$profile_path")"

# ============================================================
# Short-circuit for auth types with no shim
# ============================================================
case "$auth_type" in
  none|helper_script)
    exit "$CP_EXIT_OK"
    ;;
  env_var|keychain)
    : # proceed
    ;;
  "")
    die_schema "auth.type is required"
    ;;
  *)
    die_schema "unknown auth.type '$auth_type'"
    ;;
esac

# ============================================================
# Resolve template path
# ============================================================
script_dir="$(cd "$(dirname "$0")" && pwd)"
templates_dir="$(dirname "$script_dir")/templates"

# ============================================================
# Target shim path + helpers dir
# ============================================================
helpers_dir="$(profile_dir)/.helpers"
mkdir -p "$helpers_dir"
chmod 0700 "$helpers_dir" 2>/dev/null || true
shim_path="$helpers_dir/${name}.sh"

# ============================================================
# Render per auth type (A1.3: no raw substitution of untrusted input)
# ============================================================
case "$auth_type" in
  env_var)
    template="$templates_dir/helper-env-var.sh.tmpl"
    [ -f "$template" ] || { printf 'claude-profiles: template missing: %s\n' "$template" >&2; exit "$CP_EXIT_RUNTIME"; }

    var="$(jq -r '.auth.var // ""' "$profile_path")"
    # A1.3 defense-in-depth: re-validate the var against the documented
    # pattern even though validate-profile.sh enforces it.
    printf '%s' "$var" | grep -Eq '^[A-Z_][A-Z0-9_]*$' \
      || die_schema "auth.var '$var' does not match pattern ^[A-Z_][A-Z0-9_]*\$"

    # Substitute {{VAR}} with the validated var name. sed delimiter '|'
    # avoids conflict with any characters the regex permits (A-Z, 0-9, _).
    rendered="$(sed "s|{{VAR}}|${var}|g" "$template")"
    ;;

  keychain)
    template="$templates_dir/helper-keychain.sh.tmpl"
    [ -f "$template" ] || { printf 'claude-profiles: template missing: %s\n' "$template" >&2; exit "$CP_EXIT_RUNTIME"; }

    service="$(jq -r '.auth.service // ""' "$profile_path")"
    account="$(jq -r '.auth.account // empty' "$profile_path")"
    [ -n "$account" ] || account="${USER:-}"

    # A1.1 defense-in-depth at render time. The regex rejects shell
    # metacharacters (", ', `, $, ;, |, &, (, ), <, >, space, newline).
    printf '%s' "$service" | grep -Eq '^[A-Za-z0-9_.-]{1,255}$' \
      || die_schema "A1.1: auth.service '$service' contains disallowed characters"
    printf '%s' "$account" | grep -Eq '^[A-Za-z0-9_.-]{1,255}$' \
      || die_schema "A1.1: auth.account '$account' contains disallowed characters"

    # A1.3: substitute only validated values. Single-quoting in the
    # template keeps the substituted values outside any shell
    # interpolation context; the regex above guarantees no single
    # quotes can appear in service/account.
    rendered="$(sed -e "s|{{SERVICE}}|${service}|g" -e "s|{{ACCOUNT}}|${account}|g" "$template")"
    ;;
esac

# ============================================================
# Write atomically at mode 0700 (§12a Write Protocol)
# ============================================================
printf '%s' "$rendered" | atomic_write "$shim_path" 0700 || {
  printf 'claude-profiles: failed to write shim: %s\n' "$shim_path" >&2
  exit "$CP_EXIT_RUNTIME"
}

# ============================================================
# A1.3 post-write validation: re-read and parse the rendered shim.
# Confirms no unexpected shell constructs survived.
# ============================================================
if ! bash -n "$shim_path" 2>/dev/null; then
  rm -f "$shim_path"
  printf 'claude-profiles: rendered shim failed post-write parse: %s\n' "$shim_path" >&2
  exit "$CP_EXIT_RUNTIME"
fi

# A1.3 post-write check: no unexpected placeholders remain. If the
# template leaked an un-substituted `{{...}}` marker, the shim is broken.
if grep -q '{{[A-Z_]*}}' "$shim_path"; then
  rm -f "$shim_path"
  printf 'claude-profiles: rendered shim contains un-substituted placeholders: %s\n' "$shim_path" >&2
  exit "$CP_EXIT_RUNTIME"
fi

exit "$CP_EXIT_OK"
