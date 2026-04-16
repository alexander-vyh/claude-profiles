#!/usr/bin/env bash
# shellcheck disable=SC2031  # HOME redirected inside scoped subshells; outer $HOME unaffected.
# doctor.sh [--fix] [--json] [--verbose] — run all diagnostics across
# every profile and optionally repair safe issues.
#
# Per §7, §8, and Amendment A5 /doctor row. Runs ALL checks (collects
# results), then emits a report. Never invokes apiKeyHelper scripts —
# invariant 8: helper checks verify the executable bit only.
#
# Diagnostic categories:
#   schema       per-profile validate-profile.sh pass/fail
#   helper       per-profile helper (helper_script) or shim (env_var,
#                keychain) existence + executability + drift
#   sidecar      sidecar presence + parseability
#   drift        sidecar-vs-settings drift per scope
#   reachability optional curl probe of base_url per profile
#   envmarker    CLAUDE_PROFILES_ACTIVE vs sidecar global.active_profile
#   orphan       orphaned shims (profile deleted) + orphan temp files
#
# --fix behavior (non-interactive; safe repairs only):
#   - Missing/corrupt sidecar: rebuild from CLAUDE_PROFILES_ACTIVE env
#     marker + profile definition (A2.2).
#   - Drifted / missing env_var or keychain shim: re-render via
#     render-apikey-helper.sh.
#   - Orphaned helper shims (profile deleted): remove.
#   - Orphaned temp files (.<name>.XXXXXX): remove.
#   - Drifted managed env keys: REFUSED — requires AskUserQuestion at
#     the command layer (A5). Script exits 8 so the command layer can
#     invoke apply-profile.sh --accept-drift=... per scope.
#
# Exit codes per §10 + A5:
#   0 — all checks OK, or --fix successfully repaired every issue
#   1 — runtime error (cannot read profile_dir, etc.)
#   2 — usage error
#   7 — missing hard dependency (jq; raised by lib.sh)
#   8 — drift detected (or other unfixable fail in --fix mode)

set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# ============================================================
# Parse arguments
# ============================================================
do_fix=0
want_json=0
want_verbose=0

while [ $# -gt 0 ]; do
  case "$1" in
    --fix) do_fix=1 ;;
    --json) want_json=1 ;;
    --verbose|-v) want_verbose=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: doctor.sh [--fix] [--json] [--verbose]

Run all diagnostics across every profile. By default emits a human-
readable report. --json emits a structured result set. --fix attempts
safe repairs (sidecar rebuild, shim regeneration, orphan cleanup).
Drifted managed env keys always require interactive confirmation at
the command layer and are reported, never silently overwritten.

Exit codes: 0 ok | 1 runtime | 2 usage | 7 missing-dep | 8 drift/unfixable
EOF
      exit "$CP_EXIT_OK"
      ;;
    --*) die_usage "unknown flag: $1" ;;
    *) die_usage "unexpected argument: $1" ;;
  esac
  shift
done

# ============================================================
# Paths + script resolution
# ============================================================
script_dir="$(cd "$(dirname "$0")" && pwd)"
validate_script="$script_dir/validate-profile.sh"
render_script="$script_dir/render-apikey-helper.sh"

target_dir="$(profile_dir)"
helpers_dir="$target_dir/.helpers"
sidecar="$(sidecar_path)"

# Collected checks: each entry is a one-line compact JSON object.
# Held in a tempfile so subshells and post-hoc fix paths can append.
checks_file="$(mktemp "${TMPDIR:-/tmp}/cp-doctor-checks.XXXXXX")"
trap 'rm -f "$checks_file"' EXIT

emit_check() {
  # emit_check <category> <profile-or-scope> <status> <detail>
  local category="$1" profile="${2:-}" status="$3" detail="$4"
  jq -nc --arg c "$category" --arg p "$profile" --arg s "$status" --arg d "$detail" \
    '{category: $c, profile: $p, status: $s, detail: $d}' >> "$checks_file"
}

# ============================================================
# PROFILE-DIR STATE
# ============================================================
if [ ! -d "$target_dir" ]; then
  emit_check "profile_dir" "" "fail" "profile directory does not exist: $target_dir"
else
  emit_check "profile_dir" "" "ok" "$target_dir"
fi

if [ ! -d "$helpers_dir" ]; then
  emit_check "helpers_dir" "" "warn" "helpers directory missing: $helpers_dir"
else
  emit_check "helpers_dir" "" "ok" "$helpers_dir"
fi

# ============================================================
# SCHEMA + HELPER checks per profile
# ============================================================
profile_names=""
if [ -d "$target_dir" ]; then
  for pf in "$target_dir"/*.json; do
    [ -f "$pf" ] || continue
    pname="$(basename "$pf" .json)"
    profile_names="$profile_names $pname"

    # Schema
    if bash "$validate_script" "$pf" >/dev/null 2>&1; then
      emit_check "schema" "$pname" "ok" "schema validates"
    else
      err_msg="$(bash "$validate_script" "$pf" 2>&1 || true)"
      emit_check "schema" "$pname" "fail" "$err_msg"
      # Skip helper/reachability checks if schema is broken — auth.type
      # is unreliable. Continue to next profile.
      continue
    fi

    # Helper
    auth_type="$(jq -r '.auth.type // ""' "$pf")"
    case "$auth_type" in
      helper_script)
        helper_path="$(jq -r '.auth.path' "$pf")"
        # shellcheck disable=SC2088  # literal-tilde pattern in case branches, not path expansion
        case "$helper_path" in
          "~/"*) helper_path="$HOME/${helper_path:2}" ;;
          "~")   helper_path="$HOME" ;;
        esac
        if [ ! -e "$helper_path" ]; then
          emit_check "helper" "$pname" "fail" "helper missing: $helper_path"
        elif [ ! -x "$helper_path" ]; then
          emit_check "helper" "$pname" "fail" "helper not executable: $helper_path"
        else
          # Invariant 8: check bit only, NEVER invoke.
          emit_check "helper" "$pname" "ok" "helper exists + executable"
        fi
        ;;
      env_var|keychain)
        shim_path="$helpers_dir/${pname}.sh"
        if [ ! -f "$shim_path" ]; then
          emit_check "helper" "$pname" "fail" "shim missing: $shim_path"
        else
          # Re-render to a tmp location and diff.
          tmp_shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/cp-doctor-shim.XXXXXX")"
          # Render into a tmp profile-dir tree. The renderer derives its
          # output path from $(profile_dir) which uses $HOME, so we run
          # the renderer in a subshell with HOME redirected. The parent
          # shell's HOME is not affected.
          # shellcheck disable=SC2030
          (
            HOME="$tmp_shim_dir"
            export HOME
            mkdir -p "$tmp_shim_dir/.claude/llm-profiles"
            cp "$pf" "$tmp_shim_dir/.claude/llm-profiles/${pname}.json"
            bash "$render_script" "$tmp_shim_dir/.claude/llm-profiles/${pname}.json" >/dev/null 2>&1 || true
          )
          rendered="$tmp_shim_dir/.claude/llm-profiles/.helpers/${pname}.sh"
          if [ ! -f "$rendered" ]; then
            emit_check "helper" "$pname" "fail" "shim could not be re-rendered for comparison"
          elif ! diff -q "$rendered" "$shim_path" >/dev/null 2>&1; then
            emit_check "helper" "$pname" "fail" "shim content drifted from template"
          else
            emit_check "helper" "$pname" "ok" "shim matches template"
          fi
          rm -rf "$tmp_shim_dir"
        fi
        ;;
      none)
        : # nothing to check
        ;;
    esac
  done
fi

# ============================================================
# SIDECAR integrity
# ============================================================
sidecar_ok=0
if [ ! -f "$sidecar" ]; then
  emit_check "sidecar" "" "fail" "sidecar missing: $sidecar"
elif ! jq empty "$sidecar" 2>/dev/null; then
  emit_check "sidecar" "" "fail" "sidecar is not valid JSON: $sidecar"
else
  sidecar_ok=1
  emit_check "sidecar" "" "ok" "$sidecar"
fi

# ============================================================
# DRIFT: for each tracked scope, compare managed_env_values vs settings.
# ============================================================
drift_found=0
if [ "$sidecar_ok" -eq 1 ]; then
  # Iterate scopes: global + every key in projects{}.
  scopes_list="$(jq -r '
    [ (if has("global") then "global" else empty end),
      (if has("projects") then (.projects | keys[] | "projects[\"" + . + "\"]") else empty end)
    ] | .[]' "$sidecar" 2>/dev/null || true)"

  while IFS= read -r scope_key; do
    [ -z "$scope_key" ] && continue
    scope_json="$(jq -c ".$scope_key // {}" "$sidecar")"
    # Empty scope: nothing to check.
    [ "$scope_json" = "{}" ] && continue

    target_file="$(printf '%s' "$scope_json" | jq -r '.target_file // ""')"
    [ -n "$target_file" ] || continue

    mkeys_json="$(printf '%s' "$scope_json" | jq -c '.managed_env_keys // []')"
    mvals_json="$(printf '%s' "$scope_json" | jq -c '.managed_env_values // {}')"
    m_ak_helper="$(printf '%s' "$scope_json" | jq -r '.managed_api_key_helper // false')"
    m_ak_helper_val="$(printf '%s' "$scope_json" | jq -r '.managed_api_key_helper_value // ""')"

    if [ ! -f "$target_file" ]; then
      emit_check "drift" "$scope_key" "warn" "target settings file missing: $target_file"
      continue
    fi
    if ! jq empty "$target_file" 2>/dev/null; then
      emit_check "drift" "$scope_key" "fail" "target settings file is not valid JSON: $target_file"
      drift_found=1
      continue
    fi

    # Managed env key drift.
    drifted_for_scope=""
    while IFS= read -r key; do
      [ -z "$key" ] && continue
      expected="$(printf '%s' "$mvals_json" | jq -r --arg k "$key" '.[$k] // ""')"
      actual="$(jq -r --arg k "$key" '.env[$k] // ""' "$target_file")"
      if [ "$expected" != "$actual" ]; then
        drifted_for_scope="$drifted_for_scope $key"
      fi
    done < <(printf '%s' "$mkeys_json" | jq -r '.[]')

    # apiKeyHelper drift.
    if [ "$m_ak_helper" = "true" ]; then
      actual_helper="$(jq -r '.apiKeyHelper // ""' "$target_file")"
      if [ "$actual_helper" != "$m_ak_helper_val" ]; then
        drifted_for_scope="$drifted_for_scope apiKeyHelper"
      fi
    fi

    if [ -n "$drifted_for_scope" ]; then
      drift_found=1
      emit_check "drift" "$scope_key" "fail" "drifted keys:$drifted_for_scope"
    else
      emit_check "drift" "$scope_key" "ok" "no drift"
    fi
  done < <(printf '%s\n' "$scopes_list")
fi

# ============================================================
# ENV MARKER vs sidecar (global.active_profile)
# ============================================================
if [ "$sidecar_ok" -eq 1 ]; then
  sidecar_global_active="$(jq -r '.global.active_profile // ""' "$sidecar")"
  env_marker="${CLAUDE_PROFILES_ACTIVE:-}"
  if [ -z "$env_marker" ] && [ -z "$sidecar_global_active" ]; then
    emit_check "envmarker" "" "ok" "no active profile"
  elif [ -z "$env_marker" ]; then
    emit_check "envmarker" "" "warn" "env marker unset; sidecar says: $sidecar_global_active"
  elif [ -z "$sidecar_global_active" ]; then
    emit_check "envmarker" "" "warn" "env marker=$env_marker; sidecar has no global active_profile"
  elif [ "$env_marker" != "$sidecar_global_active" ]; then
    emit_check "envmarker" "" "warn" "disagreement: env=$env_marker sidecar=$sidecar_global_active"
  else
    emit_check "envmarker" "" "ok" "env marker matches sidecar: $env_marker"
  fi
fi

# ============================================================
# REACHABILITY (A5): curl missing = SKIPPED, never silent pass.
# ============================================================
has_curl=1
if ! command -v curl >/dev/null 2>&1; then
  has_curl=0
fi

if [ -d "$target_dir" ]; then
  for pf in "$target_dir"/*.json; do
    [ -f "$pf" ] || continue
    pname="$(basename "$pf" .json)"
    # Skip if schema invalid — would have been flagged above.
    if ! bash "$validate_script" "$pf" >/dev/null 2>&1; then
      continue
    fi
    base_url="$(jq -r '.base_url // ""' "$pf")"
    [ -n "$base_url" ] && [ "$base_url" != "null" ] || continue

    if [ "$has_curl" -eq 0 ]; then
      emit_check "reachability" "$pname" "warn" "SKIPPED (curl not installed)"
      continue
    fi

    # -sS silent-but-show-errors; --max-time 5. Any HTTP response (even
    # a 4xx) means the host is reachable — we just record the code.
    # Don't fall-through append to %{http_code}: curl emits 000 on its
    # own for unreachable hosts, so rely on that and swallow failure.
    http_code="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$base_url" 2>/dev/null)" || http_code="000"
    [ -n "$http_code" ] || http_code="000"
    if [ "$http_code" = "000" ]; then
      emit_check "reachability" "$pname" "warn" "unreachable: $base_url"
    else
      emit_check "reachability" "$pname" "ok" "HTTP $http_code"
    fi
  done
fi

# ============================================================
# ORPHAN shims (shim exists for profile that no longer exists)
# ============================================================
orphan_shims=""
if [ -d "$helpers_dir" ]; then
  for shim in "$helpers_dir"/*.sh; do
    [ -f "$shim" ] || continue
    sname="$(basename "$shim" .sh)"
    if [ ! -f "$target_dir/${sname}.json" ]; then
      orphan_shims="$orphan_shims $shim"
      emit_check "orphan" "$sname" "warn" "orphan shim (no profile): $shim"
    fi
  done
fi

# ============================================================
# ORPHAN temp files (per §12a Write Protocol cleanup)
# ============================================================
orphan_tmp=""
if [ -d "$target_dir" ]; then
  # Match mktemp suffix pattern .<basename>.XXXXXX — six alphanumerics.
  while IFS= read -r f; do
    orphan_tmp="$orphan_tmp $f"
    emit_check "orphan" "" "warn" "orphan tempfile: $f"
  done < <(find "$target_dir" -maxdepth 2 -type f -name '.*.??????' 2>/dev/null)

  # Stale lock directory (§12a polyfill).
  if [ -d "$target_dir/.state.lock" ]; then
    lock_pid="$(cat "$target_dir/.state.lock/pid" 2>/dev/null || true)"
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      emit_check "orphan" "" "warn" "stale lock directory (PID $lock_pid dead)"
      orphan_tmp="$orphan_tmp $target_dir/.state.lock"
    fi
  fi
fi

# ============================================================
# --FIX: safe repairs
# ============================================================
fix_refused_drift=0
if [ "$do_fix" -eq 1 ]; then

  # Sidecar rebuild from env marker (A2.2).
  if [ "$sidecar_ok" -eq 0 ]; then
    env_marker="${CLAUDE_PROFILES_ACTIVE:-}"
    if [ -z "$env_marker" ]; then
      emit_check "fix" "sidecar" "fail" "cannot rebuild: CLAUDE_PROFILES_ACTIVE unset"
    else
      marker_profile="$target_dir/${env_marker}.json"
      if [ ! -f "$marker_profile" ]; then
        emit_check "fix" "sidecar" "fail" "cannot rebuild: profile not found: $env_marker"
      elif ! bash "$validate_script" "$marker_profile" >/dev/null 2>&1; then
        emit_check "fix" "sidecar" "fail" "cannot rebuild: profile fails schema: $env_marker"
      else
        # Compute what keys that profile would have managed.
        auth_type="$(jq -r '.auth.type' "$marker_profile")"
        base_url="$(jq -r '.base_url // ""' "$marker_profile")"
        ttl_ms="$(jq -r '.ttl_ms // ""' "$marker_profile")"
        extras_keys="$(jq -r '.extras // {} | keys[]' "$marker_profile" 2>/dev/null || true)"

        rebuilt_keys="CLAUDE_PROFILES_ACTIVE"
        rebuilt_vals="$(jq -nc --arg v "$env_marker" '{CLAUDE_PROFILES_ACTIVE: $v}')"
        if [ -n "$base_url" ] && [ "$base_url" != "null" ]; then
          rebuilt_keys="$rebuilt_keys ANTHROPIC_BASE_URL"
          rebuilt_vals="$(printf '%s' "$rebuilt_vals" | jq --arg v "$base_url" '.ANTHROPIC_BASE_URL = $v')"
        fi
        if [ -n "$ttl_ms" ] && [ "$ttl_ms" != "null" ]; then
          rebuilt_keys="$rebuilt_keys CLAUDE_CODE_API_KEY_HELPER_TTL_MS"
          rebuilt_vals="$(printf '%s' "$rebuilt_vals" | jq --arg v "$ttl_ms" '.CLAUDE_CODE_API_KEY_HELPER_TTL_MS = $v')"
        fi
        for ek in $extras_keys; do
          rebuilt_keys="$rebuilt_keys $ek"
          ev="$(jq -r --arg k "$ek" '.extras[$k]' "$marker_profile")"
          rebuilt_vals="$(printf '%s' "$rebuilt_vals" | jq --arg k "$ek" --arg v "$ev" '.[$k] = $v')"
        done

        r_ak_helper="false"
        r_ak_helper_val=""
        if [ "$auth_type" = "helper_script" ]; then
          hp="$(jq -r '.auth.path' "$marker_profile")"
          # shellcheck disable=SC2088  # literal-tilde pattern in case branches, not path expansion
          case "$hp" in
            "~/"*) hp="$HOME/${hp:2}" ;;
            "~")   hp="$HOME" ;;
          esac
          r_ak_helper="true"
          r_ak_helper_val="$hp"
        elif [ "$auth_type" = "env_var" ] || [ "$auth_type" = "keychain" ]; then
          r_ak_helper="true"
          r_ak_helper_val="$helpers_dir/${env_marker}.sh"
        fi

        rebuilt_keys_json="$(printf '%s' "$rebuilt_keys" | jq -Rsc 'split(" ") | map(select(length > 0))')"
        target_settings="$HOME/.claude/settings.local.json"

        rebuilt_scope="$(jq -nc \
          --argjson keys "$rebuilt_keys_json" \
          --argjson values "$rebuilt_vals" \
          --arg active "$env_marker" \
          --argjson ak_helper "$r_ak_helper" \
          --arg ak_helper_val "$r_ak_helper_val" \
          --arg target "$target_settings" \
          '{
            active_profile: $active,
            managed_env_keys: $keys,
            managed_env_values: $values,
            managed_api_key_helper: $ak_helper,
            managed_api_key_helper_value: $ak_helper_val,
            target_file: $target
          }')"

        # Write a fresh sidecar with global entry. Other scopes (if any
        # previously existed in a corrupt sidecar) are not recoverable
        # without their env markers and are dropped — user must switch
        # again in those projects.
        mkdir -p "$(dirname "$sidecar")"
        printf '%s\n' "$(jq -nc --argjson g "$rebuilt_scope" '{global: $g}')" \
          | atomic_write "$sidecar" 0600

        emit_check "fix" "sidecar" "ok" "rebuilt from env marker: $env_marker"
      fi
    fi
  fi

  # Regenerate drifted/missing shims for env_var/keychain profiles.
  if [ -d "$target_dir" ]; then
    for pf in "$target_dir"/*.json; do
      [ -f "$pf" ] || continue
      pname="$(basename "$pf" .json)"
      if ! bash "$validate_script" "$pf" >/dev/null 2>&1; then
        continue
      fi
      auth_type="$(jq -r '.auth.type // ""' "$pf")"
      case "$auth_type" in
        env_var|keychain)
          if bash "$render_script" "$pf" >/dev/null 2>&1; then
            emit_check "fix" "$pname" "ok" "shim regenerated"
          else
            emit_check "fix" "$pname" "fail" "shim regeneration failed"
          fi
          ;;
      esac
    done
  fi

  # Remove orphan shims.
  for shim in $orphan_shims; do
    [ -n "$shim" ] || continue
    if rm -f "$shim"; then
      emit_check "fix" "" "ok" "removed orphan shim: $shim"
    fi
  done

  # Remove orphan tmpfiles + stale locks.
  for f in $orphan_tmp; do
    [ -n "$f" ] || continue
    if [ -d "$f" ]; then
      rm -rf "$f" && emit_check "fix" "" "ok" "removed stale lock: $f" || true
    elif [ -f "$f" ]; then
      rm -f "$f" && emit_check "fix" "" "ok" "removed orphan tempfile: $f" || true
    fi
  done

  # Drift refusal: env-drift needs AskUserQuestion at the command layer.
  if [ "$drift_found" -eq 1 ]; then
    fix_refused_drift=1
    emit_check "fix" "drift" "fail" \
      "drift requires per-scope AskUserQuestion at the command layer; re-invoke apply-profile.sh --accept-drift=overwrite|incorporate per scope"
  fi
fi

# ============================================================
# Emit report
# ============================================================
if [ "$want_json" -eq 1 ]; then
  # Build a single JSON object: {checks: [...]}.
  jq -s '{checks: .}' "$checks_file"
else
  # Human-readable report grouped by section.
  [ "$want_verbose" -eq 1 ] && \
    printf 'claude-profiles: --verbose exposes paths. Only use in private.\n' >&2

  print_section() {
    local section_title="$1" category_filter="$2"
    local section_checks
    section_checks="$(jq -cs --arg c "$category_filter" '[.[] | select(.category == $c)]' "$checks_file")"
    local count
    count="$(printf '%s' "$section_checks" | jq 'length')"
    [ "$count" -eq 0 ] && return 0

    printf '\n== %s ==\n' "$section_title"
    # Emit one line per check. Redact profile-path-ish details unless
    # --verbose.
    printf '%s' "$section_checks" | jq -r '.[] | "[\(.status | ascii_upcase)] \(.profile // "-") — \(.detail)"' \
      | if [ "$want_verbose" -eq 1 ]; then cat; else \
          # Soft redaction for the default view: replace $HOME with ~.
          sed "s|$HOME|~|g"; fi
  }

  print_section "PROFILES (schema)"      "schema"
  print_section "HELPERS"                "helper"
  print_section "SIDECAR"                "sidecar"
  print_section "DRIFT"                  "drift"
  print_section "ENV MARKER"             "envmarker"
  print_section "REACHABILITY"           "reachability"
  print_section "ORPHANS"                "orphan"
  if [ "$do_fix" -eq 1 ]; then
    print_section "FIX ACTIONS"          "fix"
  fi
  printf '\n'
fi

# ============================================================
# Exit code derivation
# ============================================================
# Count final fails. In --fix mode, a successful repair for a category
# emits a "fix" OK record; those are not fails. Drift always produces a
# category=drift fail record; --fix cannot repair it (by design), so it
# remains a fail for exit-code purposes.
any_fail="$(jq -s 'map(select(.status == "fail")) | length' "$checks_file")"

if [ "$do_fix" -eq 1 ]; then
  # In --fix mode, the only remaining fails after repair should be:
  # drift (refused) + any fixes that themselves failed.
  if [ "$drift_found" -eq 1 ] || [ "$fix_refused_drift" -eq 1 ]; then
    exit "$CP_EXIT_DRIFT"
  fi
  if [ "$any_fail" -gt 0 ]; then
    # Something failed that --fix couldn't repair. Surface as drift/
    # unfixable (exit 8 per A5). The command layer can treat this as
    # "manual intervention required."
    exit "$CP_EXIT_DRIFT"
  fi
  exit "$CP_EXIT_OK"
fi

# Non-fix mode: drift → 8, any other fail → 1, all-ok → 0.
if [ "$drift_found" -eq 1 ]; then
  exit "$CP_EXIT_DRIFT"
fi
if [ "$any_fail" -gt 0 ]; then
  exit "$CP_EXIT_RUNTIME"
fi
exit "$CP_EXIT_OK"
