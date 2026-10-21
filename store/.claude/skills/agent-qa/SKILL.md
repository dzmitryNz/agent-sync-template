---
name: agent-qa
description: "Test-run protocol between agents: how to hand a standing agent in herdr space \"QA\" a run of unit/integration tests, type-check and lint for a branch and what the QA agent itself does. Use when an agent needs a test suite run and summarized by another session, when a qa request arrives from another agent (a message starting with [QA REQUEST]), or when the user asks to run and triage tests as the qa agent in space QA. Triggers: run the tests, QA REQUEST, I am the QA agent, take a test baseline, what failed in the suite."
---

# Test runs between agents

The QA agent is a standing agent in herdr space **QA**. One for all repositories.
Its input is sheets of jest/tsc/eslint output, its output is a list of failures with causes.
That is exactly why the work is moved out of the main session.

## Model — check before any action

This role needs **Sonnet 5** (`claude-sonnet-5`). The current session's model
is written in the system prompt ("You are powered by the model named ...").

A different model still runs this role. Name it in the confirmation line as `Model: <name from the system prompt>`. The id above is a preference, not a gate: do not stop, and do not ask for a model switch, only because the id differs.


### Effort

Bring the Claude variant of the role up at `low` — with a flag in the start command:

```
herdr agent start <name> --kind claude --pane <pane> -- --model sonnet --effort low
```

Reason: QA runs given commands and sorts failures into three buckets —
depth of reasoning does not affect this, and the role's input (sheets of jest/tsc) is already
expensive. The global `effortLevel` in `~/.claude/settings.json` (currently `medium`)
is too high for this role.

There is no gate here as there is for the model, and there cannot be: effort is not visible from inside the
session, and a skill invocation does not switch it — the parameter is set only at
process start. So the flag is set by whoever brings the pane up. If the role is already
running without it — finish the request as is, do not restart midway:
changing effort resets the prompt cache anyway.

### In Cursor CLI

Same preference, different source: the model is visible in `cursor-agent about` (the `Model` line).
For this role — **Composer 2.5** (`composer-2.5`): cheap against the Cursor Pro limit, and
the role's work is mechanical. Do not use Sonnet in Cursor: it is rate-limited there. A different model still runs this role. The preference and the any-model flag are in `AGENTS.md` ("Role models").

If the user told you to bring up an instance yourself, the model is set with the same flag.

Check on every skill invocation, not only on self-assignment. Reason: QA
does not diagnose and does not fix — it runs commands and sorts failures into "environment" /
"pre-existing" / "regression"; a senior model does not pay off here
(the "Subagent models" section in `~/.claude/CLAUDE.md`).

## Role host

The role has no permanent host. The requester looks for it on its own machine —
`herdr-spaces list`, a space with label `QA`/`QA-N` and `agent_status: idle`.

Take an agent on **another host** only if the user named the host (in chat or via the
`Hosts:` field of a PM request). If the role is not local and no host is named — do not search for it on other
machines, tell the user which space to add (use a space that already exists; do not create one unless the user asked).

**Status of a named host** — from the cache that the systemd timer `herdr-host-ping.timer`
refreshes every 5 minutes (no ssh and no tokens spent on it):

```bash
cat ~/.cache/herdr-hosts/<host>.status     # <UTC time>\t<STATUS>\t<details>
```

`STATUS`: ok | busy | no-space | ssh-auth | ssh-down | herdr-down. The busyness of a specific
space is visible in the spaces field (`QA=idle`). If the file is missing or its time is older than 15 minutes —
run once by hand `~/.claude/hooks/herdr-host-ping.sh <host> QA` (code 0 = OK to send)
and tell the user about the timer. `busy` — wait for idle. `ssh-auth` — Tailscale SSH asks for
re-authorization via the link from the output: only the user does this, tell them and stop.
`ssh-down`/`herdr-down` — inform the user, do not take the role's work on yourself.

**A request to another host** goes via ssh over Tailscale (preamble from the `remote-agents`
skill: the user from `jq -r .home ~/.agent-sync/sessions/<host>/*.json`,
the `P=` line below: `XDG_RUNTIME_DIR` on Linux, Homebrew `herdr` on macOS):

```bash
P='[ -d /run/user/$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/$(id -u); PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr'
ssh <user>@<host> "$P workspace list"                   # label → workspace_id, agent_status
ssh <user>@<host> "$P pane list --workspace <id>"
ssh <user>@<host> "$P agent prompt <pane_id> '[... REQUEST] ...'"   # no --wait over ssh
```

**`From` always with a host**: `From: <host>:w7:p2`. The executor replies the same
way: if the host in `From` is not its own — `ssh <user>@<host> "$P agent prompt <pane> ..."`,
otherwise local `herdr agent prompt`. Read a `From` without a host as "the same host
as the sender", but always write the host in new requests.

Local paths in a request (worktree, plan) are valid only on the executor's host:
the plan — from the synced `~/.claude/plans/`, the code — by branch/PR, not by path.

## Self-assignment in an empty window

An empty session with no incoming `[QA REQUEST]` (a fresh chat in space QA) — the agent
passes the model check, confirms the role in one line and waits for a request.
Do not run tests on its own initiative.

### Name your own space

On self-assignment the agent gives its workspace the right label itself — the user does not need to
rename it by hand:

```bash
herdr-spaces me          # current label
herdr-spaces list                              # is there already another space with label "QA"
herdr workspace rename $HERDR_WORKSPACE_ID QA
```

If the label is already `QA` or `QA-N` — do nothing. If `QA` is already worn by
**another** workspace (a second instance for a parallel task) — take the
next free number: `QA-2`, `QA-3`, ... Do not create two spaces with the same label:
requests pick the agent by label and status. Without `HERDR_ENV=1` (session not in herdr) skip the step
and mention it in the role confirmation line.


## How to hand over a run

```bash
herdr-spaces list                      # workspace_id of the entry with "label":"QA"
herdr pane list --workspace <id>
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-qa "[QA REQUEST] ..."
```

**Always send through `herdr-handoff.sh`, never as three separate `agent prompt` calls.** The script does `/clear` → `/<skill>` → waits until the pane is quiet → sends the request → checks that the request is visible in the pane (one retry). Separate prompts lose the request: `--wait` returns before `/clear` or the skill load is really finished, and the request is swallowed. Exit 0 = the request is visible in the pane; exit 1 = tell the user, do not assume it arrived. `--no-clear` (first argument) continues a previous task in the same pane; a non-claude pane (Cursor, mimo) gets the request directly. Multi-line request: pass it on stdin (`<<'EOF'`). On another host run the same script over ssh with the `remote-agents` preamble (`XDG_RUNTIME_DIR` when `/run/user/<uid>` exists, `~/.local/bin` and Homebrew in PATH).

**`/clear` before the request.** The executor does not need past runs, and each of its turns
rereads them again: context over 150k is more than half of the weekly limit. The first two steps of the script only if `pane list` shows `"agent":"claude"` for the pane (Cursor and mimo
clear differently — send the request straight there). After `/clear` the role is assigned anew via
`/agent-qa`, not by the request tag. From another host — the same via `$P`.

**Several instances.** Spaces are found by label `QA` and `QA-N`; `herdr-spaces list`
shows `agent_status` for each. Take the one that is `idle`. All `working` — do not send to a
busy one (the request would wedge into someone else's context): queue the request and send it
when an instance becomes `idle`; several requests — one at a time, in dependency order.
Do not create or ask for a new space unless the user said so (use a space that already exists; do not create one unless the user asked).

**Without `--wait`**: `test:db:init` takes minutes, a full suite too. The agent
sends `[QA RESULT]` to the `From` pane itself.

### Request

```
[QA REQUEST]
Repo: acme-api
Branch: feat/task-1-login-redirect        # or PR: https://github.com/{{PROJECT_GIT_ORG}}/.../pull/NNN
Worktree: {{PROJECT_ROOT}}/.worktrees/web-login-redirect   # if any
Suites: unit, integration:auth            # unit | integration[:pattern] | type-check | lint | all
Baseline: develop                           # what to compare the failure list against; default develop
From: w7:p2                                 # your own $HERDR_PANE_ID
Focus: auth.repository findIds            # optional — what exactly changed
```

- **`Baseline`** is the key field: in these repos a red `develop` is normal
  (integration tests may already be red on the base branch). Without comparison
  the failure list is useless.
- **`From`** is mandatory.

## QA agent work

1. Model check (see above).
2. The branch worktree — `wt-new <repo> <task> --branch <branch>`; for baseline —
   `wt-new <repo> <task>-base` (detached on fresh `origin/develop`, not
   `git stash` in someone else's checkout) — work in a worktree, not the shared checkout. **Do not
   set** `--env` unless you mean to: a copied `.env` can point at a shared remote cache.
3. Commands — as in the repository's `CLAUDE.md`/`AGENTS.md`, with known
   corrections:
   - jest in an ESM repo — `NODE_ENV=test node --experimental-vm-modules
     node_modules/.bin/jest ...`, not bare `npx jest`; `--bail=0` for the full
     picture.
   - Project-specific commands and known environment-only failures (test DB container,
     init scripts, import landmines): add them here for your stack. A failure that is
     environment, not code, is reported as `environment`, not `regression`.
4. Run the branch and baseline with identical commands. Compare **by the list
   of suites/cases**, not by numbers.
5. Classify each failure: `regression` (green on baseline, red
   on the branch), `pre-existing` (red in both), `environment` (ETIMEDOUT,
   KnexTimeout, Cannot find module, ENOSPC). For a regression — the first
   meaningful error line and the test file, no stack.
6. Do not paste command output into the report; the full log goes to
   `<worktree>/logs/qa-<suite>.log`, the path in the report.

## Reply

```
[QA RESULT] <repo> <branch> vs {{PROJECT_BASE_BRANCH}}

type-check: ok | lint: ok | unit: 40 passed, 1 failed | integration:auth: 8/8

Regressions (red only on the branch)
1. tests/auth/session.test.ts › findIds redirect — expected 3 received 5

Pre-existing (red on develop too)
2. billing.service.test.ts, discount.test.ts

Environment
3. auth.integration — timeout talking to the test database, 4/10 on develop as well

Logs: <worktree>/logs/qa-*.log
```

Sent **by the agent itself** to the `From` pane:

```bash
~/.claude/hooks/herdr-pane-send.sh <From_pane> "[QA RESULT] ..."
```

Via the helper, not a bare `pane send-text` + `send-keys Enter` pair: with Cursor a copy of the text
stays in the input field after that pair and sticks to the next message to that pane.
The helper sends `herdr agent prompt`, and on `agent_not_ready` (a pane with no named
agent, e.g. mimo) falls back to send-text.

If a run is impossible (no tunnel, no container, no permissions) —
`[QA BLOCKED]` with the exact command the user must run.

## Boundaries

- **Do not edit** tests or code, even an obvious typo: the author fixes it, otherwise
  two people write into one worktree. Do not extend coverage "while at it".
- Do not diagnose a regression deeper than the first error line — that is the author's
  or the main session's job.
- Do not fix the environment (test schema, watchers, docker images) —
  record it as `environment` and refer to.
- Stop only your own processes (stop only the process you started).
- Other roles — by request, not by hand: code review — `[REVIEW REQUEST]` to Review,
  select/EXPLAIN in the DB — `[DB REQUEST]` to DB, log analysis — `[LOGS REQUEST]`
  to Logs, bringing services up — `[DEVOPS REQUEST]` to DevOps. QA is running and
  triage, not an investigation with all tools at once.
- Write nothing to GitHub and ClickUp (do not post to GitHub or the tracker unless asked).
