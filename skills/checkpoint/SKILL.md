---
name: checkpoint
description: "Save a durable, explicit progress snapshot at a safe boundary; list or show existing snapshots."
argument-hint: "[save | list | show <id>]"
allowed-tools: Read, Bash(overclaude-checkpoint *)
---

# /checkpoint

A checkpoint records the current work so another session can continue it. It does not hand off or start another session. Save one after an audited work stage or when a quota nudge asks you to wrap up. Finish the current step, collect all agent results and wait for concurrent writers to stop before claiming a consistent snapshot. If work remains in flight, identify it explicitly; do not represent it as completed.

For `list`, run `overclaude-checkpoint list`. For `show <id>`, run `overclaude-checkpoint show <id>`. Both are scoped to the current working directory; an ID cannot select another directory's snapshot. No automatic expiration applies.

For `save` (the default), supply `--session` with the actual session ID from the current session's hook/runtime context. Never invent an ID. If it is unavailable, pass `--session unknown`; the snapshot records `session_known: false`. Send one UTF-8 JSON object on stdin with exactly these string keys: `Goal`, `Current state`, `Decisions`, `Validation`, `Next steps`, `Work in flight`, and `Artifacts`. Goal, current state, and next steps must describe real work; use the explicit string `None` for an empty optional section. The input and final checkpoint each have a 32 KiB limit.

Write the sections yourself from the task context. Record artifact paths and whether they exist or are pending; do not collect file contents, raw transcripts, credentials, tokens, or secrets. Avoid sensitive text in the snapshot. The command does not inspect artifacts or harvest session data. It publishes a new private immutable version; it does not edit a prior checkpoint, commit, switch accounts, or change repository files. Confirm the returned ID to the user when appropriate.

Use a quoted heredoc to pass the JSON without shell expansion; replace the example values with the actual work and the session ID when known:

```bash
overclaude-checkpoint save --session unknown <<'JSON'
{"Goal":"Complete the requested work","Current state":"Describe the current state","Decisions":"None","Validation":"Describe checks and results","Next steps":"Describe the next action","Work in flight":"None","Artifacts":"List paths and whether they exist"}
JSON
```
