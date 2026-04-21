#!/usr/bin/env bats
# Tests for scripts/create-profile.sh — non-interactive profile writer per
# §7 /add row. Builds a profile JSON from CLI flags, validates via
# validate-profile.sh, then atomically writes to ~/.claude/llm-profiles/<name>.json.

setup() {
  load 'test_helper/common'
  setup_isolated_home
  PROFILES_DIR="$HOME/.claude/llm-profiles"
  # create-profile.sh is responsible for creating the dir itself; do not
  # pre-create here so we exercise that path too.
}

teardown() {
  teardown_isolated_home
}

create() {
  run bash "$(cp_script create-profile.sh)" "$@"
}

# ============================================================
# Happy paths
# ============================================================

@test "auth:none profile creates file with correct JSON, exit 0" {
  create anthropic-direct --auth-type none --description "Default Anthropic auth"
  assert_success
  local path="$PROFILES_DIR/anthropic-direct.json"
  [ -f "$path" ]
  assert_equal "$(jq -r '.name' "$path")" "anthropic-direct"
  assert_equal "$(jq -r '.auth.type' "$path")" "none"
  assert_equal "$(jq -r '.description' "$path")" "Default Anthropic auth"
  # No base_url, ttl_ms, or extras for a minimal auth:none profile.
  assert_equal "$(jq -r 'has("base_url")' "$path")" "false"
  assert_equal "$(jq -r 'has("ttl_ms")' "$path")" "false"
  assert_equal "$(jq -r 'has("extras")' "$path")" "false"
}

@test "auth:helper_script with base_url, ttl_ms, and repeated --extras" {
  create cake-gateway \
    --auth-type helper_script \
    --auth-path '~/llm_gateway/token-helper.sh' \
    --base-url https://ai.simpli.fi \
    --ttl-ms 300000 \
    --extras LLM_GATEWAY=1 \
    --extras MAX_THINKING_TOKENS=16000
  assert_success
  local path="$PROFILES_DIR/cake-gateway.json"
  [ -f "$path" ]
  assert_equal "$(jq -r '.name' "$path")" "cake-gateway"
  assert_equal "$(jq -r '.base_url' "$path")" "https://ai.simpli.fi"
  assert_equal "$(jq -r '.auth.type' "$path")" "helper_script"
  assert_equal "$(jq -r '.auth.path' "$path")" '~/llm_gateway/token-helper.sh'
  assert_equal "$(jq -r '.ttl_ms' "$path")" "300000"
  assert_equal "$(jq -r '.extras.LLM_GATEWAY' "$path")" "1"
  assert_equal "$(jq -r '.extras.MAX_THINKING_TOKENS' "$path")" "16000"
}

@test "auth:env_var profile stores var name literally" {
  create vault-gateway \
    --auth-type env_var \
    --auth-var VAULT_TOKEN \
    --base-url https://vault.example.com
  assert_success
  local path="$PROFILES_DIR/vault-gateway.json"
  assert_equal "$(jq -r '.auth.type' "$path")" "env_var"
  assert_equal "$(jq -r '.auth.var' "$path")" "VAULT_TOKEN"
}

@test "auth:keychain profile with service + account (Darwin only)" {
  [ "$(uname)" = "Darwin" ] || skip "keychain is macOS-only"
  create mac-keychain \
    --auth-type keychain \
    --auth-service company-gateway \
    --auth-account alice
  assert_success
  local path="$PROFILES_DIR/mac-keychain.json"
  assert_equal "$(jq -r '.auth.type' "$path")" "keychain"
  assert_equal "$(jq -r '.auth.service' "$path")" "company-gateway"
  assert_equal "$(jq -r '.auth.account' "$path")" "alice"
}

@test "file is created with mode 0644" {
  create simple --auth-type none
  assert_success
  local path="$PROFILES_DIR/simple.json"
  [ -f "$path" ]
  local mode
  mode="$(file_mode "$path")"
  assert_equal "$mode" "644"
}

# ============================================================
# Usage / precondition errors
# ============================================================

@test "missing name exits 2" {
  create --auth-type none
  assert_failure 2
}

@test "unknown flag exits 2" {
  create somename --auth-type none --totally-bogus-flag
  assert_failure 2
}

@test "missing --auth-type exits 2" {
  create named-but-no-auth
  assert_failure 2
}

@test "helper_script without --auth-path exits 2" {
  create bad-combo --auth-type helper_script
  assert_failure 2
}

@test "env_var without --auth-var exits 2" {
  create bad-envvar --auth-type env_var
  assert_failure 2
}

@test "keychain without --auth-service exits 2" {
  [ "$(uname)" = "Darwin" ] || skip "keychain is macOS-only"
  create bad-keychain --auth-type keychain
  assert_failure 2
}

@test "none with --auth-path exits 2 (mutually exclusive)" {
  create mixed --auth-type none --auth-path '~/foo.sh'
  assert_failure 2
}

@test "malformed --extras (no '=') exits 2" {
  create bad-extras --auth-type none --extras JUST_A_KEY
  assert_failure 2
}

@test "--extras with lowercase key exits 2 (usage, before validate)" {
  # Lowercase keys are obviously bad; reject at arg-parse time so we fail
  # fast with a clear usage message rather than a schema error.
  create bad-extras2 --auth-type none --extras lowercase=val
  assert_failure 2
}

# ============================================================
# Existing-file refusal (exit 4)
# ============================================================

@test "profile already exists exits 4" {
  mkdir -p "$PROFILES_DIR"
  printf '{"name":"preexisting","auth":{"type":"none"}}' > "$PROFILES_DIR/preexisting.json"
  create preexisting --auth-type none
  assert_failure 4
}

# ============================================================
# Schema validation forwarded from validate-profile.sh (exit 6)
# ============================================================

@test "extras key in denylist forwards validator exit 6" {
  create evil --auth-type none --extras PATH=/tmp/evil
  assert_failure 6
}

@test "extras key colliding with plugin-managed forwards exit 6" {
  create evil2 --auth-type none --extras ANTHROPIC_BASE_URL=https://evil.com
  assert_failure 6
}

@test "http:// base_url (non-localhost) forwards exit 6" {
  create insecure --auth-type none --base-url http://example.com
  assert_failure 6
}

@test "invalid name pattern (uppercase) forwards exit 6" {
  # Name regex is caught by validate-profile (rule on .name pattern).
  create BadName --auth-type none
  assert_failure 6
}

@test "no profile file is written when validation fails" {
  create evil3 --auth-type none --extras PATH=/tmp/evil
  assert_failure 6
  [ ! -e "$PROFILES_DIR/evil3.json" ]
}

# ============================================================
# Does NOT activate — create is separate from switch
# ============================================================

@test "create does not touch settings.local.json" {
  create harmless --auth-type none
  assert_success
  [ ! -e "$HOME/.claude/settings.local.json" ]
}

@test "create does not write sidecar state" {
  create harmless2 --auth-type none
  assert_success
  [ ! -e "$PROFILES_DIR/.state.json" ]
}
