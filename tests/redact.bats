#!/usr/bin/env bats
# Tests for scripts/redact.sh — Amendment A7 redaction scope.
#
# A7 table:
#   auth.path           -> ~/***
#   auth.var            -> ***_VAR
#   auth.service        -> ***
#   auth.account        -> ***
#   base_url            -> hostname only (scheme://host/...)
#   base_url localhost  -> verbatim
#   base_url 127.0.0.1  -> verbatim
#   apiKeyHelper        -> ~/***
#   extras keys/values  -> verbatim

setup() {
  load 'test_helper/common'
  setup_isolated_home
}

teardown() {
  teardown_isolated_home
}

redact_stdin() {
  run bash "$(cp_script redact.sh)" "$@"
}

# ============================================================
# Stdin vs file argument
# ============================================================

@test "reads from stdin when no file argument" {
  json='{"name":"p","auth":{"type":"helper_script","path":"~/secret/token.sh"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"~/***"'
}

@test "reads from file when file argument given" {
  path="$HOME/profile.json"
  printf '%s' '{"name":"p","auth":{"type":"helper_script","path":"~/secret/token.sh"}}' > "$path"
  run bash "$(cp_script redact.sh)" "$path"
  assert_success
  assert_output --partial '"~/***"'
}

# ============================================================
# auth field redactions
# ============================================================

@test "redacts auth.path to ~/***" {
  json='{"name":"p","auth":{"type":"helper_script","path":"/Users/alice/llm/tok.sh"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"path": "~/***"'
  refute_output --partial 'alice'
  refute_output --partial 'tok.sh'
}

@test "redacts auth.var to ***_VAR" {
  json='{"name":"p","auth":{"type":"env_var","var":"VAULT_TOKEN"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"var": "***_VAR"'
  refute_output --partial 'VAULT_TOKEN'
}

@test "redacts auth.service to ***" {
  json='{"name":"p","auth":{"type":"keychain","service":"company-gateway"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"service": "***"'
  refute_output --partial 'company-gateway'
}

@test "redacts auth.account to ***" {
  json='{"name":"p","auth":{"type":"keychain","service":"svc","account":"alice"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"account": "***"'
  assert_output --partial '"service": "***"'
  refute_output --partial 'alice'
  refute_output --partial '"svc"'
}

# ============================================================
# base_url redactions
# ============================================================

@test "redacts base_url to hostname only" {
  json='{"name":"p","base_url":"https://ai.simpli.fi/v1/abc/def","auth":{"type":"none"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"base_url": "https://ai.simpli.fi/..."'
  refute_output --partial '/v1/abc/def'
}

@test "redacts base_url drops port and path" {
  json='{"name":"p","base_url":"https://api.example.com:8443/tenant/xyz","auth":{"type":"none"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"base_url": "https://api.example.com/..."'
  refute_output --partial '8443'
  refute_output --partial 'tenant'
  refute_output --partial 'xyz'
}

@test "preserves base_url for localhost verbatim" {
  json='{"name":"p","base_url":"http://localhost:8080/v1","auth":{"type":"none"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"base_url": "http://localhost:8080/v1"'
}

@test "preserves base_url for 127.0.0.1 verbatim" {
  json='{"name":"p","base_url":"http://127.0.0.1:9000/api","auth":{"type":"none"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"base_url": "http://127.0.0.1:9000/api"'
}

@test "passes through null base_url unchanged" {
  json='{"name":"p","base_url":null,"auth":{"type":"none"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"base_url": null'
}

@test "passes through missing base_url unchanged" {
  json='{"name":"p","auth":{"type":"none"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  refute_output --partial '"base_url"'
}

# ============================================================
# Top-level apiKeyHelper (settings-shaped JSON)
# ============================================================

@test "redacts top-level apiKeyHelper to ~/***" {
  json='{"env":{"ANTHROPIC_BASE_URL":"https://ai.simpli.fi"},"apiKeyHelper":"/Users/alice/llm/tok.sh"}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"apiKeyHelper": "~/***"'
  refute_output --partial 'alice'
  refute_output --partial 'tok.sh'
}

# ============================================================
# extras — NOT redacted (verbatim per A7)
# ============================================================

@test "preserves extras keys verbatim" {
  json='{"name":"p","auth":{"type":"none"},"extras":{"CLAUDE_CODE_MAX_OUTPUT_TOKENS":"64000","LLM_GATEWAY":"1"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial 'CLAUDE_CODE_MAX_OUTPUT_TOKENS'
  assert_output --partial 'LLM_GATEWAY'
}

@test "preserves extras values verbatim" {
  json='{"name":"p","auth":{"type":"none"},"extras":{"CLAUDE_CODE_MAX_OUTPUT_TOKENS":"64000","MODEL_NAME":"claude-sonnet-4-5"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"64000"'
  assert_output --partial '"claude-sonnet-4-5"'
}

# ============================================================
# Other fields unchanged
# ============================================================

@test "preserves name, description, ttl_ms, auth.type unchanged" {
  json='{"name":"cake-gateway","description":"Simpli.fi gateway","auth":{"type":"env_var","var":"TOK"},"ttl_ms":300000}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"name": "cake-gateway"'
  assert_output --partial '"description": "Simpli.fi gateway"'
  assert_output --partial '"type": "env_var"'
  assert_output --partial '"ttl_ms": 300000'
  assert_output --partial '"var": "***_VAR"'
}

# ============================================================
# --verbose flag: pass-through with stderr banner
# ============================================================

@test "--verbose passes input through unchanged" {
  json='{"name":"p","base_url":"https://ai.simpli.fi/v1/abc","auth":{"type":"helper_script","path":"/Users/alice/tok.sh"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)' --verbose"
  assert_success
  assert_output --partial '/Users/alice/tok.sh'
  assert_output --partial 'https://ai.simpli.fi/v1/abc'
}

@test "-v alias passes input through unchanged" {
  json='{"name":"p","auth":{"type":"env_var","var":"VAULT_TOKEN"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)' -v"
  assert_success
  assert_output --partial 'VAULT_TOKEN'
}

@test "--verbose prints stderr banner" {
  json='{"name":"p","auth":{"type":"none"}}'
  stderr_file="$HOME/stderr"
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)' --verbose 2>'$stderr_file'"
  assert_success
  run cat "$stderr_file"
  assert_output --partial 'reconnaissance'
  assert_output --partial '--verbose'
}

# ============================================================
# Error handling
# ============================================================

@test "invalid JSON input exits 6" {
  run bash -c "printf 'not json {{{' | bash '$(cp_script redact.sh)'"
  assert_failure 6
}

@test "nonexistent file exits 3" {
  run bash "$(cp_script redact.sh)" "$HOME/does-not-exist.json"
  assert_failure 3
}

@test "unknown flag exits 2" {
  json='{"name":"p","auth":{"type":"none"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)' --bogus"
  assert_failure 2
}

# ============================================================
# Compound redaction (realistic profile)
# ============================================================

@test "redacts all A7 fields in a full helper_script profile" {
  json='{"name":"cake-gateway","description":"gateway","base_url":"https://ai.simpli.fi/v1/abc","auth":{"type":"helper_script","path":"/Users/alice/llm/tok.sh"},"ttl_ms":300000,"extras":{"MODEL":"sonnet"}}'
  run bash -c "printf '%s' '$json' | bash '$(cp_script redact.sh)'"
  assert_success
  assert_output --partial '"path": "~/***"'
  assert_output --partial '"base_url": "https://ai.simpli.fi/..."'
  assert_output --partial '"MODEL": "sonnet"'
  refute_output --partial 'alice'
  refute_output --partial '/v1/abc'
}
