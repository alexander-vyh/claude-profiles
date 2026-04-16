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
9. **All plugin-managed files re-verified at read time.** No plugin-managed
   file on disk (profile, sidecar, settings, shim) is trusted to be unchanged
   since last write. Apply-time re-validation is required; create/edit-time
   validation alone is never sufficient.
10. **All plugin-managed file writes follow the Write Protocol (§12a).**
    Settings files, sidecar, helper shims, and profile files all use the same
    atomic write procedure. No exceptions.
11. **After any `/switch` that changes the active profile, the user MUST be
    informed via structured UI** (`AskUserQuestion`, not free-text print) that
    the running session's env is stale until process restart.
12. **Plugin never resurrects user-deleted profile files.** `/init` does not
    re-create seed profiles if the user has deleted them. `/doctor --fix` or a
    dedicated reseed command is the repair path.
13. **Threat model:** single-user workstation. Other local users are not
    treated as adversaries. Profile files at 0644 are acceptable. If the
    deployment target is a shared host, profile mode should be changed to
    0600 and documented accordingly.

---

## 12a. Plugin-Managed Write Protocol

All plugin-managed file writes (settings, sidecar, profiles, helper shims)
MUST follow this procedure:

1. Set `umask 077` at script start (ensures no world-readable temp files).
2. Create temp file in the **same directory** as the target:
   `mktemp "$(dirname "$target")/.<basename>.XXXXXX"`.
   Same-directory guarantees same-filesystem, which guarantees `rename(2)` is
   atomic. Never use `$TMPDIR` for files destined outside `/tmp`.
3. Write content to temp file.
4. Set permissions on the temp file BEFORE rename:
   - Settings files: `chmod 0600`
   - Sidecar: `chmod 0600`
   - Profile files: `chmod 0644` (or `0600` on shared hosts — see §12 invariant 13)
   - Helper shims: `chmod 0700`
5. Atomic rename: `mv -f "$tmpfile" "$target"`.
6. (Optional, recommended) `sync` the parent directory for durability on
   power-loss (not required for correctness, only for crash-recovery).

**Advisory lock:** `apply-profile.sh` holds `flock` on
`~/.claude/llm-profiles/.state.lock` for the duration of its
read-modify-write sequence (§5 steps 1–12). Other scripts that write the
sidecar or settings file MUST acquire the same lock. `flock(1)` is available
on macOS (via Homebrew coreutils or a polyfill using `mkdir`) and Linux
natively.

**Locking on macOS:** macOS does not ship `flock(1)` natively. The
implementation MUST use a `mkdir`-based polyfill:
- Acquire: `mkdir "$lockdir" 2>/dev/null` in a retry loop with backoff.
- Release: `rmdir "$lockdir"`.
- Stale lock detection: store PID in `$lockdir/pid`. On acquisition
  failure, read the PID and check `kill -0 $pid`. If the process is
  dead, remove the stale lock and retry.
- `trap ... EXIT` ensures cleanup on normal exit, SIGTERM, SIGHUP, and
  SIGINT. SIGKILL cannot be trapped — stale lock detection covers this.

**Cleanup:** orphaned temp files (`.<basename>.*`) and stale lock
directories (`.state.lock/`) are cleaned up by `/doctor` and `/init`.

---

## 13. Review-Discovery Amendments (v0.1.0-rc2)

Amendments from the mol-feature review-discovery gate (2026-04-16).
Reviewed by: adversarial-reviewer, qa-security, qa-devex, qa-ops.
Each amendment references the section it modifies. The original text in
§§1–12 is the Phase 3 baseline; these amendments supersede where they
conflict.

### Amendment A1: Schema Security Constraints (modifies §2)

**A1.1 — Keychain field patterns (closes: command injection BLOCK)**

In the `auth` oneOf table (§2), the `keychain` branch is amended:

| Field | Constraint |
|-------|-----------|
| `service` | `"type": "string", "pattern": "^[A-Za-z0-9_.-]{1,255}$"` |
| `account` | `"type": "string", "pattern": "^[A-Za-z0-9_.-]{1,255}$"` |

Shell metacharacters (`"`, `'`, `` ` ``, `$`, `;`, `|`, `&`, `(`, `)`,
`<`, `>`, ` `, newline) are rejected by the pattern.

Additionally, `render-apikey-helper.sh` MUST shell-escape field values
using `printf '%s'` piped through a safe-quoting function, not
raw template substitution. The rendered shim MUST be validated: re-read
after write, parse to confirm no unexpected shell constructs.

Add validation rule:

> 7\. For `auth.type: keychain`, `service` and `account` MUST match
>    `^[A-Za-z0-9_.-]{1,255}$`. Reject shell metacharacters.

**A1.2 — Extras denylist (closes: env-var injection BLOCK)**

Add validation rule:

> 8\. `extras` keys MUST NOT appear in the EXTRAS_DENYLIST. The denylist is
>    a hard-coded constant shared between `validate-profile.sh` and
>    `apply-profile.sh` (defense-in-depth).
>
>    EXTRAS_DENYLIST:
>    - Process-control: `PATH`, `HOME`, `USER`, `SHELL`, `TERM`, `TMPDIR`,
>      `EDITOR`, `VISUAL`
>    - Dynamic linker: `LD_LIBRARY_PATH`, `LD_PRELOAD`, any key matching
>      `^LD_`, `^DYLD_`
>    - XDG dirs: `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME`,
>      `XDG_STATE_HOME`, `XDG_RUNTIME_DIR`
>    - Node.js: `NODE_OPTIONS`, `NODE_PATH`, `NODE_EXTRA_CA_CERTS`
>    - Python: `PYTHONPATH`, `PYTHONSTARTUP`, `PYTHONDONTWRITEBYTECODE`
>    - Ruby: `RUBYLIB`, `RUBYOPT`
>    - Perl: `PERL5LIB`, `PERL5OPT`
>    - JVM: `JAVA_TOOL_OPTIONS`, `_JAVA_OPTIONS`, `MAVEN_OPTS`,
>      `GRADLE_OPTS`
>    - Git: `GIT_SSH_COMMAND`, `GIT_EXEC_PATH`
>    - TLS: `SSL_CERT_FILE`, `SSL_CERT_DIR`
>    - Build tools: `CARGO_HOME`, `GOPATH`, `GOBIN`,
>      `CMAKE_PREFIX_PATH`, `PKG_CONFIG_PATH`, `COMPOSER_HOME`
>    - Plugin-managed: `ANTHROPIC_BASE_URL`, `CLAUDE_PROFILES_ACTIVE`,
>      `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`
>
>    Enforced at validate-time (rule 8) AND at apply-time (§5 step 5,
>    defense-in-depth). If collision detected at apply-time despite passing
>    validate, exit 6.

**A1.3 — Template rendering safety (modifies §9)**

`render-apikey-helper.sh` MUST NOT perform raw string substitution of
profile fields into shell templates. Instead:

- For `env_var` shims: the `{{VAR}}` placeholder is validated against
  `^[A-Z_][A-Z0-9_]*$` (already enforced by schema) and inserted as a
  literal string in `printf '%s' "${<VAR>:-}"`.
- For `keychain` shims: `{{SERVICE}}` and `{{ACCOUNT}}` are validated
  against A1.1 pattern and single-quoted in the rendered command. The
  rendered shim MUST NOT use double quotes around these values.
- After writing, the shim is re-read and parsed to confirm it matches the
  expected template structure. Any unexpected content → delete shim, exit 1.

**A1.4 — Helper shim empty-output hardening (modifies §3 Cases B, C)**

`env_var` shim template is amended:

```sh
#!/bin/sh
# Generated by claude-profiles — do not hand-edit
_val="${ANTHROPIC_API_KEY_COMPANY_GATEWAY:-}"
if [ -z "$_val" ]; then
  echo "claude-profiles: env var ANTHROPIC_API_KEY_COMPANY_GATEWAY is not set" >&2
  exit 1
fi
printf '%s' "$_val"
```

`keychain` shim template is amended similarly: check exit code of
`security find-generic-password`, emit diagnostic to stderr, exit 1 on
failure. This prevents Claude Code from receiving an empty key and
silently falling back to default auth (compliance bypass).

### Amendment A2: Sidecar Hardening (modifies §4)

**A2.1 — Additional sidecar fields**

Each scope entry in `.state.json` gains:

```json
{
  "active_profile": "cake-gateway",
  "managed_env_keys": ["..."],
  "managed_env_values": {
    "ANTHROPIC_BASE_URL": "https://ai.simpli.fi",
    "CLAUDE_PROFILES_ACTIVE": "cake-gateway"
  },
  "managed_api_key_helper": true,
  "managed_api_key_helper_value": "/Users/alice/llm_gateway/token-helper.sh",
  "target_file": "/Users/alice/.claude/settings.local.json"
}
```

`managed_env_values` stores the actual values the plugin wrote last time
(enables precise drift detection — compare file-on-disk against these).
`managed_api_key_helper_value` tracks the helper path for drift detection
across auth-type transitions (closes: silent apiKeyHelper overwrite BLOCK).

**A2.2 — Sidecar loss recovery**

If `.state.json` is missing or jq-unparseable when `apply-profile.sh` runs:

- REFUSE the switch. Exit 1 with message: "Sidecar state file is missing
  or corrupt. Run `/claude-profiles:doctor --fix` to rebuild."
- NEVER treat missing sidecar as empty `[]` — that silently strands
  previously-managed keys in the settings file.
- `/doctor --fix` rebuilds from the `CLAUDE_PROFILES_ACTIVE` env marker:
  read the marker → find the matching profile → compute what keys that
  profile would have managed → reconstruct sidecar entry.

**A2.3 — Sidecar is per-machine**

Sidecar `target_file` paths are absolute. The sidecar is NOT portable
between machines. Users who sync `~/.claude/llm-profiles/` between machines
MUST exclude `.state.json` (or accept that `/doctor` will rebuild on first
run). Add `.state.json` to the "not synced" documentation.

Sidecar mode is changed from 0644 to **0600** (contains apiKeyHelper
absolute paths — reconnaissance surface on shared hosts).

### Amendment A3: Merge Algorithm Rewrite (replaces §5)

The corrected merge algorithm for `apply-profile.sh`:

0. **Preflight:** Source `lib.sh` (which runs `require_cmd jq` — see A6.1).
   Run `validate-profile.sh` on target profile; exit 6 if invalid.
   This catches schema violations, extras-denylist collisions, and
   platform-incompatible auth types BEFORE any mutation.
1. **Acquire advisory lock** on `~/.claude/llm-profiles/.state.lock`.
2. **Read target settings file** from disk (or `{}` if absent). Store as
   `file_on_disk`. Do NOT mutate yet.
3. **Read sidecar** → `prev_managed_keys`, `prev_managed_values`,
   `prev_api_key_helper_value` for this scope. If sidecar is missing or
   corrupt → exit 1 with recovery instructions (A2.2).
4. **Drift detection** (BEFORE any mutation): for each key in
   `prev_managed_keys`, compare `file_on_disk.env[key]` against
   `prev_managed_values[key]`. Also compare `file_on_disk.apiKeyHelper`
   against `prev_api_key_helper_value` if `managed_api_key_helper` was
   true. Any mismatch → enter drift-confirm flow (§6 as amended by A4).
   If user cancels → exit 8, release lock, target file unchanged.
5. **Compute new managed set:** read new profile → derive
   `new_managed_keys` from auth type + `ttl_ms` + `extras`. Verify extras
   keys are disjoint from plugin-managed keys (defense-in-depth for
   post-validation sideloading). If collision → exit 6.
   **Merge order contract:** extras written first, plugin-managed keys
   written last. Plugin keys override extras on conflict.
6. **Remove old managed keys:** starting from `file_on_disk`, remove each
   of `prev_managed_keys` from `.env`. If `prev_managed_api_key_helper`
   was true, remove `.apiKeyHelper`.
7. **Handle drift-incorporated unmanaged keys:** if drift resolution was
   "incorporate" and any drifted keys are NOT in `new_managed_keys`,
   re-insert them as unmanaged (user-owned) values. They remain in `.env`
   but are excluded from sidecar tracking going forward.
8. **Write new keys:** insert `new_managed_keys` into `.env` (extras
   first, then plugin-managed keys). Write new `.apiKeyHelper` if
   applicable.
9. **Atomic sidecar update** per §12a Write Protocol: record
    `new_managed_keys`, `new_managed_values` (actual values written),
    `active_profile`, `managed_api_key_helper`,
    `managed_api_key_helper_value`. Sidecar is written FIRST (before
    target) for crash-safe ordering: if a crash occurs between sidecar
    write and target write, the sidecar is "ahead" and self-corrects on
    next successful switch. The reverse order would orphan managed keys.
10. **Atomic target write** per §12a Write Protocol: same-dir mktemp →
    write → chmod 0600 → rename. Target file is guaranteed unchanged
    until this step succeeds.
11. **Post-apply stale-env check:** invoke
    `get-active.sh --scope=effective`. If env marker disagrees with
    sidecar → exit 9 ("success, restart required"). The command layer
    surfaces an `AskUserQuestion`: "Profile switched to '<name>'. Claude
    Code must restart for this to take effect. [Acknowledge]".
12. **Release advisory lock.**

Key ordering invariant: drift detection (step 4) runs BEFORE any mutation
(steps 6–8). The file on disk is guaranteed unchanged until step 9.

### Amendment A4: Drift Handling Precision (replaces §6)

When `apply-profile.sh` detects drift (§5 step 4), the drift-confirm
flow proceeds:

1. **Compute diff:** for each drifted key, show
   `key: expected (sidecar) → actual (file)`. Include `apiKeyHelper` if
   drifted. Compute `drift_hash = sha256(file_on_disk)` for staleness
   protection.
2. **Print diff** to stderr for user visibility.
3. **Invoke `AskUserQuestion`** via the command layer with four options:
   - **Overwrite all** — forget all drift, apply new profile's values.
   - **Cancel switch** — exit 8, target unchanged.
   - **Review per-key** — iterate: for each drifted key, `AskUserQuestion`
     with [Use new profile's value / Keep current value / Cancel switch].
     On cancel at any point → exit 8, target unchanged.
   - **Incorporate drift** — see step 4.
4. **"Incorporate" semantics (precisely defined):**
   - Drifted keys that ARE in `new_managed_keys` → use new profile's
     value. Sidecar records the new value as the baseline.
   - Drifted keys that are NOT in `new_managed_keys` → re-insert into
     `.env` as unmanaged (user-owned). Remove from sidecar tracking.
     These survive the switch.
   - **Drifted `apiKeyHelper` → NEVER incorporated without
     re-validation.** Separate `AskUserQuestion`: "apiKeyHelper was
     changed to `<path>`. [Accept (will validate) / Reject, use new
     profile's helper]." If accepted: validate file exists, is
     executable, is owned by `$USER`, is not world-writable. Validation
     failure → reject, use new profile's helper.
5. **Re-invocation contract:** `apply-profile.sh` accepts
   `--accept-drift={overwrite|incorporate}` and `--drift-hash=<sha256>`.
   If hash doesn't match current file → restart drift detection (protects
   against stale-diff authorization).

Exit codes:
- **8** — drift detected and unconfirmed (user cancelled, or hash mismatch)
- **0** — drift detected and resolved

`/doctor --fix` provides a standalone repair flow using the same
mechanism. When multiple scopes have drift, `/doctor --fix` processes them
sequentially, one `AskUserQuestion` per scope.

### Amendment A5: Command Spec Corrections (modifies §7)

**init** — behavior rewritten:

> Preflight: `require_cmd jq` (exit 7 with install hint:
> "brew install jq" on macOS, "apt install jq" on Debian/Ubuntu).
> Creates `~/.claude/llm-profiles/` (0755), `.helpers/` (0700),
> `.state.json` (empty). Seeds `anthropic-direct.json` +
> `gateway-example.json` ONLY if no `*.json` files exist in the profile
> dir. Never overwrites existing files. Exit 0 on re-run (true
> idempotent).
>
> Exit codes: 0, 1, 7

**list** — amended:

> All auth-branch fields routed through `redact.sh` by default.
> `--verbose` disables redaction with stderr warning: "This output
> contains paths and env var names. Only use --verbose in private."
> `--json` obeys the same redaction rules. `list-profiles.sh` dependency
> chain updated to include `redact.sh`.
>
> `base_url` redacted to hostname-only by default (e.g.,
> `https://ai.simpli.fi/v1/...` → `https://ai.simpli.fi/...`). Exception:
> `localhost` / `127.0.0.1` shown verbatim.

**current** — amended:

> Same redaction rules as `/list`. `--verbose` requires same stderr
> warning banner. `/current --json` redacts by default.

**switch** — amended:

> `--force` implies `--project` scope. `--force` combined with explicit
> `--global` is a usage error (exit 2). Post-apply: invokes
> `get-active.sh --scope=effective` to check for stale env. If stale
> (expected in running session), surfaces `AskUserQuestion`:
> "Profile switched to '<name>'. Claude Code must restart for this to
> take effect. [Acknowledge]". Exit 9 when session restart is required.
>
> Exit codes: 0, 2, 3, 5, 6, 8, 9

**edit** — amended:

> Copies profile to a temp file (`mktemp` in same dir, mode 0600). Opens
> `${EDITOR:-vi}` on the temp file. On save: validates via
> `validate-profile.sh`. If valid: atomic rename to replace original. If
> invalid: shows errors, offers re-edit from the temp file (preserving
> user's work). On discard: temp file deleted, original unchanged. Warns
> if profile is active.
>
> Exit codes: 0, 3, 6

**doctor** — amended:

> `curl` probe: if `curl` not installed, output line "base_url
> reachability: SKIPPED (curl not installed)". Never silently pass.
> `--fix` processes drifted scopes sequentially, one `AskUserQuestion`
> per scope. `--fix` also rebuilds sidecar if missing/corrupt (A2.2).
> Helper checks: verify executable bit only, NEVER invoke helper
> (invariant #8). Report: "helper check: exists + executable" or
> "helper check: FAIL (not found / not executable)".
>
> Exit codes: 0, 1, 7, 8

### Amendment A6: Exit Codes + Error Messages (modifies §10)

**A6.1 — New exit code**

| Exit | Meaning |
|------|---------|
| `9` | Success, but running session env is stale — restart required |

**A6.2 — Exit code precedence rule**

When multiple exit conditions apply simultaneously:
- Argument validity (exit 2) → checked first
- Dependency availability (exit 7) → checked second
- Profile existence (exit 3) → checked before authorization
- Authorization/lock (exit 5) → checked after existence
- Schema validation (exit 6) → checked after authorization
- Drift (exit 8) → checked during merge

**A6.3 — Error message requirements**

Every non-zero exit MUST emit a human-readable message to stderr
containing:

| Exit | Required message content |
|------|------------------------|
| 2 | The invalid argument + correct usage hint |
| 3 | The profile name that wasn't found + list of available profiles |
| 4 | The profile name that already exists |
| 5 | Which scope is locked + which profile holds the lock |
| 6 | The specific validation rule(s) that failed + the offending value |
| 7 | The missing command + install hint per OS (macOS/Debian/Arch) |
| 8 | The drifted key(s) + expected vs actual values |
| 9 | The new profile name + "restart Claude Code to activate" |

`lib.sh` provides `die_usage()`, `die_not_found()`, etc. — one formatter
per exit code. All errors are routed through these functions.

**A6.4 — jq preflight in lib.sh**

`lib.sh` MUST include at source time:

```sh
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'claude-profiles: required command "%s" not found.\n' "$1" >&2
    case "$1" in
      jq) printf '  Install: brew install jq (macOS) | apt install jq (Debian)\n' >&2 ;;
    esac
    exit 7
  }
}
require_cmd jq
```

Every script sources `lib.sh` as its first line, guaranteeing jq is
checked before any JSON operation.

### Amendment A7: Redaction Scope (modifies §8)

`redact.sh` scope is precisely defined:

| Field | Default (redacted) | `--verbose` (unredacted) |
|-------|--------------------|--------------------------|
| `auth.path` (helper_script) | `~/***` | Full expanded path |
| `auth.var` (env_var) | `***_VAR` | Full var name |
| `auth.service` (keychain) | `***` | Full service name |
| `auth.account` (keychain) | `***` | Full account name |
| `base_url` | Hostname only (e.g., `ai.simpli.fi`) | Full URL |
| `base_url` localhost/127.0.0.1 | Verbatim (no redaction) | Verbatim |
| `apiKeyHelper` path | `~/***` | Full path |
| `extras` values | Verbatim | Verbatim |
| `extras` keys | Verbatim | Verbatim |

`extras` keys and values are NOT redacted — they are user-defined
configuration, not auth secrets. The denylist (A1.2) prevents dangerous
keys; the remaining keys are safe to display.

`redact.sh` is a dependency of: `list-profiles.sh`, `get-active.sh`,
`doctor.sh`. All display-path scripts route through it.

---

### Open items from review (CONCERNs — user decision pending)

The following findings were classified CONCERN (not BLOCK) and require
user input during implementation:

1. **`/current` exit 8 on drift** — adversarial C2 argues a READ command
   should always exit 0, reporting drift as data (via `--json`), not as
   a failure code. Alternative: keep exit 8 for script composability
   awareness. **Decision needed.**

2. **`/add` extras loop and `/doctor --fix` multi-scope** both depend on
   whether the Claude Code harness supports multiple `AskUserQuestion`
   calls per command invocation. **Needs harness investigation.**

3. **Sidecar portability** — adversarial C3 notes sidecar paths are
   absolute and break when synced across machines. Amendment A2.3
   documents this as "per-machine, don't sync." Alternative: store
   relative paths. **Decision needed during implementation.**

4. **`ttl_ms` + extras collision** — adversarial C5 notes that
   `extras.CLAUDE_CODE_API_KEY_HELPER_TTL_MS` collides with the `ttl_ms`
   field. The denylist (A1.2) now covers this key. Validate-profile.sh
   should also reject the combination as a hard error. **Implementation
   detail.**

5. **Per-key drift review** — Amendment A4 step 3 adds a "Review per-key"
   option. This is a UX enhancement; if implementation complexity is too
   high for v0.1.0, it can be deferred to v0.2.0 without downgrading
   security. **User decision on scope.**
