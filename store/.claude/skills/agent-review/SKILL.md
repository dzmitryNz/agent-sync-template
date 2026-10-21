---
name: agent-review
description: "Inter-agent review protocol: how to send a PR for review to a standing agent in herdr space \"Review Cursor\" / \"Review Claude\" (including from another host) and what the reviewer itself does. Use when an agent needs a code review from another session, when a review request arrives from another agent (a message starting with [REVIEW REQUEST]), or when the user asks to review someone else's changes as the reviewer agent. Triggers: request a review, send for review, REVIEW REQUEST, review a PR, I am the reviewer agent."
---

# Review between agents

The reviewer is a standing agent in herdr space **Review Cursor** or **Review Claude**
(by agent type). Requests also come from other hosts, so the unit of review is an
**open PR**: the reviewer has no local paths and no uncommitted changes.

## Role host

The role has no permanent host. The requester looks for it on its own machine:
`herdr-spaces list`, a space with label `Review Cursor` / `Review Cursor N` /
`Review Claude` / `Review Claude N` and `agent_status: idle`.

Take an agent on **another host** only if the user named the host (in chat or in the
`Hosts:` field of a PM request). If the role is not present locally and no host is
named, do not search other machines; tell the user which space to add
(use a space that already exists; do not create one unless the user asked).

**Status of a named host** comes from a cache that the systemd timer
`herdr-host-ping.timer` refreshes every 5 minutes (no ssh or tokens spent on it):

```bash
cat ~/.cache/herdr-hosts/<host>.status     # <UTC time>\t<STATUS>\t<details>
```

`STATUS`: ok | busy | no-space | ssh-auth | ssh-down | herdr-down. Busyness of a
specific space is visible in the spaces field (`Review Cursor=idle`, `Review Claude=idle`).
If the file is missing or older than 15 minutes, run once by hand
`~/.claude/hooks/herdr-host-ping.sh <host> "Review Cursor"` (or `"Review Claude"`;
exit code 0 = OK to send) and tell the user about the timer. `busy` — wait for idle.
`ssh-auth` — Tailscale SSH asks for re-authorization via a link in the output: only the
user can do this; tell them and stop. `ssh-down`/`herdr-down` — report to the user, do
not take the role's work on yourself.

**Request to another host** goes over ssh via Tailscale (preamble from the
`remote-agents` skill: the user from `jq -r .home ~/.agent-sync/sessions/<host>/*.json`,
the `P=` line below: `XDG_RUNTIME_DIR` on Linux, Homebrew `herdr` on macOS):

```bash
P='[ -d /run/user/$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/$(id -u); PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr'
ssh <user>@<host> "$P workspace list"                   # label → workspace_id, agent_status
ssh <user>@<host> "$P pane list --workspace <id>"
ssh <user>@<host> "$P agent prompt <pane_id> '[... REQUEST] ...'"   # no --wait over ssh
```

**`From` always carries the host**: `From: <host>:w7:p2`. The executor replies the
same way: if the host in `From` is not its own, `ssh <user>@<host> "$P agent prompt <pane> ..."`,
otherwise a local `herdr agent prompt`. A `From` without a host reads as "the same host
as the sender", but in new requests always write the host.

Local paths in a request (worktree, plan) are valid only on the executor's host:
the plan comes from the synced `~/.claude/plans/`, the code from the branch/PR, not from a path.

## Model — check before any action

This role needs **Opus 5.5** (`claude-opus-5-5`); Opus 5 is more expensive and does not fit.
The current session's model is stated in the system prompt ("You are powered by the model named ...").

A different model still runs this role. Name it in the confirmation line as `Model: <name from the system prompt>`. The id above is a preference, not a gate: do not stop, and do not ask for a model switch, only because the id differs.


This role runs on Claude. A workspace labeled `Review Cursor` is only a label and a history bucket so the two families can be told apart. Do not perform the review in a Cursor pane, and do not send a `[REVIEW REQUEST]` there. Send it to an idle `Review Claude` pane. Other roles' Cursor model preferences, and the `~/.cache/agent-roles/any-model` flag, are in `AGENTS.md` ("Role models").


## Self-assignment in an empty window

If this skill is invoked on an agent in an **empty session** — no incoming
`[REVIEW REQUEST]` in the prompt and no other current task in context (a fresh
chat, just started in space Review Cursor / Review Claude) — this is the way to assign
the agent as a reviewer: it confirms the role in one line and does nothing further
until a `[REVIEW REQUEST]` arrives in this same pane. Do not look at other people's PRs
and do not start a review on your own initiative.

If the context is non-empty (there is already history, the incoming text starts with
`[REVIEW REQUEST]`, or this is an ordinary user invocation outside this protocol), this is
not self-assignment but the ordinary protocol branch below; the "empty window" condition is
checked once, at the first invocation of the skill in a session, not on every message.

### Naming your space

On self-assignment the agent gives its workspace the right label itself — the user does
not need to rename it by hand. The base name depends on the agent type:

- **cursor-agent** (`CURSOR_AGENT=1` or `"agent":"cursor"` in `herdr pane list`)
  → `Review Cursor`
- **claude** (otherwise, `"agent":"claude"`) → `Review Claude`

```bash
herdr-spaces me          # current label
herdr-spaces list                              # all labels, to pick a number
# BASE="Review Cursor" or "Review Claude"
herdr workspace rename $HERDR_WORKSPACE_ID "$TARGET"
```

**How to choose `TARGET`.** Collect from `workspace list` all labels of your own family
(your `BASE` and `BASE N`, where N is an integer ≥ 2). Exclude your own current workspace
from the list.

1. Your label already equals `BASE` or `BASE N` — do nothing.
2. Nobody else occupies `BASE` — `TARGET=BASE`.
3. Otherwise take the maximum number among the occupied ones: bare `BASE` counts as `1`,
   for `BASE N` the number is N. `TARGET="$BASE $((max+1))"` (a space before the digit:
   `Review Cursor 2`, `Review Claude 3`, ...).

Do not create two spaces with the same label: requests pick an agent by label and
status. Without `HERDR_ENV=1` (session not in herdr) skip the step and mention it in the
role confirmation line.


## Where to find the reviewer

Do not review yourself and do not spawn a subagent — the request goes to an idle
`Review Claude` pane. A `Review Cursor` label is not a destination:

```bash
herdr-spaces list                      # label: "Review Cursor"|"Review Claude"|… N
herdr pane list --workspace <id>          # pane with the agent (one per workspace)
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-review "[REVIEW REQUEST] ..."   # no --wait: the answer arrives on its own
```

**Always send through `herdr-handoff.sh`, never as three separate `agent prompt` calls.** The script does `/clear` → `/<skill>` → waits until the pane is quiet → sends the request → checks that the request is visible in the pane (one retry). Separate prompts lose the request: `--wait` returns before `/clear` or the skill load is really finished, and the request is swallowed. Exit 0 = the request is visible in the pane; exit 1 = tell the user, do not assume it arrived. `--no-clear` (first argument) continues a previous task in the same pane; a non-claude pane (Cursor, mimo) gets the request directly. Multi-line request: pass it on stdin (`<<'EOF'`). On another host run the same script over ssh with the `remote-agents` preamble (`XDG_RUNTIME_DIR` when `/run/user/<uid>` exists, `~/.local/bin` and Homebrew in PATH).

**`/clear` before the request.** The executor does not need past reviews, yet each of its
turns rereads them: a context over 150k is more than half of the weekly limit. The first two steps of the script apply only if `pane list` shows `"agent":"claude"` for the pane and the request
does not continue a previous one in the same pane (re-review of the same PR after fixes).
After `/clear` the role is assigned anew via `/agent-review`, not by the request tag. From
another host — the same script over ssh. 
**Several instances.** Spaces are found by label `Review Cursor`, `Review Cursor N`,
`Review Claude`, `Review Claude N` (N ≥ 2); `herdr-spaces list` shows `agent_status` for
each. Take an idle `Review Claude` pane. Do not send to `Review Cursor`: that label
is history only. All `working` — do not send to a busy one (the
request would wedge into someone else's context): queue the request and send it when an
instance becomes `idle`; several requests — one at a time, in dependency order.
Do not create a new space or ask for one unless the user said so (use a space that already exists; do not create one unless the user asked).

The Review role is one for all repositories (there is no separate reviewer per service);
there may be several space instances for parallelism. If the pane does not respond or the
space is not found, tell the user rather than reviewing with your own hands: reviewing
yourself does not count as a second round.

## Request

```
[REVIEW REQUEST]
PR: https://github.com/{{PROJECT_GIT_ORG}}/<repo>/pull/861
Task: ClickUp task-1          # or a plan, or "none"
From: w7:p2                      # your own $HERDR_PANE_ID — where to send the result
Focus: tax on cancelled bookings    # optional
```

- **PR only.** A branch in someone else's worktree or `uncommitted` is not a review: PR
  first, then the request. The PR is usually **draft** (keep the PR draft until local rounds are finished) — as
  it should be: local rounds go before `gh pr ready`, otherwise GitHub bots spend their
  limit on the same findings. Reviewing a draft is fine; the reviewer does not run
  `gh pr ready` itself.
- **Not ready before the local rounds.** Before the first `[REVIEW REQUEST]`, if the PR is
  already not draft (`gh pr view --json isDraft`), return it to draft:
  `gh pr ready <N> --undo` — and only then send the review.
- **`Task`** — what to check behavior against. Without it the review is about the code,
  not about whether this was what was asked.
- **`From`** — your own `$HERDR_PANE_ID`. Without it the reviewer does not know where to
  return the verdict: the result lands in its own chat and stays there.
- The reviewer does not write PR comments — only to the agent in chat. Only the user can
  change this, not a requesting agent.

**Do not wait for the answer.** Do not set `--wait` on a review: the real pass — clone,
fetch, `/code-review`, reading files — takes many minutes, the timeout expires anyway, and
until then the requesting agent idles. Sent the request — told the user which space it went
to and returned to your own work (or ended the turn). The reviewer itself will send
`[REVIEW RESULT]` to the pane from `From`; it arrives as an ordinary incoming message.

Do not poll the reviewer's pane with repeated `agent prompt`s — the result arrives as an
incoming message. If the role is silent longer than reasonable: once, `herdr-pane-reply <pane>`
instead of `herdr pane read` (the block from `[… RESULT]`).

## Reviewer's work

1. A local clone of the PR's repo (not `{{PROJECT_ROOT}}/` — if it has no git root,
   code review needs a git root). A clean copy of the PR without conflict with the
   author's branch: `wt-new <repo> review-<n> --at <headRefOid>` (detached at the head commit).
2. `gh pr view <N> --json headRefName,baseRefName,state,title,headRefOid` + `git fetch` +
   `pr-diff <repo> <N>` (file list first, then the diff one file/group at a time — not the full `gh pr diff`).
3. `/code-review <N> medium` from the git root; `high` — if the diff touches money, billing,
   permissions or migrations, or is over ~500 lines; `max` — only at the user's request.
   Write the level explicitly every time: without it the skill takes the last one typed.
4. Reading files — via subagents (`Explore`, `model: haiku` for "where does it live").
   The sender clears the context via `/clear` before the request (see "Where to find the reviewer").
5. Beyond the skill, check: reconciliation with `Task` (is the scope cut), tests (do they
   exist and cover the behavior — from the diff, not by running), stale comments next to
   the change (update comments next to the change), the PR body per template and an
   untouched `docs/qa-checklist.md` (the PR body follows the repo template). Plus three pitfalls that `/code-review`
   regularly misses and that people and the bot catch in PRs:
   - external HTTP calls (fetch/axios) without timeout — especially on the shutdown path;
   - check every claim in the PR body and QA steps against the diff — the most frequent
     finding (the PR body must match the final diff);
   - a fix in one branch or copy of the code: find adjacent places with the same
     pattern in the diff and check that they are fixed too;
   - a migration must be idempotent, and you must check that idempotency, not only
     the repo README. A second run on a database that already has the change is a
     no-op: existing columns, indexes, and rows are guarded, and nothing is dropped
     or rewritten without a current-state check. Also check online DDL against that
     repo's README.
6. **Does not run tests itself.** Running unit/integration tests, type-check and lint is
   `agent-qa` (the QA space): a `[QA REQUEST]` with the PR branch and Baseline, `From`
   — your own pane. Meanwhile the reviewer reads the diff; the result arrives on its own,
   no need to idle waiting for it. If a green run is needed for the verdict and QA has not
   answered yet — hand over the review with a note "did not run tests, sent to QA", rather
   than running `npm test` yourself.

## Answer

```
Verdict: blocker | fix-before-merge | minor-only | ok

Blockers
1. [correctness/null-guard] src/x.ts:42 — crashes on .id for a booking without owner_id → guard before dereferencing

Fix before merge
2. ...

Minor
3. ...

Checked: task matched | read tests via diff, run in QA (17/17) | migrations not checked — none in diff
```

Verdict on the first line. Each finding is an input that breaks: "may be null" without a
scenario will be dismissed by the author. The "Checked" section lists the
unchecked too, silence reads as "everything checked". Mark a disputable finding as disputable.

Every finding begins with a key `[<category>/<key>]` from `review-keys.md` next to the
skill. `/pr-review-retro` finds repeats across PRs by the keys, so take an existing key
first, a new one only if none fits (and add it to the file).

### Where to send

The reviewer **itself** sends the finished review to the requesting agent in its pane —
still nothing is written to the PR:

```bash
~/.claude/hooks/herdr-pane-send.sh <pane_id from From> "[REVIEW RESULT] PR #12

Verdict: ...
..."
```

Through the helper, not a bare `pane send-text` + `send-keys Enter` pair: with Cursor, after
that pair a copy of the text stays in the input field and sticks to the next message into
that pane. The helper sends `herdr agent prompt`, and on `agent_not_ready` (a pane without a
named agent, e.g. mimo) falls back to send-text.

`--wait` is not needed here: the reviewer does not wait for an answer, the author fixes. If
there was no `From` in the request, find the pane via `herdr pane list` (workspace/repository
from the request) and, if it cannot be determined unambiguously, ask the user rather than
leave the verdict in your own chat: the requesting agent will not see it.

The same text also stays in the reviewer's chat — the user reads the review there.

## After REVIEW RESULT — what the requesting agent does

`Verdict: blocker` or `fix-before-merge` — fixes are needed. Do not fix it yourself (same
principle as the reviewer's — do not write into someone else's worktree) and do not retell
the findings to the user as a fact for decision: hand them to `agent-developer`
(the Developer space) immediately, with the same `[DEV REQUEST]` into the worktree/branch
of this PR, findings from `Blockers`/`Fix before merge` as `Focus`. `Minor` may be attached
optionally; no need to fix right away.

The exception is a finding that describes a fork rather than an unambiguous fix (two
different ways to close it; a blocker that requires choosing between architecture options) —
then first to the user's choice, then a `[DEV REQUEST]` with the decision already made.
`Verdict: ok`/`minor-only` — minor fixes are up to the user, the review itself does not
block. Right after such a verdict the requester runs `gh pr ready <N>`
(keep the PR draft until local rounds are finished): local rounds are finished, now GitHub review bots may be let
in. While the verdict is `blocker` / `fix-before-merge`, do not take it out of draft.

After fixes and a repeat push — a new `[REVIEW REQUEST]` for the same PR (still draft);
do not skip the second round.

## Boundaries

- Post nothing to GitHub and ClickUp — only to chat
  (do not post to GitHub or the tracker unless asked). Inline PR comments only on the user's direct request.
- Approval and merge are not yours (do not merge or approve your own PR,
  an approval does not add extra comments). `gh pr ready` is not yours either — the requester
  takes it out of draft after `ok`/`minor-only`.
- Make no edits: the author fixes, otherwise two agents write into one worktree
  (work in a worktree, not the shared checkout).
- On scope — in one direction only: whether it was **cut** relative to `Task`. Expanded
  scope is not a finding: "move it to a separate PR", "this is off-topic", "CLAUDE.md is
  here as a rider" — do not write these, the author may have done it at the user's request,
  which the reviewer cannot see (do not split one finding into scope nits). If it is unclear why
  a change exists, ask a one-line question in chat. Check the content of such a change as
  usual (update comments next to the change).
