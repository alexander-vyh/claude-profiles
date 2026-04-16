---
description: List all LLM profiles and show which is active per scope
argument-hint: [--json] [--verbose]
---

List every profile under `~/.claude/llm-profiles/` and indicate which one is active at global scope and at the current-project scope. Drift (managed keys edited outside the plugin) is flagged with a `*` marker next to the affected profile.

Invoke the underlying script, forwarding any flags the user provided:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-profiles.sh $ARGUMENTS
```

### Flags

- `--json` — emit machine-readable JSON. Still redacted by default.
- `--verbose` — show full paths, env var names, service names, and base URLs **without redaction**. The script emits a stderr warning banner before the output; preserve that banner when relaying to the user.

### Redaction model (default behavior, per Amendment A7)

By default, `list-profiles.sh` pipes output through `redact.sh`, which masks:

- `auth.path` (helper_script) → `~/***`
- `auth.var` (env_var) → `***_VAR`
- `auth.service` / `auth.account` (keychain) → `***`
- `base_url` → hostname-only (`https://ai.simpli.fi/v1/...` becomes `https://ai.simpli.fi/...`). `localhost` and `127.0.0.1` are shown verbatim.
- `apiKeyHelper` path → `~/***`

`extras` keys and values are shown verbatim — they are user-defined config, not secrets. The schema denylist prevents dangerous keys from reaching display.

### Exit codes

- **0** — success. Relay the (possibly formatted) output to the user.

Do not attempt to re-run with `--verbose` on the user's behalf unless they explicitly ask — verbose output may contain secrets.
