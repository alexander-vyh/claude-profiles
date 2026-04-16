---
description: Bootstrap ~/.claude/llm-profiles/ with directory structure and seed profiles
---

Bootstrap the `claude-profiles` plugin on this machine. Creates `~/.claude/llm-profiles/` (mode 0755), the `.helpers/` subdirectory (mode 0700), and an empty `.state.json` sidecar. Seeds two example profiles (`anthropic-direct.json` and `gateway-example.json`) **only if the profile directory contains no `*.json` files yet** — existing user profiles are never touched.

This command is fully idempotent: running it again on an already-initialized machine is a silent no-op (exit 0). Per plugin invariant #12, `/init` does NOT resurrect profiles the user deleted.

Invoke the underlying script:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/init.sh
```

### Exit code handling

- **0** — success (first-run init, or silent no-op on re-run). Briefly report what was created (or confirm "already initialized") and point the user at `/claude-profiles:list` and `/claude-profiles:add` as next steps.
- **1** — generic runtime error (e.g., permission denied creating `~/.claude/llm-profiles/`). Surface the stderr message from the script so the user can fix it.
- **7** — missing hard dependency (`jq`). The script emits an install hint per OS (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu). Relay that hint verbatim.

Do not re-run on failure unless the user confirms they have fixed the underlying cause.
