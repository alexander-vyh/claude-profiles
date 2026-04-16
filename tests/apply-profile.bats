#!/usr/bin/env bats
# Tests for scripts/apply-profile.sh — core merge algorithm (§5 as
# amended by A3). Scope: auth:none and auth:helper_script branches,
# global scope. env_var and keychain blocked on ads.2. Drift-incorporate
# deferred to a follow-up task.

setup() {
  load 'test_helper/common'
  setup_isolated_home
  PROFILES_DIR="$HOME/.claude/llm-profiles"
  SETTINGS="$HOME/.claude/settings.local.json"
  SIDECAR="$PROFILES_DIR/.state.json"
  mkdir -p "$PROFILES_DIR"
  mkdir -p "$(dirname "$SETTINGS")"

  # Profile A: bare auth:none
  cat > "$PROFILES_DIR/direct.json" << 'EOF'
{
  "name": "direct",
  "auth": { "type": "none" }
}
EOF

  # Profile B: helper_script with extras
  cat > "$PROFILES_DIR/gateway.json" << 'EOF'
{
  "name": "gateway",
  "base_url": "https://ai.simpli.fi",
  "auth": { "type": "helper_script", "path": "~/helper.sh" },
  "ttl_ms": 300000,
  "extras": {
    "LLM_GATEWAY": "1",
    "MAX_THINKING_TOKENS": "16000"
  }
}
EOF

  # Helper file for helper_script profiles (must exist + be executable
  # per Q7). Create a stub.
  printf '#!/bin/sh\necho test-key\n' > "$HOME/helper.sh"
  chmod +x "$HOME/helper.sh"
}

teardown() {
  teardown_isolated_home
}

apply() {
  run bash "$(cp_script apply-profile.sh)" "$@"
}

# ============================================================
# Happy path: auth:none, first switch
# ============================================================

@test "apply 'direct' (auth:none) on clean system: exits 9 (stale env)" {
  apply direct
  # Exit 9 is the "success, restart required" code.
  assert_failure 9
}

@test "apply 'direct' creates settings.local.json with CLAUDE_PROFILES_ACTIVE" {
  apply direct
  [ -f "$SETTINGS" ]
  run jq -r '.env.CLAUDE_PROFILES_ACTIVE' "$SETTINGS"
  assert_output "direct"
}

@test "apply 'direct' (auth:none) does NOT set apiKeyHelper" {
  apply direct
  run jq -r '.apiKeyHelper // "unset"' "$SETTINGS"
  assert_output "unset"
}

@test "apply 'direct' (auth:none) does NOT set ANTHROPIC_BASE_URL" {
  apply direct
  run jq -r '.env.ANTHROPIC_BASE_URL // "unset"' "$SETTINGS"
  assert_output "unset"
}

@test "apply writes sidecar with active_profile and managed_env_keys" {
  apply direct
  [ -f "$SIDECAR" ]
  run jq -r '.global.active_profile' "$SIDECAR"
  assert_output "direct"
  run jq -r '.global.managed_env_keys | contains(["CLAUDE_PROFILES_ACTIVE"])' "$SIDECAR"
  assert_output "true"
}

# ============================================================
# Happy path: auth:helper_script with extras
# ============================================================

@test "apply 'gateway' sets ANTHROPIC_BASE_URL" {
  apply gateway
  run jq -r '.env.ANTHROPIC_BASE_URL' "$SETTINGS"
  assert_output "https://ai.simpli.fi"
}

@test "apply 'gateway' sets apiKeyHelper to expanded path" {
  apply gateway
  run jq -r '.apiKeyHelper' "$SETTINGS"
  assert_output "$HOME/helper.sh"
}

@test "apply 'gateway' sets CLAUDE_CODE_API_KEY_HELPER_TTL_MS from ttl_ms" {
  apply gateway
  run jq -r '.env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS' "$SETTINGS"
  assert_output "300000"
}

@test "apply 'gateway' writes extras into env" {
  apply gateway
  run jq -r '.env.LLM_GATEWAY' "$SETTINGS"
  assert_output "1"
  run jq -r '.env.MAX_THINKING_TOKENS' "$SETTINGS"
  assert_output "16000"
}

@test "apply 'gateway' tracks all keys in sidecar managed_env_keys" {
  apply gateway
  for key in ANTHROPIC_BASE_URL CLAUDE_PROFILES_ACTIVE CLAUDE_CODE_API_KEY_HELPER_TTL_MS LLM_GATEWAY MAX_THINKING_TOKENS; do
    run jq --arg k "$key" '.global.managed_env_keys | index($k) != null' "$SIDECAR"
    assert_output "true"
  done
}

@test "apply 'gateway' records managed_api_key_helper = true" {
  apply gateway
  run jq -r '.global.managed_api_key_helper' "$SIDECAR"
  assert_output "true"
}

@test "apply 'gateway' records managed_api_key_helper_value (A2.1)" {
  apply gateway
  run jq -r '.global.managed_api_key_helper_value' "$SIDECAR"
  assert_output "$HOME/helper.sh"
}

# ============================================================
# Second switch: gateway → direct (removes gateway-unique keys)
# ============================================================

@test "switching gateway → direct removes gateway's unique managed keys" {
  apply gateway
  apply direct
  # ANTHROPIC_BASE_URL, CLAUDE_CODE_API_KEY_HELPER_TTL_MS,
  # LLM_GATEWAY, MAX_THINKING_TOKENS were gateway's — must be gone
  for key in ANTHROPIC_BASE_URL CLAUDE_CODE_API_KEY_HELPER_TTL_MS LLM_GATEWAY MAX_THINKING_TOKENS; do
    run jq -r --arg k "$key" '.env[$k] // "removed"' "$SETTINGS"
    assert_output "removed"
  done
  # CLAUDE_PROFILES_ACTIVE must be updated to "direct"
  run jq -r '.env.CLAUDE_PROFILES_ACTIVE' "$SETTINGS"
  assert_output "direct"
}

@test "switching gateway → direct removes apiKeyHelper (auth:none has none)" {
  apply gateway
  apply direct
  run jq -r '.apiKeyHelper // "removed"' "$SETTINGS"
  assert_output "removed"
}

# ============================================================
# Preserving user-set non-managed keys
# ============================================================

@test "apply preserves user-set keys that are not plugin-managed" {
  # User has a custom key in settings before any switch
  printf '{"env": {"MY_CUSTOM_VAR": "hello"}}' > "$SETTINGS"
  apply direct
  run jq -r '.env.MY_CUSTOM_VAR' "$SETTINGS"
  assert_output "hello"
}

# ============================================================
# Drift detection
# ============================================================

@test "drift detected after user hand-edits a managed key: exit 8" {
  apply gateway
  # User hand-edits ANTHROPIC_BASE_URL
  jq '.env.ANTHROPIC_BASE_URL = "https://hacked.example.com"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  # Switch to direct — should detect drift and exit 8
  apply direct
  assert_failure 8
  assert_output --partial "drift"
}

@test "drift with --accept-drift=overwrite applies new profile" {
  apply gateway
  jq '.env.ANTHROPIC_BASE_URL = "https://hacked.example.com"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  apply direct --accept-drift=overwrite
  # Exit 9 (stale env, success)
  assert_failure 9
  # ANTHROPIC_BASE_URL should be removed (direct is auth:none)
  run jq -r '.env.ANTHROPIC_BASE_URL // "removed"' "$SETTINGS"
  assert_output "removed"
}

# ============================================================
# Drift incorporate semantics (A4 step 4)
# ============================================================

@test "incorporate: drifted key in new managed set uses new profile's value" {
  apply gateway
  # User hand-edits ANTHROPIC_BASE_URL
  jq '.env.ANTHROPIC_BASE_URL = "https://user-edit.example.com"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  # Re-apply gateway with incorporate — ANTHROPIC_BASE_URL is still in
  # new_managed_keys, so new profile's value wins.
  apply gateway --accept-drift=incorporate
  run jq -r '.env.ANTHROPIC_BASE_URL' "$SETTINGS"
  assert_output "https://ai.simpli.fi"
}

@test "incorporate: drifted key NOT in new managed set preserved as unmanaged" {
  apply gateway
  # User hand-edits LLM_GATEWAY (was extras-managed by gateway)
  jq '.env.LLM_GATEWAY = "custom-value"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  # Switch to direct — direct has no LLM_GATEWAY in its managed set.
  # With incorporate, LLM_GATEWAY's drifted value is preserved as unmanaged.
  apply direct --accept-drift=incorporate
  run jq -r '.env.LLM_GATEWAY' "$SETTINGS"
  assert_output "custom-value"
}

@test "incorporate: drifted unmanaged key is NOT tracked in sidecar" {
  apply gateway
  jq '.env.LLM_GATEWAY = "custom-value"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  apply direct --accept-drift=incorporate
  # LLM_GATEWAY survives in settings, but sidecar no longer manages it.
  run jq -r '.global.managed_env_keys | index("LLM_GATEWAY")' "$SIDECAR"
  assert_output "null"
}

@test "incorporate: apiKeyHelper drift refused — must use per-helper confirmation" {
  apply gateway
  # User hand-edits apiKeyHelper to a malicious path
  printf '#!/bin/sh\necho bad\n' > "$HOME/malicious.sh"
  chmod +x "$HOME/malicious.sh"
  jq --arg h "$HOME/malicious.sh" '.apiKeyHelper = $h' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  # incorporate should REFUSE — apiKeyHelper drift needs explicit per-helper
  # confirmation (A4 step 4: "NEVER incorporated without re-validation").
  apply direct --accept-drift=incorporate
  assert_failure 8
  assert_output --partial "apiKeyHelper"
}

@test "incorporate: subsequent switch without drift proceeds normally" {
  apply gateway
  # Normal switch to direct — no hand-edits, no drift
  apply direct --accept-drift=incorporate
  # --accept-drift=incorporate when there's no drift is a no-op
  assert_failure 9
  run jq -r '.env.CLAUDE_PROFILES_ACTIVE' "$SETTINGS"
  assert_output "direct"
}

# ============================================================
# Error paths
# ============================================================

@test "nonexistent profile exits 3" {
  apply does-not-exist
  assert_failure 3
}

@test "missing argument exits 2 (usage)" {
  apply
  assert_failure 2
}

@test "invalid profile exits 6" {
  printf '{"name": "bad-profile", "auth": {"type": "magic"}}' > "$PROFILES_DIR/bad-profile.json"
  apply bad-profile
  assert_failure 6
}

@test "sidecar corrupt exits 1 with recovery hint (A2.2)" {
  # Write corrupt sidecar
  printf 'not json {{{' > "$SIDECAR"
  apply direct
  assert_failure 1
  assert_output --partial "doctor"
}

# ============================================================
# Atomic write verification (§12a)
# ============================================================

@test "settings.local.json is written atomically (no orphan tmpfiles)" {
  apply gateway
  orphans=$(find "$(dirname "$SETTINGS")" -maxdepth 1 -name ".settings.local.json.*" 2>/dev/null)
  [ -z "$orphans" ]
}

@test "sidecar is written atomically (no orphan tmpfiles)" {
  apply gateway
  orphans=$(find "$PROFILES_DIR" -maxdepth 1 -name ".state.json.*" 2>/dev/null)
  [ -z "$orphans" ]
}

@test "helper_script path expanded at apply time (Q7)" {
  apply gateway
  # The ~ in profile becomes $HOME at apply
  run jq -r '.apiKeyHelper' "$SETTINGS"
  [[ "$output" = "$HOME/helper.sh" ]]
  [[ "$output" != *'~'* ]]
}

@test "helper_script missing file: apply refuses with clear error" {
  rm -f "$HOME/helper.sh"
  apply gateway
  assert_failure
  assert_output --partial "helper.sh"
}
