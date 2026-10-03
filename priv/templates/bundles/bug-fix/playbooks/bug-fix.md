---
name: bug-fix
description: Reproduce, fix, verify, and review a reported bug with the bug-fix team, ending in user sign-off. Use for a defect with a clear symptom, not for features.
team: bugfix-team
roles:
  test: test
  backend: backend
  frontend: frontend
  reviewer: reviewer
coordinator: project-manager
channel: new
stall_after: 30m
inputs: The symptom, where it happens, steps to reproduce if known, expected vs actual, links or screenshots.
steps:
  - id: triage
    title: Triage and scope
    owner: coordinator
  - id: reproduce
    title: Reproduce with a failing test
    owner: test
  - id: fix
    title: Fix
    owner: [backend, frontend]
  - id: verify
    title: Verify
    owner: test
  - id: review
    title: Review
    owner: reviewer
    on_reject: fix
  - id: sign-off
    title: User sign-off
    owner: coordinator
    approval: user
---

# Bug fix

Ground rules for the whole run:

- The channel task holds the bug: title "Bug: <symptom>", description with repro steps and current
  status. Keep it current.
- Give each step to its owner with `canopy_delegate_task`. A delegation must stand alone: the bug, what
  earlier steps found (`path:line`, failing test name, command), and what done looks like. Don't also
  @mention the delegate.
- Advance with `canopy_playbook_advance` only when the step's "Done when" holds, and put the evidence in
  `result`. Later steps and the user read it there.
- Test runs take the `tests` lock (`canopy_lock_acquire`).
- Nobody commits or pushes unless the user says so.

## triage

Read the brief. Check `git log` and the code area it names, or ask @researcher, to judge which layers are
involved: backend, frontend, or both. Write the channel task. If the report is too vague to reproduce, ask
the user one clear question and stop. Don't advance until they answer.

Done when: the task says what's broken, where, and how to see it, and names the layers involved.

## reproduce

Delegate to the test role: write the smallest automated test that fails because of this bug. Report the
test's path and name, the exact command, and the failing assertion. If the bug won't reproduce after a
reasonable try, report what was tried. You then ask the user rather than guessing.

Done when: a named test fails for the reported reason.

## fix

Delegate to backend for server-side causes and to frontend for UI causes. Only delegate to both when both
layers are wrong, and tell each what the other is changing. Skip a role that isn't involved. Each
delegate fixes the root cause rather than the symptom and runs the reproduce test.

Done when: every delegate has reported the files changed, why, and that the reproduce test now passes.

## verify

Delegate to the test role: run the reproduce test plus the suites covering the touched files (and the e2e
spec for any UI change). If anything fails, advance with `next: "fix"` and put the failure output in the
result.

Done when: everything named passes. The result lists the commands and their outcomes.

## review

Delegate to the reviewer role: review `git diff` against the bug, the root cause, and the test, looking
at correctness, edge cases and regressions. If the reviewer asks for changes, advance with
`next: "fix"` and carry the findings into the fix delegation. After round 2 of review, stop and ask the
user instead of looping.

Done when: the reviewer approves, or lists only optional nits.

## sign-off

Post one summary for the user: the bug, root cause, the fix (files), tests added and run, review
outcome, anything left. Then call `canopy_playbook_advance`: Canopy holds the step for the user's
approval and wakes you with their answer. On approval, set the channel task to completed. On "changes
requested", advance with `next:` the step that fits their note.
