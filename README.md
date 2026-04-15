# claude-profiles

> Switch Claude Code between Anthropic direct and custom LLM gateway profiles via slash commands.

`claude-profiles` is a [Claude Code](https://code.claude.com) plugin that lets you maintain multiple LLM endpoint configurations — Anthropic direct, your company's LLM gateway, a self-hosted LiteLLM proxy, a local relay, etc. — and switch between them with a single command. Profiles are stored in `~/.claude/llm-profiles/` and support both global and per-project scope.

**Design principle:** the plugin never holds secret material. All API keys stay wherever you already keep them (shell env vars, macOS Keychain, 1Password CLI, vault, gcloud-minted tokens, etc.). The plugin manages only *references* and delegates to Claude Code's built-in `apiKeyHelper` mechanism.

## Status

**v0.1.0 — early development.** The design is frozen but the commands and scripts are not yet implemented. See [Implementation Plan](#implementation-plan) below.

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
| `--force` | Permits overwriting a locked project's profile |
| *(none)* | Defaults to `--global` |

## Install

*(installation instructions will be added once the plugin is published to a marketplace — for now, clone locally and reference with `--plugin-dir`)*

## Implementation Plan

This plugin is being built top-down through the `/plugin-dev:create-plugin` workflow. Phases:

- [x] Phase 1 — Discovery
- [x] Phase 2 — Component planning (8 commands, 0 agents, 0 hooks, 0 MCP)
- [x] Phase 3 — Detailed design (profile schema, settings mutation model, scope rules, drift detection)
- [ ] Phase 4 — Structure creation *(in progress)*
- [ ] Phase 5 — Command + script implementation
- [ ] Phase 6 — Validation
- [ ] Phase 7 — End-to-end testing
- [ ] Phase 8 — Documentation + marketplace entry

## License

GPL-3.0-or-later. See [LICENSE](./LICENSE).
