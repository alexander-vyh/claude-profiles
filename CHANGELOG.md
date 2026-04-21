# Changelog

All notable changes to claude-profiles are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned (v0.2.0)
- `/add`: accept flags to skip the wizard when all fields are provided
- `/remove --force`: bypass interactive confirmation for automation paths
- `/edit`: flag-driven field mutations (`--set-description`, `--set-base-url`,
  `--add-extra`, etc.) alongside an opt-in `--interactive` mode

## [0.1.0] - 2026-04-20

Initial public release.

### Added

- **8 slash commands** for managing Claude Code LLM endpoint profiles:
  - `/claude-profiles:init` — seed `~/.claude/llm-profiles/` + 2 example profiles
  - `/claude-profiles:list` — table view, paths redacted by default
  - `/claude-profiles:current` — effective profile for cwd, cross-checked against env marker
  - `/claude-profiles:switch <name>` — apply + drift-confirm + restart-ack flow
  - `/claude-profiles:add` — interactive wizard to create a new profile
  - `/claude-profiles:remove <name>` — refuses when profile is active
  - `/claude-profiles:edit <name>` — validate + atomic write
  - `/claude-profiles:doctor [--fix]` — schema, shim, sidecar, drift, reachability checks
- **4 auth types:** `none`, `helper_script`, `env_var`, `keychain` (macOS-only)
- **Profile schema** (JSON Schema Draft 7) with strict validation at create + apply time
- **Extras denylist** covering ~40 dangerous env vars
  (`PATH`, `NODE_OPTIONS`, `LD_PRELOAD`, `XDG_*`, `JAVA_TOOL_OPTIONS`, etc.)
- **Atomic writes** for all plugin-managed files via a unified Write Protocol
  (same-dir mktemp → chmod → atomic rename)
- **Advisory lock** on `apply-profile.sh` (mkdir polyfill with stale-PID detection)
- **Crash-safe sidecar-first ordering** — sidecar written before target
- **Drift detection** with three resolution paths: `overwrite`, `incorporate`,
  and explicit refusal for `apiKeyHelper` drift
- **Post-apply stale-env check** surfacing the restart-required state as a
  structured prompt rather than a scrollable print

### Design documentation

- `docs/design/phase3-decisions.md` (833 lines) — authoritative spec with
  §13 review-discovery amendments

### Invariants

No secret material in plugin-managed files. Plugin writes only to
`settings.local.json`, never `settings.json`. `apiKeyHelper` output is never
logged or read. Drift is never silently overwritten. Profiles are portable
(tildes expand only at apply time).

### Tests

259 bats-core tests (1 environment-dependent skip). Shellcheck clean on all
10 scripts.

[Unreleased]: https://github.com/alexander-vyh/claude-profiles/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/alexander-vyh/claude-profiles/releases/tag/v0.1.0
