---
name: feature-build
description: Take a feature from request to done with design, technical design, build, test, and review, ending with the user told it is ready. Use for new features, not bugs.
roles:
  designer: designer
  frontend: frontend
  backend: backend
  reviewer: reviewer
  test: test
coordinator: project-manager
stall_after: 1h
inputs: What the feature should do and for whom, as a description or a link to an asset (issue, doc, mockup, screenshot), plus any constraints.
steps:
  - id: intake
    title: Capture the request
    owner: coordinator
  - id: design
    title: Clarify and propose 3 designs
    owner: designer
  - id: design-approval
    title: User approves a design
    owner: coordinator
    approval: user
    on_reject: design
  - id: tech-design
    title: Technical design docs
    owner: [frontend, backend]
  - id: tech-review
    title: Review technical designs
    owner: [frontend, backend, reviewer]
    on_reject: tech-design
  - id: build
    title: Implement, and write the test plan
    owner: [frontend, backend, test]
  - id: verify
    title: Test and code review
    owner: [test, reviewer]
    on_reject: build
  - id: design-check
    title: Designer approves the result
    owner: designer
    on_reject: build
  - id: notify
    title: Tell the user it's done
    owner: coordinator
---

# Feature build

The project manager coordinates and drives the run to completion. Rules for every step:

- The channel task holds the feature: title "Feature: <name>", and a description with the request, the
  approved design, and current status. Keep it current.
- Give each step to its owners with `canopy_delegate_task`, one delegation per owner. A delegation must
  stand alone: the request, what earlier steps decided (documents by `doc_…` id, files by `path:line`),
  what this owner does, and what done looks like. Don't also @mention the delegate.
- Designs, technical docs, test plans and screenshots are shared as Canopy documents (write under
  `.canopy/out/`, then `canopy_document_share` or attach to the post). Put their ids in each step result.
- Advance with `canopy_playbook_advance` only when the step's "Done when" holds; put the evidence in
  `result`.
- Test and e2e runs take the `tests` lock (`canopy_lock_acquire`).
- Nobody commits or pushes unless the user says so.

## intake

Read the request. If it is a link, open it (or ask `researcher` to summarise it) and restate the feature in
your own words. Check the code area it touches to judge whether it needs frontend, backend, or both. Write
the channel task. If the request is too vague to design from, leave the questions to the designer.

Done when: the task states the feature, who it is for, the source (description or link), and the layers
likely involved.

## design

Delegate to the designer: read the request, ask the user clarifying questions (one batch, then wait for
answers), then produce 3 distinct designs. Each design gets a short rationale and a mockup or sketch shared
as a document, plus a recommendation of one.

Done when: the user's questions are answered and 3 designs are shared, with document ids in the result.

## design-approval

Post the 3 designs (document ids, the designer's recommendation) to the user and ask which to build, with
any changes. Then call `canopy_playbook_advance`: Canopy holds the step for the user's approval. On
approval, record the chosen design in the task. On "changes requested", advance with `next: "design"`
and carry the user's note into the delegation.

Done when: the user approved one design (with any changes noted).

## tech-design

Delegate to frontend and backend in parallel: each writes a technical design doc for its layer from the
approved design: files and modules touched, data and API changes, the contract between frontend and
backend, risks, and how it will be tested. Tell each what the other is covering so the contract matches.
Skip a layer the feature doesn't touch.

Done when: each involved layer has shared its doc, and both docs name the same frontend/backend contract.

## tech-review

Delegate to frontend, backend and reviewer: each reviews all the technical design docs (not only their
own) and replies approve or changes requested, with reasons. If anyone requests changes, advance with
`next: "tech-design"` and carry the findings. After round 2, ask the user rather than looping.

Done when: frontend, backend and reviewer have each approved every doc.

## build

Delegate in parallel: frontend and backend implement to the approved docs and run their unit tests; test
writes a detailed test plan (cases, edge cases, e2e flows, and the screens to screenshot) from the
approved design and docs, and shares it. On a return from verify or design-check, the delegations carry
the bugs and change requests to fix.

Done when: frontend and backend report files changed and passing unit tests, and the test plan is shared.

## verify

Delegate in parallel: test runs the test plan (unit, integration, and e2e for UI) and collects screenshots
of every screen in the plan, shared as documents; reviewer reviews `git diff` against the approved docs
for correctness, edge cases, and regressions. If test finds bugs or the reviewer requests changes,
advance with `next: "build"` with the failures and findings in the result. After round 3, ask the user
rather than looping.

Done when: the test plan passes with screenshots shared, and the reviewer approves or lists only nits.

## design-check

Delegate to the designer: compare the screenshots from verify with the approved design and approve, or
list the differences to fix. On changes, advance with `next: "build"` and carry the list; the fix goes
back through verify.

Done when: the designer approves the screenshots against the approved design.

## notify

As channel owner, post one summary for the user: the feature, the approved design, files changed, tests
and test plan results, screenshots (document ids), review and design outcomes, and anything left open.
@mention nobody else. Set the channel task to completed.

Done when: the summary is posted and the task is completed.
