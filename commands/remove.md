---
description: Delete a profile's JSON file and its generated helper shim
argument-hint: <profile-name>
---

Delete the profile named `$1`. This removes `~/.claude/llm-profiles/<name>.json` and, if the profile had `auth.type: env_var` or `keychain`, the plugin-generated helper shim at `~/.claude/llm-profiles/.helpers/<name>.sh`.

If `$1` is missing, emit a usage hint and stop.

### Safety checks (before invoking the script)

1. Confirm the profile exists. If `~/.claude/llm-profiles/<name>.json` doesn't exist, the script will exit 3 — but it's fine to let the script be the source of truth here.

2. **Refuse if the profile is active anywhere.** The script (`remove-profile.sh`) checks this via `get-active.sh` at both global and project scopes. If active, the script exits 5 with the scope(s) that hold the lock. Relay that message and tell the user to `/claude-profiles:switch` away to a different profile first.

3. **Destructive-action confirmation.** Before invoking the script, use `AskUserQuestion`:
   - **Prompt:** "Delete profile '<name>'? This removes `~/.claude/llm-profiles/<name>.json` and its helper shim (if any). This cannot be undone."
   - **Options:** [Delete / Cancel]
   - On `Cancel`, end the command without invoking the script.

### Script invocation

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/remove-profile.sh $1
```

### Exit codes

- **0** — deleted. Confirm to the user and list what was removed (profile JSON path, shim path if applicable).
- **2** — usage error (missing or malformed name). Show usage hint.
- **3** — profile not found. Relay the list of available profiles from stderr.
- **5** — profile is active at one or more scopes; deletion refused. Show the scope(s) and advise the user to `/claude-profiles:switch` away first.

Never pass a `--force` override; the refusal at exit 5 is a safety feature, not a nuisance.
