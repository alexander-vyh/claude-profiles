# claude-profiles

> Switch Claude Code between Anthropic direct and custom LLM gateway profiles via slash commands.

`claude-profiles` is a [Claude Code](https://code.claude.com) plugin that lets you maintain multiple LLM endpoint configurations — Anthropic direct, your company's LLM gateway, a self-hosted LiteLLM proxy, a local relay, etc. — and switch between them with a single command. Profiles are stored in `~/.claude/llm-profiles/` and support both global and per-project scope.

**Design principle:** the plugin never holds secret material. All API keys stay wherever you already keep them (shell env vars, macOS Keychain, 1Password CLI, vault, gcloud-minted tokens, etc.). The plugin manages only *references* and delegates to Claude Code's built-in `apiKeyHelper` mechanism.

## Status

**v0.1.0 — released.** All eight commands are implemented, tested (259 bats tests green), and shellcheck-clean. See [Install](#install) to try it.

## Prerequisites

- [Claude Code](https://code.claude.com/docs/en/install) (any recent version)
- `bash` 4+ or a POSIX-compatible shell
- [`jq`](https://jqlang.github.io/jq/) — required for JSON reads/writes
- *(optional)* `curl` — only used by `/doctor` for base-URL reachability checks
- *(optional, macOS only)* `security` — only used by `auth.type: keychain` profiles

## Commands

| Command | What it does |
|---------|--------------|
| `/claude-profiles:init` | First-time setup — creates `~/.claude/llm-profiles/` and seeds example profiles |
| `/claude-profiles:list` | Show all profiles and which is active per scope |
| `/claude-profiles:current` | Show the effective profile for the current working directory (redacted) |
| `/claude-profiles:switch <name> [--global\|--project] [--force]` | Change the active profile for a scope |
| `/claude-profiles:add` | Interactive wizard to create a new profile |
| `/claude-profiles:remove <name>` | Delete a profile (refuses if it's currently active) |
| `/claude-profiles:edit <name>` | Open a profile JSON in `$EDITOR` and validate on save |
| `/claude-profiles:doctor [--fix]` | Diagnose broken helpers, unset env vars, drift, invalid JSON |

Every command must be invoked explicitly by the user. The plugin never auto-activates on context — auth rotation is an explicit action, not an inferred one.

### Usage examples

First-time setup — from any Claude Code session:

```
/claude-profiles:init
```

This creates `~/.claude/llm-profiles/` with two seed profiles (`anthropic-direct.json` and `gateway-example.json`), a `.helpers/` directory for generated shims, and an empty `.state.json` sidecar.

See what you have and which profile is active:

```
/claude-profiles:list
/claude-profiles:current
```

Switch to a different profile (global scope by default):

```
/claude-profiles:switch anthropic-direct
```

Switch just the current project, leaving your global profile untouched:

```
/claude-profiles:switch cake-gateway --project
```

Create a new profile interactively:

```
/claude-profiles:add
```

Edit an existing profile in your `$EDITOR` (validates on save):

```
/claude-profiles:edit cake-gateway
```

Remove a profile (must not be active):

```
/claude-profiles:remove old-gateway
```

Run diagnostics; use `--fix` to repair drift or rebuild a corrupt sidecar:

```
/claude-profiles:doctor
/claude-profiles:doctor --fix
```

## Profile schema

```json
{
  "name": "cake-gateway",
  "description": "Company LLM gateway via gcloud-minted tokens",
  "base_url": "https://gateway.example.com",
  "auth": {
    "type": "helper_script",
    "path": "~/path/to/token-helper.sh"
  },
  "ttl_ms": 300000,
  "extras": {
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
    "MAX_THINKING_TOKENS": "16000",
    "LLM_GATEWAY": "1"
  }
}
```

The authoritative schema lives at [`lib/profile-schema.json`](./lib/profile-schema.json). See [`docs/design/phase3-decisions.md`](./docs/design/phase3-decisions.md) §2 for field-by-field rules and security constraints.

### Auth types

| `auth.type` | Required fields | Use for |
|-------------|-----------------|---------|
| `none` | — | Anthropic direct (default OAuth or `ANTHROPIC_API_KEY`) |
| `helper_script` | `path` | Dynamic/rotating tokens — gcloud, vault, 1Password CLI, any script that prints a key to stdout |
| `env_var` | `var` | Static keys kept in a shell env var (direnv, `.zshrc`, 1Password shell plugin) |
| `keychain` *(macOS only)* | `service`, *(optional)* `account` | Long-lived keys stored in macOS Keychain via `security find-generic-password` |

## How activation works

Claude Code reads environment variables at process startup. A command like `/claude-profiles:switch` cannot rotate auth for the *currently running* session — it prepares the next session. After switching, exit Claude Code and relaunch.

**One nuance:** `apiKeyHelper` is re-invoked on HTTP 401 and after `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` expires. So within a single session, an expired dynamic token will auto-refresh without a restart — but a *base URL* change requires a restart.

## Scopes and locking

Profile settings write to `settings.local.json` (both global and project variants) — never to `settings.json`. This keeps machine-specific auth out of any dotfiles repo you might have.

| Scope | Target file |
|-------|-------------|
| Global | `~/.claude/settings.local.json` |
| Project | `<repo>/.claude/settings.local.json` |

Project scope **overrides** global scope because Claude Code's own settings precedence puts project-local files first. If a project has its own active profile, it's implicitly "locked" — `/switch` inside that project refuses to change scope without an explicit flag.

| Flag | Behavior |
|------|----------|
| `--global` | Always edits the global settings file regardless of cwd |
| `--project` | Always edits the current repo's project settings file (errors if not in a repo) |
| `--force` | Permits overwriting a locked project's profile (implies `--project`) |
| *(none)* | Defaults to `--global` |

## Security model

The plugin is built so that its own files never contain secret material. Key guarantees:

- **No secrets in plugin-managed files.** Profile JSONs, the sidecar state file, and generated helper shims hold only references (paths, env var names, keychain service names) — never API keys or tokens.
- **Extras denylist.** `validate-profile.sh` and `apply-profile.sh` both reject extras keys that could alter process semantics — `PATH`, `LD_*`, `DYLD_*`, `NODE_OPTIONS`, `PYTHONPATH`, `SSL_CERT_*`, plugin-managed keys, and many more. Enforced at validate-time and apply-time (defense in depth).
- **Drift detection.** Every `switch` compares the settings file against the sidecar's record of what the plugin last wrote. If a plugin-managed key was hand-edited, the switch stops and asks before overwriting.
- **Atomic writes.** Settings, sidecar, profile, and shim writes all follow a same-directory-mktemp-then-rename protocol with an advisory lock, so concurrent switches can't corrupt state.
- **No autonomous activation.** All behavior is user-invoked via slash commands. The plugin ships no agents, hooks, or skills.

See [`docs/design/phase3-decisions.md`](./docs/design/phase3-decisions.md) §12 (architectural invariants), §12a (write protocol), and §13 (review amendments A1–A7) for the full threat model, schema constraints, and merge algorithm.

## Install

### Local install (recommended while evaluating)

Clone this repo and point Claude Code at the local directory:

```bash
git clone https://github.com/alexander-vyh/claude-profiles.git ~/src/claude-profiles
claude --plugin-dir ~/src/claude-profiles
```

Inside the session, run `/claude-profiles:init` to seed the profile directory, then `/claude-profiles:list` to confirm the commands are loaded.

To make the plugin available for every session without the flag, add `~/src/claude-profiles` to your Claude Code plugin path (see [Claude Code plugin docs](https://code.claude.com/docs/en/plugins)).

### Marketplace install

*(Marketplace publication is pending. This section will be updated once `claude-profiles` is listed in an official or curated marketplace.)*

## Troubleshooting

**"I switched profiles but my session still uses the old one."**
Claude Code reads auth env vars at process startup. Exit Claude Code and relaunch after running `/claude-profiles:switch`. Exit code 9 from `switch` is the plugin telling you the running session is now stale — the new profile is on disk, but the current process needs a restart.

**`/claude-profiles:doctor` reports drift.**
Something (another tool, a manual edit) changed a plugin-managed key in your `settings.local.json` since the last switch. Run `/claude-profiles:doctor --fix` to walk through each drifted scope and choose per scope whether to overwrite with the active profile's values, incorporate the current file as the new baseline, or leave it alone.

**"Missing `jq`" / exit code 7.**
`jq` is a hard dependency. Install it before running any command:

```bash
# macOS
brew install jq

# Debian / Ubuntu
sudo apt install jq

# Arch
sudo pacman -S jq
```

**Keychain auth on Linux / Windows.**
`auth.type: keychain` is macOS-only in v0.1.0 (it shells out to the `security` binary). On Linux or Windows, use `auth.type: helper_script` wrapping a platform-appropriate tool — `secret-tool`, `pass`, `wincred`, etc. A tiny script that prints the key to stdout is all you need; `apiKeyHelper` does the rest.

**"Sidecar state file is missing or corrupt."**
`apply-profile.sh` refuses to switch when `~/.claude/llm-profiles/.state.json` is missing or unparseable (a deliberate choice — silently treating it as empty would strand previously-managed keys in your settings file). Run `/claude-profiles:doctor --fix` to rebuild the sidecar from the `CLAUDE_PROFILES_ACTIVE` env marker and your profile definitions.

**Helper script not executable.**
For `auth.type: helper_script` profiles, the referenced file must exist and be executable at switch time. Check with `ls -l <path>`; `chmod +x <path>` if needed. `/claude-profiles:doctor` reports this without running the helper (per invariant #8).

## License

GPL-3.0-or-later. See [LICENSE](./LICENSE).
