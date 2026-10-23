# Review policy

This policy applies to agent-assisted implementation and review in this repository.
Explicit user instructions take precedence. It governs review effort; existing
authorization, required checks, security, release, and deployment gates still apply.

## Bounded review

- Allow **at most three review passes per logical change**, including a clean
  confirming pass. Stop immediately when clean; three is a ceiling, not a target.
- Pass 1 reviews the complete diff, intent, affected callers/contracts, tests, and
  repository requirements against recorded base and head SHAs.
- Passes 2 and 3 review the changes since the preceding pass, their affected
  behavior, and every unresolved finding. Expand inspection when a changed
  contract or base requires it, without reopening an unrelated whole-repo audit.
- Batch verified fixes and relevant local verification before the next push.
  Avoid separate commits/pushes for each finding. Coordinate branch ownership
  with other agents; preserve active CI runs unless the user authorizes interruption.
- Carry one finding ledger and round count across commits, rebases, handoffs,
  reviewer changes, and resumed chats. A new commit or reviewer does not reset
  the count. Record base changes and any expanded review scope.
- If pass 3 is not clean, stop automatic fix/re-review cycling with
  **needs-rethink**. Leave the change unmerged, retain active findings and evidence,
  and propose a smaller scope or different approach. Further automatic rounds
  require explicit user direction. Never lower severity or discard findings to
  fit the limit.

## Findings and verification

Report all evidence-backed P0/P1/P2 defects introduced or exposed by the change;
there is no finding-count cap. Give each root cause a stable ID, severity, trigger,
impact, file/line, and verification evidence. Track it as active, fixed+verified,
invalidated with a reason, or explicitly user-deferred. Deduplicate by root cause,
reopen regressions, and do not repeat already resolved findings without new evidence.
P3/style preferences do not block or trigger automatic edits.

Unrelated pre-existing defects belong in a separate follow-up, with their provenance
made clear; do not silently expand this PR. Do not file or message externally
without authorization. Check the complete class of an introduced bug within the
affected code, rather than repairing only the reported instance.

Use the existing shared check runner and affected behavioral tests. A build does
not prove runtime behavior; a signature does not prove environment equivalence.
Reuse local results only through the repository's existing verifier. Missing or
mismatched evidence must execute normal CI. After relevant checks pass, repeat
them only for changed inputs, failures, or an unresolved concern. Required checks
must cover the current merge candidate; earlier-head green results do not apply.

## Risk and handoff

Choose low, medium, or high risk from behavior and blast radius, not authorship:
docs/copy with no behavioral effect are usually low; ordinary product changes
medium; trust, authorization, billing, CI execution/receipt verification, signing,
migrations, and difficult recovery paths high. Give high-risk changes focused
review and explicit recovery evidence. Honor existing human approval requirements;
an agent review never substitutes for a required human. Do not invent extra
approval gates when the user has already authorized the action.

Before handoff or merge, record in the PR description (or a local review artifact
before a PR exists):

- Base/head SHAs, risk and reason, pass count out of 3, and latest review scope.
- Active/fixed/invalidated/deferred finding IDs and reasons; say "0 active
  findings" when clean.
- Commands and results, reused versus executed checks, unverified behavior, and
  recovery steps or why recovery is not applicable.
- State: clean, needs-rethink, or blocked with the concrete reason and owner.

Keep this record with the change so another session resumes the same review.
This is an agent workflow policy, not a new automated GitHub approval or check.

## Bicino review focus

| Changed area | Failure to look for | Evidence to retain |
| --- | --- | --- |
| BLE and ownership | Firmware/iOS/Watch framing or authorization diverges | Protocol and affected host/Swift contracts |
| Workouts and navigation | Reconnect/lifecycle loses or duplicates persisted ride state | Behavioral helpers and relevant simulator tests |
| Firmware and hardware | Wrong board/profile, image reserve, power/display regression | Existing build/provenance and separate per-board hardware gates |
| Maps and releases | Format incompatibility, cross-installation access, untested artifact promoted | Reader/auth contracts and exact artifact identity |
| CI and local reuse | Wrong source/toolchain trusted; failed/skipped work reported green | Routing, verifier, and fallback failure tests |

Use [AGENTS.md](AGENTS.md) and [development checks](docs/development-checks.md)
for commands. Preserve physical acceptance and release-signing gates. App Store
and flashed-device recovery cannot be inferred from a server rollback; describe
the relevant recovery path explicitly.

