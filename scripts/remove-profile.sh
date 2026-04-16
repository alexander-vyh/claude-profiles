#!/usr/bin/env bash
# remove-profile.sh <name>
#
# Deletes a profile JSON and its plugin-generated helper shim. Refuses
# when the profile is active in any sidecar-tracked scope (§1 Q6, §7).
#
# Active-profile check is best-effort per §13 C7: the sidecar is an
# incomplete view, so a profile marked "not active" by the sidecar may
# still be live in a session whose env has not been restarted. If the
# sidecar is missing, we emit a stderr warning and proceed.
#
# Exit codes per §10:
#   0 — success
#   2 — usage error (no name, or name has invalid characters)
#   3 — profile not found
#   5 — profile is active in some scope (refused)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# ============================================================
# Parse arguments
# ============================================================
profile_name="${1:-}"
[ -n "$profile_name" ] || die_usage "remove-profile.sh <name>"

# Validate the name against the §2 schema pattern BEFORE constructing
# any filesystem path. This ensures shell metacharacters, path
# separators, and NUL-like bytes can never reach rm.
printf '%s' "$profile_name" | grep -Eq '^[a-z0-9][a-z0-9-]{0,62}$' \
  || die_usage "invalid profile name '$profile_name' (must match ^[a-z0-9][a-z0-9-]{0,62}\$)"

profile_path="$(profile_dir)/${profile_name}.json"
shim_path="$(profile_dir)/.helpers/${profile_name}.sh"

# ============================================================
# Existence check (§10 precedence: exit 3 before authorization)
# ============================================================
[ -f "$profile_path" ] || die_not_found "$profile_name"

# ============================================================
# Active-profile check — refuse with exit 5 when the profile is active
# in any sidecar-tracked scope. Best-effort per §13 C7: if the sidecar
# is missing we warn and proceed; if it is corrupt we let
# sidecar_read_scope surface the error path.
# ============================================================
sidecar_file="$(sidecar_path)"
if [ ! -f "$sidecar_file" ]; then
  printf 'claude-profiles: sidecar not found, proceeding without active-profile check\n' >&2
else
  # Collect every active_profile value recorded in the sidecar:
  #   .global.active_profile
  #   .projects[*].active_profile
  # An empty/missing value is skipped by jq's `// empty`.
  actives="$(jq -r '
      [.global.active_profile // empty]
      + ((.projects // {}) | to_entries | map(.value.active_profile // empty))
      | .[]
    ' "$sidecar_file" 2>/dev/null || true)"

  while IFS= read -r active; do
    [ -z "$active" ] && continue
    if [ "$active" = "$profile_name" ]; then
      printf 'claude-profiles: profile "%s" is active; /switch away first, then retry.\n' \
        "$profile_name" >&2
      exit "$CP_EXIT_LOCKED"
    fi
  done <<EOF
$actives
EOF
fi

# ============================================================
# Delete profile JSON, then shim if present. The shim is optional —
# auth:none profiles have none.
# ============================================================
rm -f "$profile_path"
if [ -f "$shim_path" ]; then
  rm -f "$shim_path"
fi

exit "$CP_EXIT_OK"
