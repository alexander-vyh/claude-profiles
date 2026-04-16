---
description: Edit a profile's JSON in $EDITOR with validation on save
argument-hint: <profile-name>
---

Open the profile named `$1` in the user's `$EDITOR` (falls back to `vi`). On save, validate the edited file. If valid, atomically replace the original. If invalid, show the specific errors and offer to re-edit **from the user's in-progress text** (not from the original), so no work is lost.

If `$1` is missing, emit a usage hint and stop.

### Workflow (per Amendment A5)

1. Resolve the profile path: `~/.claude/llm-profiles/<name>.json`. If it doesn't exist, report exit 3 with a list of available profiles.

2. **Warn if the profile is active.** Run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-active.sh --scope=effective --json` to check. If the current profile matches, tell the user: "Profile '<name>' is currently active. Edits will take effect after the next `/claude-profiles:switch <name>` (the sidecar tracks the previous values until then)." This is informational, not blocking.

3. **Copy to a temp file in the same directory** (same-directory guarantees same-filesystem, required for atomic rename per invariant #10 / §12a):

   ```bash
   TMPFILE=$(mktemp "$(dirname "$PROFILE")/.$(basename "$PROFILE").XXXXXX")
   cp "$PROFILE" "$TMPFILE"
   chmod 0600 "$TMPFILE"
   ```

4. **Open the temp file in the editor:**

   ```bash
   "${EDITOR:-vi}" "$TMPFILE"
   ```

   Wait for the editor to exit.

5. **Validate the edited temp file:**

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-profile.sh "$TMPFILE"
   ```

   - **Exit 0** — valid. Restore mode to 0644 on the temp file, then atomically rename over the original: `mv -f "$TMPFILE" "$PROFILE"`. Confirm success.
   - **Exit 6** — invalid. Show the validation errors from stderr. Use `AskUserQuestion`:
     - **Prompt:** "Profile failed validation: [list of rules]. Re-edit (your changes are preserved in the temp file) or discard?"
     - **Options:** [Re-edit / Discard]
     - On `Re-edit`: go back to step 4 (re-open the same temp file).
     - On `Discard`: `rm -f "$TMPFILE"`; original unchanged; end.

6. On any unexpected error, delete the temp file (`rm -f "$TMPFILE"`) and report.

### Exit codes

- **0** — saved and validated successfully.
- **3** — profile not found.
- **6** — validation failed and user chose to discard. (Or re-edit loop was exhausted.)

### Invariant reminders

- Atomic rename (invariant #10): never truncate-in-place on the original. Always write temp, chmod, rename.
- No secret material in the edited file (invariant #1): if the user pastes an API key into the JSON, the schema (`auth` is a reference-only branch) will fail validation at step 5.
