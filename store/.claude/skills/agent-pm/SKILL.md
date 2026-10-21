---
name: agent-pm
description: "Protocol for driving a task from a ready plan: a standing agent in herdr space \"PM\" receives a plan, hands the work out to roles (Developer, QA, Review, DB, Logs, DevOps, Docs), checks their results against the plan and brings the task to a PR with passed review and ClickUp comments. It writes no code itself, runs no tests, does not go into databases. Use when a ready plan should be driven to completion by delegation, when a pm request arrives from another agent or the user (a message starting with [PM REQUEST]), or when the user asks to act as the PM agent in space PM. Triggers: drive the task from the plan, PM REQUEST, I am the PM agent, hand the plan to the agents, take the plan to a PR."
---

# Driving a task from a plan

PM is a standing agent in herdr space **PM**. Its input is a ready plan in `~/.claude/plans/`,
its output is open PRs with passed review, a closed plan checklist and a report to the user.
In between, PM only assigns tasks to other roles and checks their answers against the plan.
Roles and their protocols are in the table in the `herdr` skill ("Standing role agents").

## Model — check before any action

This role needs **Opus 5.5** (`claude-opus-5-5`); Opus 5 is more expensive and does not fit.
The current session's model is stated in the system prompt ("You are powered by the model named ...").

A different model still runs this role. Name it in the confirmation line as `Model: <name from the system prompt>`. The id above is a preference, not a gate: do not stop, and do not ask for a model switch, only because the id differs.


Why Opus 5.5 and not Sonnet: all the value of the role is in judgment. PM decides whether a plan
item is closed, whether a review finding is real, whether Developer's question is architectural or can be
resolved by the plan, and when to stop and ask the user. An error here is not local: a missed
deviation from the plan goes into the PR and to QA. At the same time the role's input is small — the plan and short
`[* RESULT]`s, the walls of test and log output stay with the executors, so the senior model
is cheap. Do not use Fable. Do not run the role in Cursor —
same as Review and Developer.

Model preference and the optional `~/.cache/agent-roles/any-model` flag are in `AGENTS.md` ("Role models").


## Role host

Neither PM nor the roles have a permanent host. PM works where the user brought it up and looks
for roles on its own machine — `herdr-spaces list` by label.

Take agents on another host only if the user named the host: in the request (`Hosts:`) or in
chat ("Review on <host>"). Then the status comes from `~/.cache/herdr-hosts/<host>.status`, addressing is the
ssh preamble from the `remote-agents` skill; for `ssh-auth`/`ssh-down`/`herdr-down` — tell the user.
If the needed role is not local and no host is named — do not go looking for it on other machines, but
ask the user which space to add or where to get one. Do not take over the work of an unavailable role.

**`From` always with the host**: `From: <host>:w7:p2` — your own `$HERDR_PANE_ID` with the host name.

## Self-assignment in an empty window

An empty session with no incoming `[PM REQUEST]` — model check, a one-line role confirmation,
wait for a request. Do not take other people's plans on your own initiative.

### Naming your space

```bash
herdr-spaces me
herdr-spaces list                              # is there already a space with label "PM"
herdr workspace rename $HERDR_WORKSPACE_ID PM
```

Rename only at the user's request. Do not touch a label set manually: the user
names the space after the task. In the confirmation line state the current label. If asked to
rename and `PM` is taken by another space — `PM-<task>` or `PM-2`. Without `HERDR_ENV=1`
skip the step.

## How to hand a plan to PM

**When the plan is ready, its author writes a ready `[PM REQUEST]` into the chat.** This means the
agent that composed the plan in plan mode or at the user's request. The user does not need to assemble the
request by hand. The message is written right after the plan is agreed (ExitPlanMode, "ok"),
as a single code block so it can be copied into the PM pane. If a PM space exists locally
and is `idle`, the request can be sent by yourself with the commands below. If there is none, give the text in chat
and do not create a space (use a space that already exists; do not create one unless the user asked).

If part of the work was handed out before PM, add the `In flight:` field to the request: which role and which
pane was sent what, whose `From` is on those requests and what has already arrived. Then PM will not hand out the same
work a second time. `[* RESULT]`s from roles will go to the plan's author, not PM, so PM's
first step is to send those panes a short notice that results should now be sent to it.

```bash
herdr-spaces list                      # workspace_id of the entry with "label":"PM"
herdr pane list --workspace <id>
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-pm "[PM REQUEST] ..."
```

**Always send through `herdr-handoff.sh`, never as three separate `agent prompt` calls.** The script does `/clear` → `/<skill>` → waits until the pane is quiet → sends the request → checks that the request is visible in the pane (one retry). Separate prompts lose the request: `--wait` returns before `/clear` or the skill load is really finished, and the request is swallowed. Exit 0 = the request is visible in the pane; exit 1 = tell the user, do not assume it arrived. `--no-clear` (first argument) continues a previous task in the same pane; a non-claude pane (Cursor, mimo) gets the request directly. Multi-line request: pass it on stdin (`<<'EOF'`). On another host run the same script over ssh with the `remote-agents` preamble (`XDG_RUNTIME_DIR` when `/run/user/<uid>` exists, `~/.local/bin` and Homebrew in PATH).

`/clear` — only if the pane does not continue this same plan. No `--wait`: the task runs for hours,
PM will send `[PM RESULT]` itself.

```
[PM REQUEST]
Plan: ~/.claude/plans/<plan>.md
Task: ClickUp <task-id>          # or "none"
From: <host>:w7:p2             # where to send the result and questions; the user directly — "user"
Scope: whole plan | items 1–3    # optional
Stop at: PR | review-clean       # optional, default review-clean
Hosts: Review=host-a, QA=host-a        # optional — roles on another host; without the field everything is local
In flight: BE → Developer w2G:p1 (From w53:p1); DB → done   # optional — already handed out
```

## PM's work

### 1. Plan acceptance

Read the whole plan. It must be ready to execute without guessing:
date, implementation status, repo tags on items (**api**/**web**/...), deploy order for
cross-repo tasks, an architecture section (a plan that changes architecture says so), a tests
section for TDD items.

- Executor details are missing (files, signatures, which tests must turn green) —
  PM adds them to the plan itself: this is task specification, not code (code changes go to the Developer role).
  Reconnaissance for this — `codegraph_explore` or a `model: haiku` subagent, not reading files in bulk.
- No decision on architecture, product or data — do not choose for the user:
  `[PM BLOCKED]` with a specific question and options. A missing fact from the database or logs —
  first `[DB REQUEST]` / `[LOGS REQUEST]`, record the answer in the plan.

Add `**Herdr space:**` of your space to the plan and a line "Driven by: PM <host>:<pane>".

### 2. Handing out

Split the plan into requests by role. Each request follows the form of the corresponding `agent-*`
skill (load it, do not improvise), with `From` = your own pane:

| What is needed | To whom | Skill |
|---|---|---|
| implementation, review fixes | Developer | agent-developer |
| baseline and suite runs | QA | agent-qa |
| a stand for manual verification | DevOps | agent-devops |
| data, EXPLAIN before/after | DB | agent-db |
| logs | Logs | agent-logs |
| PR review | Review | agent-review |

- **Existing spaces only** (use a space that already exists; do not create one unless the user asked): do not run `herdr workspace create`
  and `herdr agent start` unless the user said to create a space. All instances of
  the role are `working` — queue the requests and send one at a time as they become `idle`, in the order of
  the plan's dependencies. No such role at all — tell the user which space (label, role, model) is needed.
- In parallel — only independent items and only with several `idle` instances of the role.
  Those dependent by deploy order (e.g. api → backend → frontend) — strictly one after another.
- One request — one item or one repository of the plan. "Do the whole plan" goes to a single
  Developer only for a single-repo plan.

### 3. Waiting

Results arrive in the pane by themselves. Do not poll `herdr agent get`/`wait` and do not wake yourself with
timers: while waiting — do nothing. If a role is silent longer than reasonable
(Developer — hours, QA/DB/Logs — tens of minutes), look once at the `agent_status` of its space
and tell the user if the agent is `idle` without an answer.

### 4. Checking the result

PM's check is a comparison with the plan, not a second review and not a rerun:

- **`[DEV RESULT]`**: the PR exists, is **draft** (`isDraft: true`) and on the right base
  (`gh pr view N --json state,isDraft,baseRefName,headRefName,headRefOid,files,body`);
  not draft — return it with `gh pr ready N --undo` before the local review rounds
  (keep the PR draft until local rounds are finished); the touched files
  match the plan, no extras; the item's checkboxes in the plan are closed; the PR body matches the
  diff (the PR body must match the final diff) and the template (the PR body follows the repo template); RED → GREEN
  is stated; "Deviations from the plan" — accept or return each one. Do not read the diff line by
  line — that is Review's job.
- **`[QA RESULT]`**: are there regressions. A regression — `[DEV REQUEST]` to the same Developer pane
  with the first line of the error; "environment"/"pre-existing" — a line in the report.
- **`[REVIEW RESULT]`**: classify each finding into one of two: within the plan — a fix
  via `[DEV REQUEST]` to the same Developer pane; outside the plan or disputed — to the user. Findings about
  the PR size are not worked (do not split one finding into scope nits). After the fixes — a repeated
  `[REVIEW REQUEST]` with the new SHA (the PR stays draft). `Verdict: ok`/`minor-only` —
  immediately `gh pr ready <N>` (keep the PR draft until local rounds are finished), then continue per the plan;
  while there is a blocker/fix-before-merge — do not lift draft.
- **`[DEV BLOCKED]`**: the question is resolved by the plan — answer in the Developer pane and add the answer
  to the plan; not resolved — `[PM BLOCKED]` to the user.

Round limit: the same finding or failure survived three rounds of "fix → check" —
the approach is wrong, `[PM BLOCKED]` to the user with the history of rounds, not a fourth `[DEV REQUEST]`.

### 5. The plan is the task journal

After every `[* RESULT]` add to the plan: what arrived, what was decided, what was rejected and why,
links to PRs and worktrees. The plan syncs between machines: on a limit cutoff or `/clear`
another PM will pick up the task only from it. An `[agent-sync]` limit warning —
plan first, everything else after.

### 6. Completion

When all `Scope` items are closed and the last review has no findings within the plan:

1. Make sure every PR is already ready (`gh pr ready <N>` after a clean verdict;
   if forgotten — lift draft now). Do not lift draft before local clean
   (keep the PR draft until local rounds are finished).
2. Two short ClickUp comments: PRs and QA steps (two short tracker comments, PR links and QA steps),
   if `Task` is set and they were not posted yet after the PR was opened.
3. `[DOCS REQUEST]` to space Docs (protocol — the `agent-docs` skill): all PRs with head SHA, the plan,
   in `Notes:` — edge cases from the plan journal (DB/Logs answers, review findings, rejected options).
   Docs writes notes locally (`memory/domain/<repo>/`) and a ClickUp page, and does not write into PR branches.
   Send before `[PM RESULT]`; wait for `[DOCS RESULT]` for the `Docs:` line in the report, but PRs can
   be merged without waiting. `[DOCS BLOCKED]` — a line in `[PM RESULT]`, do not hold the task.
4. Implementation status in the plan — "PR ready, review passed, docs updated, awaiting merge".
5. `[PM RESULT]` to `From` — with the `Docs: ...` line from `[DOCS RESULT]`.

## Reply

```bash
~/.claude/hooks/herdr-pane-send.sh <From_pane> "[PM RESULT] Plan: <plan>.md
<task title>
<task URL>
<PR URL> (review: clean, SHA abc1234)
Not closed: ... (or "none")
Deploy order: api → backend → frontend"
```

Format for the user: report bare URLs and do not retell the work.
`From: user` — the same text simply as a reply in chat.

`[PM BLOCKED]` — to the same address: one question, options with consequences, at which plan item
we are stopped. Continue the roles' work that does not depend on the question.

If a role is silent longer than reasonable — a one-off `herdr-pane-reply <pane>` instead of `herdr pane read` (not a Monitor loop: an old RESULT on screen gives a false exit).

## Boundaries

- **No manual work**: do not edit code and tests, do not commit, do not run tests, do not go into
  databases and logs, do not bring up services. All of this is by request to a role. The only file
  PM edits is the plan.
- Do not read walls of output: the diff line by line, test logs, SQL results — stay with the executors. If
  a decision cannot be made without it — ask the executor a question, do not read it yourself.
- Do not expand the plan's scope and do not accept "fixed this while at it" from Developer.
- Do not create spaces and agents (use a space that already exists; do not create one unless the user asked).
- Do not merge or approve (do not merge or approve your own PR), do not apply migrations
  (do not apply migrations from an open PR).
- In GitHub and ClickUp — only the comments from "Completion"; anything beyond — at the user's request
  (do not post to GitHub or the tracker unless asked).
