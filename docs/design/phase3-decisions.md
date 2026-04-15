# Phase 3 Design Decisions

This document captures all design decisions made during Phases 1–3 of the initial
design pass for `claude-profiles` v0.1.0. It is the source of truth for
implementation and should be consulted before any code is written or modified.

Design method: `/plugin-dev:create-plugin` workflow, Phases 1–3.

---

## 1. Decision Record

### Phase 1–2 decisions

| # | Decision | Value | Rationale |
|---|----------|-------|-----------|
| 1 | Scope model | Both **global** and **per-project** | User has projects requiring locked auth and projects allowing switching. |
| 1b | Lock behavior in locked projects | **Refuse by default** — require `--global` to change global scope or `--force` to override project lock | Safest; prevents silent cross-project breakage. |
| 2 | Secret storage model | Plugin holds only **references**; delegates to Claude Code's built-in `apiKeyHelper` | Matches published-plugin norms. Plugin files never contain secret material. |
| 3 | Profile knobs | Optional `ttl_ms` + free-form `extras` map of env vars | Supports full cake-style gateway config, keeps simple profiles simple. |
| 4 | Plugin name | `claude-profiles` | Verified not taken in Anthropic official marketplace, ComposioHQ curated list, rohitg00 toolkit, jeremylongshore marketplace. |

### Phase 3 decisions (Q1–Q7)

| # | Question | Choice | Rationale |
|---|----------|--------|-----------|
| Q1 | Target file for writes | `settings.local.json` (both global and project scopes) | Machine-specific auth state should never be tracked in git. `.local.json` is gitignored by default. |
| Q2 | Default scope when neither `--global` nor `--project` given | **Always global**; `--project` required explicitly | Matches lock-by-default philosophy. Silent scope picking is how you accidentally edit the wrong file. |
| Q3 | Active-profile detection | **Both**: env marker (`CLAUDE_PROFILES_ACTIVE`) AND sidecar state file, with drift detection on disagreement | Defensive. Trust-but-verify. Each failure mode maps to a distinct repair path. |
| Q4 | Drift handling in `switch` | **Warn + show diff + AskUserQuestion confirm** | Loud but not blocking. Respects user agency. |
| Q5 | Keychain auth type on non-macOS | **macOS-only**. `validate-profile.sh` rejects `auth.type: keychain` on other OSes. | Smallest test surface for v1. Linux/Windows users use `helper_script` wrapping `secret-tool`/`pass`/`wincred`. |
| Q6 | `/remove` when profile is active | **Refuse**. User must `/switch` away first. Exit 5. | Safest. No spooky action at a distance. |
| Q7 | Tilde expansion in `auth.path` | Store `~/...` in profile, **expand at apply time**, fail loud if file missing/non-executable | Portable profiles (shareable across machines), loud failures on misconfiguration. |

### Deferred to v2

- **`profile-migrator` agent** — scan a repo's `.envrc` + `.claude/settings.local.json`, propose a profile from detected env vars.
- **`SessionStart` hook** — warn when the active profile's helper is broken / env var unset. `/doctor` covers this on-demand in v1.
- **`auth.type: secret_tool`** — first-class Linux libsecret support.
- **`auth.type: os_secret_store`** — auto-detecting backend per OS.

---

## 2. Profile Schema

Profile files live at `~/.claude/llm-profiles/<name>.json` with mode 0644.
Schema validation happens via `lib/profile-schema.json` (JSON Schema Draft 7).

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "claude-profiles profile",
  "type": "object",
  "required": ["name", "auth"],
  "additionalProperties": false,
  "properties": {
    "name":        { "type": "string", "pattern": "^[a-z0-9][a-z0-9-]{0,62}$" },
    "description": { "type": "string", "maxLength": 200 },
    "base_url":    { "type": ["string", "null"], "format": "uri" },
    "auth":        { "oneOf": [ "<see auth branches below>" ] },
    "ttl_ms":      { "type": "integer", "minimum": 1000, "maximum": 86400000 },
    "extras":      {
      "type": "object",
      "patternProperties": { "^[A-Z_][A-Z0-9_]*$": { "type": "string" } },
      "additionalProperties": false
    }
  }
}
```

### `auth` oneOf branches

| `auth.type` | Required fields | Optional fields | Meaning |
|-------------|-----------------|-----------------|---------|
| `none` | — | — | Don't set `ANTHROPIC_BASE_URL` or `apiKeyHelper`. Let Claude Code's default Anthropic OAuth / `ANTHROPIC_API_KEY` flow run. |
| `helper_script` | `path` (string) | — | Point `apiKeyHelper` directly at the user's existing script. `path` may contain `~` (expanded at apply time). |
| `env_var` | `var` (string, matches `^[A-Z_][A-Z0-9_]*$`) | — | Plugin generates a shim that `printf "$VAR"`. |
| `keychain` | `service` (string) | `account` (string, defaults to `$USER`) | Plugin generates a shim running `security find-generic-password -w -s <service> -a <account>`. macOS only. |

### Additional validation rules (enforced by `validate-profile.sh`)

1. `name` field MUST equal the filename basename (`cake-gateway.json` → `name: "cake-gateway"`).
2. `base_url` MUST be `https://` — refuse `http://` — except for `localhost` and `127.0.0.1`.
3. For `auth.type: helper_script`, the `path` is tilde-expanded but the file need NOT exist at validation time (supports portable/shared profiles).
4. `extras` keys MUST NOT collide with plugin-managed keys (see §3).
5. Unknown top-level keys → error.
6. On non-macOS hosts, `auth.type: keychain` → error.

---

## 3. Settings Mutation Model

Target file for all writes:

| Scope | Target file |
|-------|-------------|
| Global | `~/.claude/settings.local.json` |
| Project | `<repo>/.claude/settings.local.json` |

Claude Code's settings precedence means the project-local file wins over the
global file at startup. This is why a per-project setting implicitly "locks"
the project regardless of what global setting says.

### Plugin-managed keys

The plugin owns these keys and will overwrite them on `switch`:

- **Always:**
  - `.env.ANTHROPIC_BASE_URL`
  - `.env.CLAUDE_PROFILES_ACTIVE`
  - `.apiKeyHelper` (top-level)
- **Conditional:**
  - `.env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS` — only if profile sets `ttl_ms`
- **User-extensible:**
  - Every key in the active profile's `extras` object

### Mutation examples

**Profile (for all examples below):**
```json
{
  "name": "cake-gateway",
  "base_url": "https://ai.simpli.fi",
  "auth": { "type": "helper_script", "path": "~/llm_gateway/token-helper.sh" },
  "ttl_ms": 300000,
  "extras": {
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "16000",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-5-20250929[1m]",
    "LLM_GATEWAY": "1"
  }
}
```

#### Case A — `helper_script`

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://ai.simpli.fi",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS": "300000",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "16000",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-5-20250929[1m]",
    "LLM_GATEWAY": "1",
    "CLAUDE_PROFILES_ACTIVE": "cake-gateway"
  },
  "apiKeyHelper": "/Users/<user>/llm_gateway/token-helper.sh"
}
```

`~` is expanded to an absolute path. `switch` refuses if file does not exist or
is not executable (Q7).

#### Case B — `env_var`

Plugin first writes `~/.claude/llm-profiles/.helpers/<name>.sh` mode 0700:

```sh
#!/bin/sh
# Generated by claude-profiles — do not hand-edit
printf '%s' "${ANTHROPIC_API_KEY_COMPANY_GATEWAY:-}"
```

Then `apiKeyHelper` points at that shim. `.env` block structure same as Case A.

#### Case C — `keychain`

Shim at `~/.claude/llm-profiles/.helpers/<name>.sh` mode 0700:

```sh
#!/bin/sh
# Generated by claude-profiles
security find-generic-password -w -s "company-gateway" -a "${USER}" 2>/dev/null
```

Same env block + shim path. macOS only.

#### Case D — `none`

```json
{
  "env": {
    "CLAUDE_PROFILES_ACTIVE": "anthropic-direct"
  }
}
```

No `ANTHROPIC_BASE_URL`, no `apiKeyHelper`. Claude Code's default auth runs.

---

## 4. Sidecar State File

Path: `~/.claude/llm-profiles/.state.json`, mode 0644.

```json
{
  "global": {
    "active_profile": "cake-gateway",
    "managed_env_keys": [
      "ANTHROPIC_BASE_URL",
      "CLAUDE_CODE_API_KEY_HELPER_TTL_MS",
      "CLAUDE_PROFILES_ACTIVE",
      "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
      "MAX_THINKING_TOKENS",
      "ANTHROPIC_DEFAULT_SONNET_MODEL",
      "LLM_GATEWAY"
    ],
    "managed_api_key_helper": true,
    "target_file": "/Users/<user>/.claude/settings.local.json"
  },
  "projects": {
    "/Users/<user>/GitHub/cake": {
      "active_profile": "cake-gateway",
      "managed_env_keys": ["..."],
      "managed_api_key_helper": true,
      "target_file": "/Users/<user>/GitHub/cake/.claude/settings.local.json"
    }
  }
}
```

The sidecar is a second source of truth next to the target settings file. The
plugin uses it to know **which keys it wrote last time** so that unrelated
user-set keys are preserved on subsequent switches.

---

## 5. Merge Algorithm (`apply-profile.sh`)

1. Read target settings file (or `{}` if absent).
2. Read sidecar → `prev_managed_keys` for this scope (or `[]` if scope not tracked).
3. Remove each of `prev_managed_keys` from `.env`.
4. If `managed_api_key_helper: true` for this scope, remove top-level `.apiKeyHelper`.
5. Read new profile → compute `new_managed_keys` based on auth type, `ttl_ms`, `extras`.
6. **Drift detection:** for each key in `prev_managed_keys`, if the current settings file has a value different from what the sidecar says we wrote → that's drift. Enter drift-confirm flow (§6).
7. Write new keys into `.env`, write new `apiKeyHelper` path if applicable.
8. `jq` write to `<target>.tmp`, then `mv` atomically (atomic on POSIX `rename(2)` within a filesystem).
9. Update sidecar: record `new_managed_keys`, `active_profile`, `managed_api_key_helper`.

---

## 6. Drift Handling

When `apply-profile.sh` detects that a plugin-managed key was hand-edited between
two `switch` invocations, it must not silently overwrite. The drift-confirm flow:

1. Compute diff: for each changed key, show `expected (sidecar) vs actual (file)`.
2. Print the diff to stderr for user visibility.
3. Invoke `AskUserQuestion` via the command layer (not the script) with three options:
   - **Overwrite with new profile's values** (forget the drift)
   - **Cancel switch, keep drift**
   - **Incorporate drift into sidecar** (treat the current file as the new baseline)
4. Apply selected action.

The script exits with code **8** if drift is detected and unconfirmed, and code **0**
if drift was detected AND resolved via one of the above actions.

`/doctor --fix` provides a standalone repair flow that does the same thing.

---

## 7. Command Spec Table

| Command | Args / Flags | Behavior | Main script | Exit codes |
|---------|--------------|----------|-------------|------------|
| `init` | — | Creates `~/.claude/llm-profiles/` (0755), `.helpers/` (0700), `.state.json` (empty); seeds `anthropic-direct.json` + `gateway-example.json`. Idempotent (refuses overwrite). | `init.sh` | 0, 1 |
| `list` | `[--json]` | Reads all `*.json` in profile dir + sidecar. Shows table of profile name → auth type → global-active? → project-active?. Flags drift with `*`. | `list-profiles.sh` | 0 |
| `current` | `[--json] [--verbose]` | Computes effective profile for current cwd. Cross-checks env marker vs sidecar; reports drift. Redacts secret paths unless `--verbose`. | `get-active.sh --scope=effective` | 0, 8 |
| `switch` | `<name>` `[--global\|--project]` `[--force]` | Default scope = global. `--project` errors outside git repo. Detects drift → AskUserQuestion confirm. Expands `~`, refuses if file missing/non-exec. Atomic write. Updates sidecar. Prints restart reminder. | `apply-profile.sh` | 0, 2, 3, 5, 6, 8 |
| `add` | — (interactive) | Command `.md` walks Claude through `AskUserQuestion` prompts for name, description, base_url, auth.type, auth fields, ttl_ms, extras loop. Calls `create-profile.sh` non-interactively. Does NOT activate. | `create-profile.sh` | 0, 2, 4, 6 |
| `remove` | `<name>` | Refuses if profile is active anywhere (exit 5). Otherwise AskUserQuestion confirm, deletes profile JSON + plugin-generated helper shim at `.helpers/<name>.sh`. | `remove-profile.sh` | 0, 2, 3, 5 |
| `edit` | `<name>` | Reads profile path, opens `${EDITOR:-vi}` on the file. On save, validates. If invalid, shows errors + offers re-edit. Warns if profile is active. | `validate-profile.sh` | 0, 3, 6 |
| `doctor` | `[--fix]` | Per-profile checks: schema, helper exists+executable (`helper_script`), shim matches template (`env_var`/`keychain`), optional `curl --max-time 5` probe of base_url. Verifies sidecar vs settings file integrity. `--fix` repairs drift interactively. | `doctor.sh` | 0, 1, 8 |

---

## 8. Scripts Inventory

All under `scripts/` at plugin root, invoked as `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh ...`.

| Script | Purpose | Depends on |
|--------|---------|------------|
| `lib.sh` | Shared helpers — profile dir resolution, JSON I/O via `jq`, color/error formatting, scope detection | — |
| `validate-profile.sh` | Validate a profile file against `lib/profile-schema.json` | `lib.sh`, `lib/profile-schema.json` |
| `list-profiles.sh` | Emit JSON listing profiles with active markers for global + project scope | `lib.sh` |
| `get-active.sh [--scope=global\|project\|effective]` | Read active profile name from target settings file + sidecar | `lib.sh` |
| `create-profile.sh <name> --base-url X --auth-type Y ...` | Non-interactive profile writer; validates then writes JSON | `lib.sh`, `validate-profile.sh` |
| `apply-profile.sh <name> [--scope] [--force]` | **Core switch logic** — merge algorithm (§5), drift detection (§6), atomic write, sidecar update | `lib.sh`, `validate-profile.sh`, `render-apikey-helper.sh` |
| `remove-profile.sh <name>` | Delete profile file + helper shim, with safety checks | `lib.sh`, `get-active.sh` |
| `doctor.sh [--fix]` | Run all diagnostics across all profiles | all other scripts |
| `init.sh` | Bootstrap `~/.claude/llm-profiles/` and write seed profiles | `lib.sh`, `templates/*` |
| `render-apikey-helper.sh <profile-path>` | Render helper shim from template into `~/.claude/llm-profiles/.helpers/<name>.sh` mode 0700 | `lib.sh`, `templates/helper-*.sh.tmpl` |
| `redact.sh` | Mask secret-ish fields for display (helper_script paths, env var names) | `lib.sh` |

---

## 9. Templates

All under `templates/`:

| File | Purpose |
|------|---------|
| `helper-env-var.sh.tmpl` | Template rendered by `render-apikey-helper.sh` for `auth.type: env_var`. Placeholder: `{{VAR}}`. |
| `helper-keychain.sh.tmpl` | Same, for `auth.type: keychain`. Placeholders: `{{SERVICE}}`, `{{ACCOUNT}}`. |
| `profile-anthropic-direct.json` | Seed profile for "direct" mode, created by `init.sh`. |
| `profile-gateway-example.json` | Commented example gateway profile, created by `init.sh`. |

---

## 10. Exit Codes

| Exit | Meaning |
|------|---------|
| `0` | Success |
| `1` | Generic runtime error |
| `2` | Invalid arguments / usage |
| `3` | Profile not found |
| `4` | Profile already exists (on create) |
| `5` | Profile locked / refusal due to lock or active-profile protection |
| `6` | Schema validation error |
| `7` | Missing dependency (`jq`, `security`, etc.) |
| `8` | Drift detected (managed keys tampered) |

---

## 11. Runtime Prerequisites

- **`jq`** — required hard dependency for all JSON I/O.
- **`bash` 4+ or POSIX sh** — standard on macOS, Linux, WSL.
- **`curl`** — optional; used only by `doctor.sh` for base URL reachability probes.
- **`security`** — optional; used only by `auth.type: keychain` profiles (macOS only).

---

## 12. Key Architectural Invariants

These invariants MUST hold across every code change:

1. **No secret material in plugin-managed files.** Profile JSONs, sidecar,
   helper shims — none of these contain API keys or tokens. Only references.
2. **All settings-file writes are atomic** (tmp + rename).
3. **Plugin never touches `settings.json`**, only `settings.local.json`.
4. **Drift is never silently overwritten** — always shown to user with
   interactive confirmation.
5. **Profiles are portable** — `~/...` in paths stays unexpanded until apply.
6. **Every command is user-invoked.** The plugin uses `commands/` not `skills/`
   specifically to prevent autonomous activation by Claude.
7. **Exit codes are standardized.** Every script uses the table in §10.
8. **`apiKeyHelper` output is never logged or echoed** — the plugin's role is
   to configure Claude Code's helper mechanism, not to read the helper's output.
