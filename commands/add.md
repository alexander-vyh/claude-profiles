---
description: Interactively create a new LLM profile (does not activate it)
---

Walk the user through creating a new LLM profile via a series of `AskUserQuestion` prompts, then invoke `create-profile.sh` non-interactively with the assembled flags. **This command does NOT activate the profile** — use `/claude-profiles:switch <name>` after creation.

Profile files live at `~/.claude/llm-profiles/<name>.json` (mode 0644).

### Interactive flow

Collect these fields using `AskUserQuestion`, one at a time. Validate each before moving to the next; if a value fails the rule, re-ask with the error message.

1. **name** (required). Pattern `^[a-z0-9][a-z0-9-]{0,62}$`. Lowercase, digits, hyphens; 1–63 chars; must start with a letter or digit. Example: `cake-gateway`.

2. **description** (optional, ≤200 chars). A short human-readable blurb. Empty string is fine.

3. **base_url** (optional). Must be `https://` unless hostname is `localhost` or `127.0.0.1`. Empty = omit the field entirely (relevant for `auth.type: none`).

4. **auth.type** (required). Present as a 4-option `AskUserQuestion`:
   - `none` — use Claude Code's default Anthropic OAuth / `ANTHROPIC_API_KEY` flow.
   - `helper_script` — point `apiKeyHelper` at an existing script you already have.
   - `env_var` — read the key from a single environment variable (plugin generates a shim).
   - `keychain` — read the key from macOS Keychain via `security` (plugin generates a shim). **macOS only.** If the user's OS is not macOS, warn and advise them to pick `helper_script` wrapping `secret-tool` / `pass` / `wincred` instead.

5. **Auth-type-specific fields.** Ask based on the choice in step 4:
   - `none`: no extra fields.
   - `helper_script`: ask for `auth.path`. Tilde allowed (e.g. `~/llm_gateway/token-helper.sh`); stored verbatim, expanded at apply time.
   - `env_var`: ask for `auth.var`. Must match `^[A-Z_][A-Z0-9_]*$` (uppercase + digits + underscore, must start with letter or underscore).
   - `keychain`: ask for `auth.service` (required) and `auth.account` (optional; defaults to `$USER`). Both must match `^[A-Za-z0-9_.-]{1,255}$` — shell metacharacters are rejected.

6. **ttl_ms** (optional). Integer milliseconds the apiKeyHelper cache is valid. Range 1000–86400000. Empty = omit.

7. **extras loop**. Ask: "Add an extra env var to this profile? (e.g. `CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000`)" via `AskUserQuestion` with options [Add one / Done]. On `Add one`, collect `KEY` (must match `^[A-Z_][A-Z0-9_]*$`) and `VALUE` (free-form string), then ask again. Reject keys on the EXTRAS_DENYLIST (`PATH`, `HOME`, `USER`, `SHELL`, `LD_*`, `DYLD_*`, `NODE_OPTIONS`, `PYTHONPATH`, `ANTHROPIC_BASE_URL`, `CLAUDE_PROFILES_ACTIVE`, `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`, etc. — the script will reject these anyway, but pre-filter for a nicer UX).

### Script invocation

Once every field is collected, invoke `create-profile.sh` with the gathered flags:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/create-profile.sh <name> \
  [--description "<desc>"] \
  [--base-url <url>] \
  --auth-type <none|helper_script|env_var|keychain> \
  [--auth-path <path>] \
  [--auth-var <VAR>] \
  [--auth-service <svc>] [--auth-account <acct>] \
  [--ttl-ms <n>] \
  [--extra KEY=VALUE]...
```

Pass `--extra` once per extras entry. Quote values that contain spaces.

### Exit codes

- **0** — success. Confirm creation to the user and suggest `/claude-profiles:switch <name>` to activate.
- **2** — usage error (bad flag combo). Relay stderr and offer to retry.
- **4** — profile already exists at `~/.claude/llm-profiles/<name>.json`. Tell the user and offer to pick a new name or use `/claude-profiles:edit <name>` instead. Do NOT overwrite.
- **6** — schema validation error (e.g., denylisted extras key, invalid keychain metacharacters, bad base_url scheme). Relay the specific rule that failed and offer to retry the affected step.

**Do not activate the profile on success.** Activation is a separate, explicit step.
