# Continuation reliability and recovery

Implementation proceeds in dependency order. Each stage requires deterministic
checks followed by an independent correctness/security audit before advancing.
Tests use disposable homes and stub processes unless explicitly recorded as live.

1. Durable continuation status/events and strict offline installation verification.
   Never equate successful process exit with verified task completion.
2. Explicit resume of a recorded thread, pinned to its original home and workspace.
   Reconcile partial external effects; no automatic latest-thread selection.
3. Atomic agent-written progress checkpoints at safe boundaries and quota pressure.
   Preserve the last snapshot; do not promise lossless recovery at a hard cap.
4. Preview-only account pool selection with bounded authenticated quota discovery.
   Unknown availability remains unknown; never mutate the active account marker.
5. Journaled recovery for managed payload changes, preserving concurrent edits.
   Package-manager rollback and service state require separate treatment.

## Ownership and QA

Terra workers own bounded implementation paths. Luna inventories extension points.
Sol independently audits each stage after objective checks; disputed high-risk
findings escalate to a judge. The parent owns integration, documentation, release
checks, and synthesis. Shared files have only one writer at a time.

Stage evidence, audit findings, and remaining live validation will be recorded
here as work completes. No stage is considered verified merely because it builds.
