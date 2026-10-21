---
name: agent-docs
description: "Given a ClickUp task, writes or updates (1) local domain notes (business logic and edge cases) in ~/.claude/projects/{{PROJECT_KEY}}/memory/domain/<repo>/ (agent-sync) and (2) the plain-English ClickUp documentation page for the feature: reads the task spec, the matching plan file, and the actual PR code, then produces a short QA/PM-facing explainer. Run at the end of every task (after the final review passes and gh pr ready), or when the user gives a ClickUp task link and asks for a doc, an explainer, or an update to existing documentation. Trigger terms: agent-docs, document this task, write docs for task, update documentation for feature, doc for QA, doc for PM, how it works page from a task, domain notes, edge cases."
---

# agent-docs — task → domain notes + ClickUp doc

Two outputs for one ClickUp task:

1. **Domain notes** — `~/.claude/projects/{{PROJECT_KEY}}/memory/domain/<repo>/<topic>.md`
   for each repo the task touched (`<repo>` = local checkout directory name):
   business rules and edge cases an agent would get wrong without being told.
   Local, synced between machines by agent-sync; Claude, Cursor and mimo read
   them via the pointer in `MEMORY.md` or a plan. Nothing goes into the repo.
2. **ClickUp page** — the QA/PM-facing "how it works" page. Output goes through
   the {{PROJECT_NAME}}-clickup-docs skill — load that skill for the language/tone/format rules.

## When

- **End of every task**: after the final review round passes and the PR is
  marked ready (`gh pr ready` — keep the PR draft until local rounds are finished). Notes are local
  files, so the PR branch is not touched and merge need not wait.
- On request with a task link — same steps; merged PR or not, notes are
  written the same way.

## Standing role — herdr space "Docs"

The skill runs as a standing agent in herdr space **Docs** (`Docs N` for extra
instances), not inside the session that did the task: that session ends with
150k+ context, and every docs turn there would re-read it.

### Model — check before any action

Role model: **Sonnet 5** (`claude-sonnet-5`), read from the system prompt
("You are powered by the model named ..."). Haiku misjudges what is
non-obvious enough to note; Opus/Fable are overkill for read-PR-and-write.

A different model still runs this role. Name it in the confirmation line as `Model: <name from the system prompt>`. The id above is a preference, not a gate: do not stop, and do not ask for a model switch, only because the id differs.

Not in Cursor/mimo: the role needs ClickUp MCP, `gh` and the {{PROJECT_NAME}}-clickup-docs skill.
Host lookup, remote hosts and `From` with host — same as `agent-qa` ("Role host").

Empty session with no incoming request → model check, Step 0 (name the space),
one-line role confirmation, wait. Don't pick tasks on your own.

### How to send (requesting agent)

When: after the final review round passes and `gh pr ready` is done — the
requester's step 5 of the completion checklist in AGENTS.md. The docs agent doesn't write to
the PR branch, so the requester may keep working on it and merge without waiting.

```bash
herdr workspace list                      # "label":"Docs", agent_status idle
herdr pane list --workspace <id>
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-docs "[DOCS REQUEST] ..."                   # no --wait
```

**Always send through `herdr-handoff.sh`, never as three separate `agent prompt` calls.** The script does `/clear` → `/<skill>` → waits until the pane is quiet → sends the request → checks that the request is visible in the pane (one retry). Separate prompts lose the request: `--wait` returns before `/clear` or the skill load is really finished, and the request is swallowed. Exit 0 = the request is visible in the pane; exit 1 = tell the user, do not assume it arrived. `--no-clear` (first argument) continues a previous task in the same pane; a non-claude pane (Cursor, mimo) gets the request directly. Multi-line request: pass it on stdin (`<<'EOF'`). On another host run the same script over ssh with the `remote-agents` preamble (`XDG_RUNTIME_DIR` when `/run/user/<uid>` exists, `~/.local/bin` and Homebrew in PATH).

All Docs instances busy → queue and send when one is idle; don't create spaces
(use a space that already exists; do not create one unless the user asked). No Docs space on this host → tell the user.

```
[DOCS REQUEST]
Task: https://app.clickup.com/t/{{CLICKUP_WORKSPACE_ID}}/task-1
PR: https://github.com/{{PROJECT_GIT_ORG}}/<repo>/pull/NNN   # one line per PR
Head: feat/task-1-refund-cap @ <sha>                       # per PR
Worktree: {{PROJECT_ROOT}}/.worktrees/api-rate-limit   # if it still exists
Plan: ~/.claude/plans/<plan>.md                               # if any
Notes: edge cases found during the task that the code doesn't show —
       DB/Logs answers, review findings, rejected options with the reason
From: <host>:<pane>                                           # $HERDR_PANE_ID with host
```

`Notes` is **required** and is the main input for domain notes: the requester
has the context, the docs agent doesn't and can't recover it from the diff.
List every known non-obvious thing to document, one line each — a rule with a
business reason, a trap (misleading column, nullable access key, timezone
shift), a decision that looks like a bug, a rejected option with why. Nothing
known → `Notes: none` explicitly, so an empty field reads as "checked", not
"forgot". The docs agent still adds what it finds in the diff and review
threads, but never drops a `Notes` item without saying why in `[DOCS RESULT]`.

### Result

Sent by the docs agent to `From` via the helper, not raw `send-text`:

```bash
~/.claude/hooks/herdr-pane-send.sh <From_pane> "[DOCS RESULT] ..."
```

```
[DOCS RESULT] task-1
Domain notes: <repo>/billing.md — +2 entries (local, agent-sync)
ClickUp: <page title> — <url> (updated)
Discrepancy: <spec vs shipped, only if any>
```

Can't proceed (no access to the ClickUp doc, PR not found) → `[DOCS BLOCKED]` with what is missing.

## Input

`/agent-docs <ClickUp task URL or ID>` or a `[DOCS REQUEST]` — one task per run. If the user gives
several tasks for one feature (e.g. a BE task and a FE task), gather facts
from all of them before writing, but still produce one page.

## Step 0 — Name your herdr space

Before anything else, give the workspace its label — the user should not rename it by hand:

```bash
herdr workspace get $HERDR_WORKSPACE_ID   # current label
herdr workspace list                      # which "Docs" / "Docs N" labels are taken
herdr workspace rename $HERDR_WORKSPACE_ID Docs
```

- Label already `Docs` or `Docs N` on **this** workspace → do nothing.
- `Docs` is taken by another workspace → use `Docs 1`; if that is taken too → `Docs 2`, then
  `Docs 3`, and so on (first free number).
- Never leave two spaces with the same label.
- Not in herdr (`HERDR_ENV` unset) → skip the step.

## Step 1 — Gather facts in one pass

Collect everything before writing a single line. Don't write, then go back
for a missing fact — that's a second research pass and it shows in the doc.

1. **Spec** — `clickup_get_task` with `include: ["description", "comments"]`
   if comments exist. This is the intent, not the ground truth: a task
   description can describe an *idea* ("possible UX improvement", "name not
   final") that shipped differently. Flag this internally, resolve it from
   code in step 3, and only write what actually shipped.
2. **Plan** — check `~/.claude/plans/` and the repo's `docs/plans/` for a
   file referencing the task id or its slug. A plan (if one exists) usually
   names the exact repos and files touched — use it to scope the code search
   in step 3 instead of guessing.
3. **Code / PR** — find what actually merged:
   - `gh search prs <task-id> --match title,body` (or `--repo {{PROJECT_GIT_ORG}}/<repo>`
     if the plan already named the repo) across the relevant repos, or
     `gh pr list --repo {{PROJECT_GIT_ORG}}/<repo> --search "<task-id>"`.
   - Once a PR is found, `gh pr view <n> --json title,body,files,url` to see
     which repo/files it touched, then `codegraph_explore` on the touched
     symbols to see the actual current behavior — not just the diff, since a
     later PR may have changed it again.
   - If no PR references the task id (task still "in progress"/"to do"),
     say so to the user instead of guessing at unshipped behavior — don't
     document a plan as if it were live code (do not invent specifics the code does not show-style:
     every claim in the doc must trace to code you read, not to the task
     description alone).
4. **Existing docs** — search the ClickUp Documentation space (workspace
   `{{CLICKUP_WORKSPACE_ID}}`, doc `{{CLICKUP_DOC_ID}}`) for a page already covering this feature
   or area (`clickup_list_document_pages` / `clickup_get_document_pages`,
   scanning titles/folders for the feature name). This decides update vs.
   create in step 4.

5. **Existing domain notes** — `memory/domain/<repo>/*.md` for every touched
   repo, plus the repo's own topic docs as context (e.g. `docs/search-lifecycle.md`,
   `docs/attention-required-rules.en.md`; read, never edited). Also scan the plan file, review
   threads and DB/Logs agent answers for edge cases found during the task.

## Step 1b — Update domain notes

Write a note only for something non-obvious from the code itself: a rule with
a business reason, a trap (column that looks right but isn't, nullable field
used as an access key, timezone shift), a deliberate decision that looks like
a bug. Skip what the code or types already say plainly.

- Path: `~/.claude/projects/{{PROJECT_KEY}}/memory/domain/<repo>/<topic>.md`
  (`~`, never an absolute `/home/<user>` — home-relative paths, not an absolute home directory). One
  topic per file (`billing.md`, `search.md`); topic exists →
  extend it, don't create a twin. New repo → create `<repo>/`.
- First line of every file: `Local notes (agent-sync), verified against code <YYYY-MM-DD>`
  — set it to today whenever you re-check the file against code.
- Each entry, 2–4 lines, English:
  ```
  ### <rule in one line>
  <why — business reason or the bug it caused>. Code: `<symbol>` in `<path>`.
  Source: <PR/ClickUp link>, <YYYY-MM-DD>.
  ```
- Reference symbols, not line numbers. Current behavior only — if the task
  changed a rule, rewrite the entry, don't append history.
- No commit, no push, nothing in the repo or PR body. Nothing to add → say so
  in the report, don't invent an entry.

## Step 2 — Resolve spec-vs-shipped conflicts

Where the task description and the merged code disagree (renamed button,
dropped "nice to have", changed validation rule), the code wins. Note the
resolution to yourself, not in the doc — the doc states what a QA tester or
PM sees today, not the history of how it got there. Exception: if the
disagreement matters operationally (a documented safety rule that got
dropped, a validation the spec promised but the code doesn't enforce), that's
a real finding — tell the user in chat, don't silently paper over it in the
doc.

## Step 3 — Write the page

Follow the {{PROJECT_NAME}}-clickup-docs skill in full: plain B1 English, no audience
labels, no self-justifying asides, worked numeric examples over descriptions
of thresholds, run the anti-slop checklist before publishing. This skill
adds only the structure for a task-driven page:

- **Title** — the feature name, not the ClickUp task name if they differ
  (task names are often internal/jira-style; the doc title is what a reader
  searches for).
- **What it does** — one or two sentences, current behavior only.
- **How it works** — the actual flow a QA tester or PM would click through
  or observe, in the order they'd encounter it. Use the worked-example
  pattern for any numbers (e.g. an amount going from $20 to $10 through a
  named action), sourced from the code, not invented.
- **What changed** (only when updating an existing page for a shipped
  change) — one short paragraph, no changelog table, no PR links inside the
  doc body (the PR is not reader-facing content).

## Step 4 — Publish

- **New page**: `clickup_create_document_page` in the folder that already
  holds sibling pages for the same product area (mirror an existing page's
  folder, don't invent a new folder without asking).
- **Existing page**: this is where the {{PROJECT_NAME}}-clickup-docs skill's replace-mode
  trap applies directly — `get_document_pages` for the full current body
  first, build the new full body (existing content + your change merged
  in), never `replace` with just the new paragraph. Re-fetch after
  publishing to sanity-check length.

## Step 5 — Report

One to three lines back to the user: the page title/link, the domain-notes
entries added/changed (repo + file), and — only if step 2 surfaced one — the
spec-vs-shipped discrepancy that needs a human call. Nothing else; the doc itself is the deliverable, not a chat summary
of it.

## Boundaries

- Don't touch `docs/qa-checklist.md` or post PR/ClickUp comments as a side
  effect of this skill — those are separate workflows
  (do not post to GitHub or the tracker unless asked). This skill writes only the
  Documentation-space page and `memory/domain/<repo>/*.md`.
- Don't invent scope: if the task covers three sub-features and only one
  shipped, document the one that shipped and say so, don't fill in the
  other two from the spec.
- If no plan and no open or merged PR exist for the task, tell the user there's
  nothing shipped to document yet rather than writing a page from the task
  description alone.
