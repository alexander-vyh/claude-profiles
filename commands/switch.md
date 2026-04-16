---
description: Switch the active LLM profile for global or current-project scope
argument-hint: <profile-name> [--global|--project] [--force]
---

Switch the active LLM profile. `$1` is the profile name (required). Optional flags:

- `--global` (default if neither scope flag is present) — write to `~/.claude/settings.local.json`.
- `--project` — write to `<repo>/.claude/settings.local.json`. Errors if `cwd` is not inside a git repo (exit 2).
- `--force` — override a project-scope lock. `--force` implies `--project`; combining `--force` with an explicit `--global` is a usage error (exit 2).

If `$1` is missing, emit a usage message and do NOT invoke the script.

### Primary invocation

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/apply-profile.sh $ARGUMENTS
```

(The script parses the name and flags itself.)

### Exit codes and user-facing handling

- **0** — success. Profile is active. Continue to the post-apply check below.
- **2** — usage error (missing name, `--force` with `--global`, `--project` outside git repo, etc.). Show stderr to the user.
- **3** — profile not found. Script lists available profiles on stderr; relay them.
- **5** — scope is locked. Project scope has a different active profile and user did not pass `--force`. Tell the user: "project scope is locked to '<other>'. Re-run with `--force` to override, or use `--global` to change global scope only."
- **6** — profile failed schema validation. Show the specific rule(s) that failed.
- **8** — drift detected during merge (plugin-managed keys were hand-edited since last switch). Enter the **Drift Confirm Flow** below.
- **9** — success, but the running Claude Code session's env is stale. Enter the **Restart Ack Flow** below.

### Drift Confirm Flow (exit 8)

When exit is 8, the script has already printed the drift diff to stderr (key-by-key `expected → actual`). Relay that diff to the user, then invoke `AskUserQuestion` with these three options:

1. **Overwrite** — re-invoke with `--accept-drift=overwrite`. Applies the new profile's values, forgets the drift.
2. **Incorporate** — re-invoke with `--accept-drift=incorporate`. Keeps drifted values for any keys not managed by the new profile; otherwise applies new profile's values. Note: drifted `apiKeyHelper` is never silently incorporated — the script will ask a follow-up `AskUserQuestion` if that specific key drifted.
3. **Cancel** — do nothing further; profile unchanged. End the command.

The re-invocation passes the drift hash the script emitted, to guard against stale-diff authorization:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/apply-profile.sh <name> [--scope=...] --accept-drift=<overwrite|incorporate> --drift-hash=<sha256>
```

After re-invocation, handle the new exit code (typically 0 or 9) exactly as above. Do NOT loop on drift more than once per command — if exit is still 8 after a re-invocation, the file changed again; tell the user and stop.

### Restart Ack Flow (exit 9)

Profile was written successfully but the running session's env variables are stale until Claude Code restarts. Per invariant #11, inform the user via structured UI (not free-text). Invoke `AskUserQuestion`:

- **Prompt:** "Profile switched to '<name>'. Claude Code must restart for this to take effect."
- **Options:** [Acknowledge]

Then end the command. Do NOT attempt to restart Claude Code.
