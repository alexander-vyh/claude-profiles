---
description: Run diagnostics across all profiles and optionally repair drift
argument-hint: [--fix]
---

Run per-profile diagnostics across every profile in `~/.claude/llm-profiles/`. Reports schema conformance, helper-shim presence and executability (without running the helper — per invariant #8), sidecar vs settings-file integrity, and optional `curl` reachability probes for each profile's `base_url`.

With `--fix`, interactively repair drift and rebuild a missing/corrupt sidecar.

> **Note:** `doctor.sh` is scheduled for ads.10 and may not yet be present in this build. If invocation fails with "script not found," tell the user this diagnostic is coming in a later release and suggest `/claude-profiles:current` + `/claude-profiles:list` as the interim manual check.

### Invocation

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh $ARGUMENTS
```

Forward `--fix` if the user provided it.

### What the script checks (per Amendment A5)

- **Schema** — every `*.json` profile passes `validate-profile.sh`.
- **helper_script profiles** — `auth.path` expanded path exists, has executable bit, not world-writable. Never invoked.
- **env_var / keychain profiles** — generated shim at `~/.claude/llm-profiles/.helpers/<name>.sh` exists, has mode 0700, matches the expected template structure (no post-hoc tampering).
- **Sidecar integrity** — `.state.json` is parseable; `managed_env_keys` in sidecar match the `.env` entries in each scope's settings file; `managed_api_key_helper_value` matches what's in the settings file.
- **base_url reachability** — if `curl` is installed, run `curl --max-time 5 --head <base_url>` for each profile with a base_url. If `curl` is not installed, output: "base_url reachability: SKIPPED (curl not installed)". Never silently pass.
- **Orphaned files** — stale tmpfiles (`.<basename>.*`) in the profile dir, stale lock directories (`.state.lock/`).

### `--fix` behavior (interactive)

For each repairable issue found, the script emits a JSON record to stdout, and the command invokes `AskUserQuestion` per issue:

1. **Drift on a scope.** Present diff and options: [Overwrite with profile's values / Incorporate into sidecar / Leave alone]. Multi-scope drift is processed one scope at a time (sequential `AskUserQuestion` calls).

2. **Missing / corrupt sidecar (A2.2).** Present: "Sidecar is missing or unparseable. Rebuild from the `CLAUDE_PROFILES_ACTIVE` env marker + profile definitions? [Rebuild / Skip]." On `Rebuild`, the script reconstructs the sidecar entry.

3. **Broken helper shim** (missing, wrong mode, or content mismatch). Present: [Regenerate from template / Leave alone].

4. **Orphaned temp/lock files.** Present: [Remove / Leave alone].

Forward the user's choice back into the script via the appropriate `--fix-<action>` flag. If the script streams multiple findings, iterate — one `AskUserQuestion` per finding.

### Exit codes

- **0** — all checks passed (or all issues fixed in `--fix` mode).
- **1** — one or more diagnostics failed and were not fixed (either `--fix` wasn't passed, or the user declined fixes). Summarize the outstanding issues.
- **7** — missing hard dependency (`jq`). Relay the install hint.
- **8** — drift detected (informational; with `--fix`, user resolves interactively above).

Never invoke apiKeyHelper scripts or read their output (invariant #8). Diagnostics on `helper_script` profiles check file metadata only.
