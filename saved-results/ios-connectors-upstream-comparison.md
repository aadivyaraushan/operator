# New connector commits compared with local repairs

Date: September 11, 2026. Purpose: determine whether the collaborator already completed portions of the remaining work.

Fetched origin/codex/ios-connectors without merging or touching local source changes. Local HEAD d1c3cc5; remote HEAD c573334. Four new commits, all by SuryaSGit; 18 changed files, 474 insertions and 56 deletions. All changed paths in this new range are under ios/.

| Commit | Work | Relation to our work |
| --- | --- | --- |
| 31f31a0 | Fixes async XCTest assertions and stale scope/command expectations | Substantial overlap with our already-passing local test repairs |
| 7269f13 | Adds GatewayDeadline and time limits to Contacts, Reminders, Photos, Music and Weather | New work worth integrating after verifying timeout behavior |
| 37d1e67 | Adds account-read deadlines, 15-second HTTP request timeout, and tests | New work worth integrating and testing |
| c573334 | Repairs pairing fixtures using the current command lists | Overlaps our pairing fixture repair; uses a different fixture approach |

Eight test files overlap local edits. Do not pull blindly over them. Preserve our production four-command allow-list fix, stored OAuth scope validation, browser cancellation fix and Notion test synchronization; the new remote source diff does not replace those changes.

Important limitation: GatewayDeadline.swift uses withTaskGroup then cancelAll, while claiming callers stop waiting even if child work ignores cancellation. Apple's documentation states the group always waits for its children to complete. This is a source/documentation-backed mismatch, not yet a measured runtime failure on these new commits. A never-completing permission callback can therefore defeat the intended timeout. The new implementation needs a focused regression test before we rely on its guarantee.

Source: https://developer.apple.com/documentation/swift/withtaskgroup(of:returning:isolation:body:)

The new commits do not establish live account sign-ins, successful service reads, WeatherKit entitlement, or completion of our merge. New code/tests were inspected, not executed. No merge, commit, push, permission grant, or Simulator changes occurred in this comparison.

Reproduce: git fetch origin codex/ios-connectors; git log --oneline d1c3cc5..origin/codex/ios-connectors; git diff --stat d1c3cc5..origin/codex/ios-connectors; git diff d1c3cc5..origin/codex/ios-connectors -- ios/OperatorApp/Sources ios/OperatorCore/Sources. Compare git diff --name-only with the remote changed-path list to locate overlapping local edits.
