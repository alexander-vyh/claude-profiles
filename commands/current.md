---
description: Show the effective LLM profile for the current working directory
argument-hint: [--json] [--verbose]
---

Compute and display the **effective** profile for the current working directory. The effective profile is determined by:

1. Checking the project-scope sidecar entry for `cwd` (wins if present).
2. Falling back to the global-scope sidecar entry.
3. Cross-checking against the `CLAUDE_PROFILES_ACTIVE` env marker in the current shell.

If the env marker disagrees with the sidecar, this is **drift** and is reported to the user.

Invoke the underlying script:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-active.sh --scope=effective $ARGUMENTS
```

### Flags

- `--json` — emit machine-readable JSON (still redacted by default).
- `--verbose` — unredacted output; stderr warning banner is printed.

### Redaction

Same rules as `/claude-profiles:list` — secret-ish fields (`auth.path`, `auth.var`, `auth.service`, `auth.account`, `apiKeyHelper` path) are masked, `base_url` is hostname-only, `extras` shown verbatim.

### Exit codes

- **0** — success. Relay output.
- **8** — drift detected between env marker and sidecar. Still print the output (including the drift diagnostic on stderr), then suggest the user run `/claude-profiles:doctor --fix` to reconcile. Do NOT auto-invoke `doctor --fix` from here; this is a read-only command.

If exit is 8, your message to the user should explicitly say "drift detected" and cite the specific key(s) that disagree, then suggest `/claude-profiles:doctor --fix`.
