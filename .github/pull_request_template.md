<!-- Thanks for contributing. A few things to check off before review. -->

## Summary

<!-- What does this PR do? One or two sentences. -->

## Why

<!-- Link to the issue this addresses. If there's no issue, explain the
     motivation. "Because it felt right" is not motivation. -->

Fixes #

## Changes

<!-- Bulleted list of user-visible changes, not a restatement of the diff. -->

-

## Invariants preserved

<!-- Does this PR touch any of the 13 architectural invariants (§12)?
     Confirm each relevant one explicitly. Delete the ones that don't apply. -->

- [ ] No secret material introduced into plugin-managed files
- [ ] Writes go only to `settings.local.json`, never `settings.json`
- [ ] All writes use the Write Protocol (§12a): same-dir mktemp → chmod → rename
- [ ] Drift detection still fires on hand-edited managed keys
- [ ] `apiKeyHelper` output still never read by the plugin
- [ ] Exit codes still match the §10 table

## Quality gates

- [ ] `./tests/bats-core/bin/bats tests/` passes (N tests, 0 fail)
- [ ] `shellcheck -x scripts/*.sh` is clean
- [ ] `jq empty lib/profile-schema.json` succeeds (if schema changed)
- [ ] CHANGELOG.md updated under `[Unreleased]`

## Test plan

<!-- How did you verify this? New tests added? Manual smoke test? -->

-
