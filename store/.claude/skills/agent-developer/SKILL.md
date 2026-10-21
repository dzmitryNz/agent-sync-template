---
name: agent-developer
description: "Implementation protocol between agents: how to hand an agreed plan over for implementation to the standing agent in herdr space \"Developer\" and what the implementer itself does. Use when an agent needs implementation work done by another session, when a dev request arrives from another agent (a message starting with [DEV REQUEST]), or when the user asks to implement a plan as the developer agent in space Developer. Triggers: hand off for implementation, pass to Developer, DEV REQUEST, I am the developer agent, implement the plan."
---

# Implementation between agents

The implementer is a standing agent in the herdr space **Developer**. Like the reviewer
(the agent-review skill), it is one agent for all repositories — there is no separate one per
service.

## Role host

The role has no permanent host. The requester looks for it on its own machine —
`herdr-spaces list`, a space with label `Developer`/`Developer-N` and `agent_status: idle`.

Take an agent on **another host** only if the host was named by the user (in chat or via the
`Hosts:` field of a request from PM). If the role is not available locally and no host is named,
do not search other machines; tell the user which space to add (use a space that already exists; do not create one unless the user asked).

**Status of a named host** — from the cache that the systemd timer `herdr-host-ping.timer`
refreshes every 5 minutes (no ssh or tokens are spent on it):

```bash
cat ~/.cache/herdr-hosts/<host>.status     # <UTC time>\t<STATUS>\t<details>
```

`STATUS`: ok | busy | no-space | ssh-auth | ssh-down | herdr-down. The busyness of a specific
space is visible in the spaces field (`Developer=idle`). If the file is missing or its time is older than 15 minutes —
run `~/.claude/hooks/herdr-host-ping.sh <host> Developer` by hand once (exit code 0 = OK to send)
and tell the user about the timer. `busy` — wait for idle. `ssh-auth` — Tailscale SSH asks for
re-authorization via a link from the output: only the user does this; tell them and stop.
`ssh-down`/`herdr-down` — report to the user, do not take over the role's work yourself.

**Request to another host** — via ssh over Tailscale (preamble from the `remote-agents` skill:
user from `jq -r .home ~/.agent-sync/sessions/<host>/*.json`,
the `P=` line below: `XDG_RUNTIME_DIR` on Linux, Homebrew `herdr` on macOS):

```bash
P='[ -d /run/user/$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/$(id -u); PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr'
ssh <user>@<host> "$P workspace list"                   # label → workspace_id, agent_status
ssh <user>@<host> "$P pane list --workspace <id>"
ssh <user>@<host> "$P agent prompt <pane_id> '[... REQUEST] ...'"   # no --wait over ssh
```

**`From` always includes the host**: `From: <host>:w7:p2`. The implementer replies the same
way: if the host in `From` is not its own — `ssh <user>@<host> "$P agent prompt <pane> ..."`,
otherwise a local `herdr agent prompt`. Read a `From` without a host as "the same host
as the sender", but always write the host in new requests.

Local paths in the request (worktree, plan) are valid only on the implementer's host:
the plan comes from the synced `~/.claude/plans/`, the code — by branch/PR, not by path.

## Model — check before any action

This role requires **Sonnet 5** (`claude-sonnet-5`). The current session's model is stated in the system
prompt ("You are powered by the model named ...").

A different model still runs this role. Name it in the confirmation line as `Model: <name from the system prompt>`. The id above is a preference, not a gate: do not stop, and do not ask for a model switch, only because the id differs.


In Cursor the role runs on `composer-2.5-fast` (the gate is the `Model` line in `cursor-agent about`),
like DevOps, QA and Logs; DB runs there on Claude Opus 5 Medium. Give a Cursor implementer only
mechanical work from an executor plan; diagnostics and architecture go to a Claude implementer
(section "Delegating to ralphex-cursor" in `~/.claude/CLAUDE.md`). The final review round is always Claude.

Model preference and the optional `~/.cache/agent-roles/any-model` flag are in `AGENTS.md` ("Role models").


## Self-assignment in an empty window

If this skill is invoked by an agent in an **empty session** — no incoming
`[DEV REQUEST]` in the prompt and no other current task in the context (a fresh
chat just started in space Developer) — this is the way to assign the agent as
the implementer: it confirms the role in one line and does nothing else
until a `[DEV REQUEST]` arrives in this same pane. Do not read other people's plans and do not
start work on its own initiative.

If the context is non-empty (there is history, the incoming text starts with
`[DEV REQUEST]`/`[DEV BLOCKED]`, or it is an ordinary invocation by the user outside this protocol) —
this is not self-assignment but the ordinary protocol branch below; the "empty window"
condition is checked once on the first invocation of the skill in a session, not on
every message.

### Name your space

On self-assignment the agent gives the workspace the right label itself — the user does not need to
rename it by hand:

```bash
herdr-spaces me          # current label
herdr-spaces list                              # is there already another space with label "Developer"
herdr workspace rename $HERDR_WORKSPACE_ID Developer
```

If the label is already `Developer` or `Developer-<something>` — do nothing. If `Developer` is already held by
**another** workspace (a second instance for a parallel task) — take a
task slug or the next number: `Developer-<task>`, `Developer-2`, ... Do not create two spaces with the same label:
requests pick an agent by label and status. Without `HERDR_ENV=1` (the session is not in herdr) skip the step
and mention this in the role's confirmation line.


## How to hand over a plan for implementation

```bash
herdr-spaces list                      # workspace_id of the entry with "label":"Developer"
herdr pane list --workspace <id>          # the pane with the agent (one per workspace)
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-developer "[DEV REQUEST] ..."
```

**Always send through `herdr-handoff.sh`, never as three separate `agent prompt` calls.** The script does `/clear` → `/<skill>` → waits until the pane is quiet → sends the request → checks that the request is visible in the pane (one retry). Separate prompts lose the request: `--wait` returns before `/clear` or the skill load is really finished, and the request is swallowed. Exit 0 = the request is visible in the pane; exit 1 = tell the user, do not assume it arrived. `--no-clear` (first argument) continues a previous task in the same pane; a non-claude pane (Cursor, mimo) gets the request directly. Multi-line request: pass it on stdin (`<<'EOF'`). On another host run the same script over ssh with the `remote-agents` preamble (`XDG_RUNTIME_DIR` when `/run/user/<uid>` exists, `~/.local/bin` and Homebrew in PATH).

**`/clear` before the request.** The implementer does not need past tasks, and each of its turns
re-reads them again: context above 150k is more than half of the weekly limit. The first two steps of the script — only if the pane in `pane list` has `"agent":"claude"` and the request does not
continue a previous one in the same pane (review fixes of the same plan). After `/clear` the role
is assigned again via `/agent-developer`, not by the request tag. From another host —
the same script over ssh. 
**Multiple instances.** Spaces are looked up by label `Developer` and `Developer-N`; in `herdr-spaces list`
each has an `agent_status`. Take the one that is `idle`. If all are `working` — do not send to
a busy one (the request would wedge into someone else's context): queue the request and send it
when an instance becomes `idle`; several requests — one at a time, in dependency order.
Do not create or ask for a new space unless the user says so (use a space that already exists; do not create one unless the user asked).

**Without `--wait`.** Implementation takes many steps (TDD, tests, commit, PR) and
does not fit a reasonable timeout — no need to wait, the implementer sends
the result to the pane from `From` itself when done. If the role is silent longer than reasonable —
a one-off `herdr-pane-reply <pane>` instead of `herdr pane read` (not a Monitor loop: an old RESULT on screen gives a false exit).

### Own instance for a task (only on the user's instruction)

By default — the existing `Developer`/`Developer-N`; when busy, a queue
(use a space that already exists; do not create one unless the user asked). Spawn an implementer for a task only if the
user explicitly said to create a space. Then the requesting agent:

```bash
# 1. workspace with cwd in the repository's git root (not {{PROJECT_ROOT}}/) and a meaningful label
herdr workspace create --cwd {{PROJECT_ROOT}}/<repo> --label Developer-<task> --no-focus
#    from the JSON take .result.workspace.workspace_id and .result.root_pane.pane_id

# 2. Claude in this pane, role model — Sonnet 5
# agent name: [a-z][a-z0-9_-]{0,31}
herdr agent start dev-<task> --kind claude --pane <pane_id> -- --model sonnet  # role on Sonnet 5

# 3. the role and the request in one delivery
~/.claude/hooks/herdr-handoff.sh --no-clear <pane_id> agent-developer "[DEV REQUEST] ..."
```

`<task>` is a short task slug (`task-1-forgot-password`), also used in the agent
name. The label is already set at creation, so the "Name your space" step
changes nothing for the implementer.

**Lifecycle.** The instance lives while the "implementation → review →
review fixes" cycle runs: send fixes for a `[REVIEW RESULT]` as the same `[DEV REQUEST]`
to the same pane — the task context is there. When the PR is handed to the user and no fixes
are expected — `herdr workspace close <workspace_id>`: close only what you
created yourself (the herdr skill — safety rules). Do not touch the worktree and branch, the PR
needs them. Without the user's instruction — only the shared `Developer`/`Developer-N`.


### Request

```
[DEV REQUEST]
Plan: ~/.claude/plans/<plan>.md
Task: ClickUp <task-id>          # or ticket/plan, or "none"
Repo: acme-api                   # where to work, if not obvious from the plan
From: w7:p2                      # your own $HERDR_PANE_ID — where to send the result
Focus: postgres side only   # optional — narrow/confirm scope
```

- **Only an agreed plan.** Not a one-line "do X" — the plan must already
  exist (a file in `~/.claude/plans/`, a plan that changes architecture says so)
  and, if it is a TDD task, contain a tests section. No plan — write
  it first, then hand it over.
- **`From`** is mandatory — without it the implementer does not know where to return the result,
  and it will stay in its own chat, where the requesting agent will not see it.
- **`Repo`** — if the plan does not name the repository unambiguously (cross-repo
  tasks, a plan in the shared `~/.claude/plans/`).

## Implementer's work (Developer)

1. Read the plan at the path from `Plan`. The plan is the specification; if during
   implementation an architectural decision surfaces that the plan does not cover
   (not "what to name the method" but "how to do it at all") — do not invent it, write
   the question to the `From` pane and wait for an answer instead of guessing.
2. The checkout is shared — work in a separate git worktree
   (work in a worktree, not the shared checkout), not in the main checkout: adjacent
   sessions stash other people's changes. Create the worktree with one command, not by hand:
   `wt-new <repo> <task> --branch <branch>` (fetch, a new branch from fresh
   `origin/develop` or an existing one from origin, `node_modules` via pnpm;
   the last output line is the path). All worktrees — only in
   `{{PROJECT_ROOT}}/.worktrees/<short>-<task>`: not inside the repository,
   not next to the checkout and not in an agent's temporary/private folder. Do not
   symlink the main checkout's `node_modules`. After switching branches in the worktree —
   `wt-install`. The path must
   be such that any other agent on this host (the reviewer, a second
   Developer request) can enter it simply by the path from the report — not search through
   a specific session's private `/tmp`/home directories.
3. TDD strictly per the plan's "Tests" section: first RED (tests fail on the current
   code — verify it, do not just write them and trust), then the minimal
   implementation until GREEN, only then refactor under green tests.
   Take a baseline (what was green/red before the changes) and compare it with what the
   plan says about the existing state — if it diverges, the plan may be
   stale; report it in the answer instead of silently adapting.
4. Tick the plan's checkboxes as you go (the file on disk, edit
   directly) — not at the end: the plan is synced between machines, another agent
   may pick it up.
5. Follow the target repository's `CLAUDE.md`/`AGENTS.md`: session log in
   `logs/`, pre-commit hooks, PR template (the PR body follows the repo template).
6. Commit → push the branch → `gh pr create --draft` with a body per
   `.github/pull_request_template.md`. **Always draft**
   (keep the PR draft until local rounds are finished): GitHub review bots (Bugbot and others) burn
   the limit on ready PRs, while the local `agent-review` finds the same things earlier.
   Ready (`gh pr ready`) is taken by the requesting agent / PM **only after**
   a clean local review round — not by Developer. **Do not merge yourself**
   (do not merge or approve your own PR) and do not request review yourself on the user's behalf — that is
   decided by the requesting agent or the user.
7. **Self-check before `[DEV RESULT]`, and again after every fix round.** These are the
   most frequent `agent-review` findings: the reviewer catches them, the author did not.
   Go through the final diff (`git diff --stat origin/{{PROJECT_BASE_BRANCH}}...`, then
   per file), not through memory of what you meant to do:
   - PR body and QA steps: every claim matches the **final** diff, not the first
     iteration; after a fix round the body is updated too (the PR body must match the final diff);
   - comments, JSDoc and `docs/**` next to every changed place still say the truth
     (update comments next to the change);
   - the same fix in sibling branches and copies: the other path (standard vs custom,
     list vs drawer, the second copy of a SQL const) — `rg` for the pattern;
   - tests check behavior, not the mock chain or SQL substrings
     (a test must not only mirror the implementation);
   - a check and a write that depend on each other: one transaction or the condition
     inside the `UPDATE ... WHERE`, not a separate SELECT first;
   - migrations must be idempotent, and you check that idempotency before the result:
     a second run is a no-op (guards for existing columns, indexes, and rows). Also
     follow the repo README (online DDL).
   Fix what you find before the result, not as a note in it.

## Reply

When everything is ready — the implementer **itself**, without waiting to be polled, sends the result to the pane
from `From`:

```bash
~/.claude/hooks/herdr-pane-send.sh <pane_id from From> "[DEV RESULT] Plan: <plan>.md

PR: https://github.com/{{PROJECT_GIT_ORG}}/<repo>/pull/NNN (draft)
Worktree: .worktrees/api-cache (branch feat/...)
Tests: RED confirmed (N failing before implementation) → GREEN (N passed)
Plan checklist: closed / partially (what is left and why)
Deviations from the plan: ... (or "none")"
```

In `[DEV RESULT]` explicitly write `(draft)` next to the URL: the requester must not
take the PR out of draft before a clean `[REVIEW RESULT]`.

Via the helper, not a bare `pane send-text` + `send-keys Enter` pair: with Cursor, after that pair
a copy of the text stays in the input field and gets glued to the next message to this pane.
The helper sends `herdr agent prompt`, and on `agent_not_ready` (a pane without a named
agent, e.g. mimo) falls back to send-text.

`--wait` is not needed — the requesting agent decides itself what to do with the result
(request review, rework, report to the user). The same text remains in the
implementer's chat — the user can read it there too.

If a blocking question arises during implementation (an architectural
fork, the plan diverges from the current code) — do not wait until the end: `[DEV
BLOCKED]` to the same `From` pane with a concrete question, plan status as is.

## After DEV RESULT — what the requesting agent does

As soon as `[DEV RESULT]` arrives with PR link(s) — without waiting for
the user to ask, immediately (if the task has a ClickUp ticket):

1. Two short comments on the task: one with the PR link(s) (and the deploy order,
   if there are several PRs and they depend on each other), the second — QA steps
   in plain English, with no technical breakdown. Format — `clickup-comments-two-short`
   (exactly two comments, no more).
2. `[REVIEW REQUEST]` to `Review` for each PR — the plan and order are the same as
   in "How to hand over a plan for implementation" of this skill.

This is not the implementer's work (Developer in another worktree may not know about the
ClickUp ticket and the comment convention) — both steps are done by the requesting agent
that received `[DEV RESULT]`. Both steps may be skipped only if the task is not
linked to ClickUp or the user explicitly asked otherwise.

## Boundaries

- Do not expand the plan's scope on your own initiative (extra tests, refactoring
  nearby, "fixed while I was at it") — the plan outlines this explicitly
  (do not split one finding into scope nits — the same logic in reverse: do not
  do anything beyond what was asked).
- Reviewing your own work does not count as review: after the push the PR goes to `Review`
  (`[REVIEW REQUEST]`), not "I reread the diff". Run tests for your own task
  yourself, but the baseline and the full suite run — `[QA REQUEST]` to QA; the stand —
  `[DEVOPS REQUEST]` to DevOps; database queries — `[DB REQUEST]` to DB.
- In GitHub and ClickUp — only what the plan/user asked for: the PR and, if the plan provides for it,
  comments per the convention (follow the repo's post-PR checklist,
  two short tracker comments, PR links and QA steps). Nothing beyond — do not post to GitHub or the tracker unless asked.
- Approval and merge are not yours (do not merge or approve your own PR).
- Do not call `gh pr ready` — draft holds the local review rounds; ready
  is taken by the requester / PM after `Verdict: ok`/`minor-only`
  (keep the PR draft until local rounds are finished).
- Do not apply migrations yourself (do not apply migrations from an open PR).
