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

## Acceptance gates

| Stage | Required evidence |
| --- | --- |
| Status | Thread event persisted before exit; malformed/truncated events bounded; missing report disclosed; stale running state distinguished; signal cleanup retains workspace lock |
| Offline verification | Changed/missing payload and wrong hook semantics fail; custom unrelated settings survive; no network, token reads, or account refresh |
| Resume | Exact recorded UUID/home/cwd; changed identity and concurrent writer rejected; explicit resume independent of Claude quota; partial effects reconciliation in prompt |
| Checkpoints | Nonempty structured versioned snapshot; atomic save and private permissions; interrupted write retains previous snapshot; no automatic workspace mutation |
| Pool preview | Authenticated relevant quotas; unknown/error/timeout explicit; duplicate identities handled; deterministic choice; active marker unchanged |
| Payload recovery | Fault at every write stage; conditional restoration; concurrent user edits preserved; symlink/mode handling; interrupted journal recoverable; package changes reported separately |

Live authentication and model execution are separate checks from protocol stubs.
A successful fixture or CLI help probe must never be reported as a successful
live continuation, account selection, or resume.

## Recovery implementation contract

The final stage uses one managed-payload transaction engine for checkout and
packaged installs. It stages desired bytes and captures original content, mode,
and symlink identity before transformations, then writes a durable journal before
each atomic replacement. Offline verification precedes transaction commit and
service activation. Failed installs recover in reverse order only where current
files still match transaction output; detected edits remain intact as conflicts.
Interrupted transactions require explicit recovery before another install starts.

Recovery targets the managed payload and shared configuration. It does not undo
package-manager upgrades or promise restoration of launch-service state. Installer
locks serialize cooperating installers; a non-cooperating editor can still write
between the final comparison and rename. This residual filesystem race must not
be described as an unconditional guarantee of preserving concurrent edits.

## Stage evidence

- Status: independent Sol audit PASS (confidence 0.94), 57 focused checks.
  Audit repairs cover inherited-pipe draining, malformed/deep JSON, reader errors,
  blocked stdin, status independent of eligibility, and concurrent manifest writes.
  Original hang reproducers now finish promptly. Live CLI events were subsequently
  exercised by the two-turn resume smoke test below.
- Offline verifier: independent Sol audit PASS (confidence 0.95) after repairs
  for disabled/async hooks and missing statusline false passes. Isolated installer
  output, tamper/missing/mode/hook/FIFO fixtures, updater failure propagation, and
  custom configuration cases pass. Package-manager upgrade control flow is mocked;
  this does not establish live upgrade recovery.
- Compatibility inventory: local CLI 0.166.0 and hub CLI 0.145.0 generated schemas
  expose both account/read and account/rateLimits/read. No authenticated request
  or model execution was made by that inventory.
- Resume audit found alternate-credential overrides, incomplete configuration
  fingerprints, and terminal records with surviving children. A blanket TOML
  refusal was rejected because it broke ordinary configured continuations.
  The revised design uses Codex's native resolved configuration and requirements,
  with a v2 policy fingerprint and the same original execution policy. Unsupported
  contexts retain initial continuation behavior but have no guarded-resume pins.
  Integrated Sol re-audit PASS (confidence 0.95), 29 resume checks and 57 runner
  regressions, plus bounded native protocol fixtures. Real credential-free probes
  on CLI 0.166 and hub 0.145 detect referenced role-file changes. User and project
  role files, Python 3.9 bundled parser, and unsupported-context fallback passed.
  Both installed CLI versions accept the resume command shape in help-only probes;
  A live two-turn no-tool smoke test then exposed volatile CODEX_TOOL_CALL_ID in
  the environment fingerprint. After a narrow fix and independent audit PASS
  (confidence 0.99; 30 resume checks), a fresh real run returned INITIAL_OK and its
  explicit resume returned RESUME_OK with the same thread and separate attempts.
  Event items were agent messages only; the empty workspace stayed unchanged.
  Exactly-once external effects remain outside this guarantee.
- Checkpoints: independent Sol audit PASS (confidence 0.96), storage/integration
  checks, 24 hook checks, and 16 concurrent saves yielding unique snapshots.
  Placeholder validation and corrupt-entry handling were repaired. The parent
  then saved and read back a real progress checkpoint with known session provenance.
  Semantic accuracy still depends on the author collecting workers and recording
  truthful evidence; the helper does not infer task completion from file writes.
- Pool preview: independent Sol audit PASS (confidence 0.96), 45 focused checks.
  Repairs cover non-finite values, conflicting/misidentified quota buckets,
  identity changes during inspection, oversized cursors, and inventory limits.
  A real authenticated local preview selected the active eligible account for
  gpt-6.1-sol, returned supported effort levels, and left its active marker intact.
  The authenticated hub preview left its marker intact and returned unknown when
  account/rateLimits/read rejected expired authentication (401). A fresh hub login
  is needed for successful quota inspection; no credentials were copied, the
  preview never writes tokens itself, and neither preview started a model turn.
  Preview eligibility is an observation, not a reservation of future capacity.

- Pool diagnostic follow-up: independent audit PASS (confidence 0.99), 51 checks.
  Authentication failures produce fixed operation names and sign-in guidance,
  without reflecting raw server errors or credential material.
- Managed-payload recovery: final independent Sol audit PASS (confidence 0.98).
  All 25 write-failure positions, failed verifier, lock contention, malformed
  journals, symlink retargeting, concurrent edits, SIGKILL recovery, ambiguous
  commit barriers, and service activation gating passed. Audit repairs close
  dangling ancestor escapes, incomplete initial-journal publication, retained-edit
  resolution, and directory durability barriers including failed-barrier retries.
  Actual power-loss testing was not performed; the external-editor race and
  package/service rollback exclusions above remain.
- Final integration: full Bash 3.2 regression suite and ShellCheck passed.
  Release packaging includes the recovery verifier and licensed Python 3.9 parser.
- Final wheel smoke caught a duplicate force-include that omitted the CLI verifier
  module. Packaging now shares the installed verifier with the recovery helper;
  a fresh sdist-to-wheel build passed isolated Python 3.9 install, strict verify,
  and recovery-list commands. CI additionally installs the wheel and imports the
  verifier to prevent recurrence.
- Post-install release QA exposed a fixture dependency on an absent policy helper.
  The runner fixture now explicitly stubs unavailable policy discovery, preventing
  an installed live helper from invoking its fake Codex as an app server. All 57
  runner checks pass with deadlines/assertions unchanged; native policy and resume
  remain covered by their dedicated suites.
