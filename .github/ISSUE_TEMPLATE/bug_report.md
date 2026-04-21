---
name: Bug report
about: Something in claude-profiles doesn't work as expected
title: '[BUG] '
labels: bug
---

## Summary

<!-- One sentence. What went wrong? -->

## Reproduction

<!-- Exact commands, in order. Use a fenced code block. -->

```
/claude-profiles:...
```

## Expected vs. actual

**Expected:**

**Actual:**
  - Exit code:
  - Error message (if any):

## `/doctor` output

<!-- Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh --json` from the Claude
     Code prompt via the ! prefix, or invoke doctor.sh directly. Redact any
     paths or env var names you don't want public. -->

```
```

## Environment

- OS: <!-- macOS 14.x / Ubuntu 22.04 / WSL / etc. -->
- Shell: <!-- bash 5.x, zsh, etc. -->
- Claude Code version: <!-- output of `claude --version` -->
- claude-profiles commit: <!-- `git -C <plugin-dir> rev-parse --short HEAD` -->
- `jq --version`:

## Additional context

<!-- Screenshots, links to related issues, anything else that matters. -->
