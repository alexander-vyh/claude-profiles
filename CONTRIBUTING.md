# Contributing to claude-profiles

Thanks for your interest in contributing. A few norms up front to make things
smooth.

## Before you start

1. **File an issue first** for anything beyond a typo or trivial fix.
   Discussion of design direction lands better in an issue than in a PR that
   has to be rewritten.
2. **Read the design doc.** `docs/design/phase3-decisions.md` is the
   authoritative spec. Amendments live in §13. If your change conflicts with
   the design, the design wins unless the PR explicitly proposes an amendment.

## Development workflow

### Prerequisites

- `bash` 4+ or POSIX shell
- `jq` (hard dependency)
- `bats-core` (included as a git submodule)
- `shellcheck` (`brew install shellcheck` on macOS)

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/alexander-vyh/claude-profiles
cd claude-profiles
```

### TDD is mandatory

All script work uses test-driven development with
[bats-core](https://github.com/bats-core/bats-core):

1. Write a failing test in `tests/<script>.bats`
2. Run the test, confirm it fails for the right reason:
   ```bash
   ./tests/bats-core/bin/bats tests/<script>.bats
   ```
3. Write the minimal implementation to pass
4. Run the full suite to confirm no regressions:
   ```bash
   ./tests/bats-core/bin/bats tests/
   ```

Tests isolate `$HOME` per test via `tests/test_helper/common.bash` so they
never touch the user's real `~/.claude/` directory.

### Quality gates (must pass before PR)

```bash
./tests/bats-core/bin/bats tests/    # expect 259+ pass, 0 fail
shellcheck -x scripts/*.sh           # expect clean
jq empty lib/profile-schema.json     # expect no output
```

CI runs these on every push and PR.

### Invariants to preserve

The design enforces 13 architectural invariants (see `§12` of the design
doc). The most load-bearing for contributions:

1. **No secret material** in plugin-managed files. Shims reference secrets;
   never embed them.
2. **Plugin writes only to `settings.local.json`**, never `settings.json`.
3. **All writes follow the Write Protocol** (`§12a`): same-dir mktemp →
   chmod before rename → atomic rename.
4. **Drift is never silently overwritten.** Use `AskUserQuestion` at the
   command layer, exit 8 at the script layer.
5. **Every command is user-invoked.** The plugin uses `commands/`, never
   `skills/`, to prevent autonomous activation.
6. **`apiKeyHelper` output is never logged or echoed.** `/doctor` checks the
   executable bit, never invokes the helper.

## Submitting a PR

1. Branch from `main`.
2. Commits should reference the issue they resolve, e.g. `ads.7: redact.sh
   coverage for apiKeyHelper`.
3. Keep PRs focused — one logical change per PR.
4. The PR description should explain the **why**, not restate the **what**
   (the diff explains the what).
5. Update `CHANGELOG.md` under `[Unreleased]`.
6. If your change modifies behavior spec'd in the design doc, either update
   the spec in the same PR or propose an amendment in `§13`.

## Reporting bugs

Use the "Bug report" issue template. Include:

- Exit code of whatever failed
- `bash scripts/doctor.sh --json` output (redacted if needed)
- What you expected vs. what happened
- Steps to reproduce

## Security

Do NOT open public issues for security bugs. See [SECURITY.md](./SECURITY.md)
for the private disclosure process.

## License

By contributing, you agree your contributions will be licensed under the
project's GPL-3.0-or-later license.
