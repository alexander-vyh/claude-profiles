# Security Policy

## Supported Versions

claude-profiles follows [Semantic Versioning](https://semver.org/). Security
fixes are back-ported to the most recent minor release on the current major.

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅ |

## Reporting a Vulnerability

**Do NOT open a public GitHub issue for security bugs.**

Email <alexander@vyhmeister.us> with:

- A clear description of the vulnerability
- Steps to reproduce
- Affected version(s)
- Any suggested mitigation

You should get an initial response within 5 business days. Disclosure
timeline is coordinated — typical target is 30 days from report to fix +
public advisory, longer if the fix requires a design amendment.

## Threat Model

The plugin's architectural invariants define its security posture:

1. **No secret material in plugin-managed files.** Profile JSONs, sidecar
   state, and helper shims hold *references* to secrets (env var names,
   keychain services, helper paths) — never the secrets themselves.
2. **Plugin never reads `apiKeyHelper` output.** `/doctor` checks the
   executable bit only; actual helper execution is Claude Code's
   responsibility.
3. **Single-user workstation.** Other local users are not in the threat
   model. Profile files at 0644 are acceptable in the default deployment.
   Shared hosts should change profile mode to 0600 (documented in the
   design doc).

## Known Hardening

- **Extras denylist** (`lib/profile-schema.json`, Amendment A1.2) blocks
  ~40 dangerous env vars (`PATH`, `NODE_OPTIONS`, `LD_PRELOAD`, `XDG_*`,
  `JAVA_TOOL_OPTIONS`, etc.) from landing in `settings.local.json`.
- **Keychain field regex** (Amendment A1.1) rejects shell metacharacters
  in `auth.service` and `auth.account` at validate time; renderer
  single-quotes values at apply time.
- **Drift detection** refuses to silently overwrite hand-edited managed
  keys. `apiKeyHelper` drift specifically cannot be incorporated without
  per-helper confirmation (Amendment A4).
- **Atomic writes** (Write Protocol §12a) prevent partial-write windows
  in which corrupted settings could leak references.
- **Advisory lock** on concurrent `apply-profile.sh` invocations prevents
  race-condition corruption of sidecar/target state.

## What Is Not a Vulnerability

- A profile with `auth.type: none` NOT setting `apiKeyHelper` — by design.
- `/doctor` reporting `[WARN] env marker unset` in a fresh shell — by design;
  the env marker is only set after a full Claude Code restart.
- `gateway-example` seed profile failing `/doctor` helper check — it's a
  placeholder template meant to be customized.
