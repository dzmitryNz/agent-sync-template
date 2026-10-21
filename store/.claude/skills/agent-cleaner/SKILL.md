---
name: agent-cleaner
description: "Worktree cleanup protocol between agents: how to hand a standing agent in herdr space \"Cleaner\" the audit and removal of finished git worktrees across all of {{PROJECT_ROOT}} (or another checkout root) and what the cleaner agent itself does. Use when an agent needs stale/finished git worktrees audited and safely removed without pulling git-status noise into its own context, when a cleaner request arrives from another agent (a message starting with [CLEANER REQUEST]), or when the user asks to clean up all worktrees / finished tasks across the monorepo. Triggers: clean worktrees, remove finished branches, CLEANER REQUEST, I am the cleaner agent, worktree audit."
---

# Worktree cleanup between agents

The Cleaner agent is a standing agent in herdr space **Cleaner**. Its input is the whole
sprawl of `git worktree list` across dozens of {{PROJECT_NAME}} repositories, its output is what was
removed and what was kept, with reasons. That is why it is moved out of the main
session: the sweep itself is expensive in context (many `git status`/`gh pr list`), and
the result is three lines.

## Model — check before any action

This role needs **Sonnet 5** (`claude-sonnet-5`). The current session's model
is written in the system prompt ("You are powered by the model named ...").

A different model still runs this role. Name it in the confirmation line as `Model: <name from the system prompt>`. The id above is a preference, not a gate: do not stop, and do not ask for a model switch, only because the id differs.


### Effort

Bring the Claude variant of the role up at `low`:

```
herdr agent start <name> --kind claude --pane <pane> -- --model sonnet --effort low
```

Reason: the work is classification (primary / devops-stand / develop / task-worktree,
dirty / ahead / PR open|merged) and removal by checklist, not investigation.
The global `effortLevel` (usually `medium`) is too high for this role. Effort cannot be
switched from inside the session — the parameter is set by whoever brings up the pane; if the
role is already running without it, finish the request as is.

Model preference and the optional `~/.cache/agent-roles/any-model` flag are in `AGENTS.md` ("Role models").


## Role host

The role has no permanent host. The requester looks for it on its own machine —
`herdr-spaces list`, a space with label `Cleaner`/`Cleaner-N` and `agent_status: idle`.

Take an agent on **another host** only if the user named the host (in chat or via the
`Hosts:` field of a PM request). If the role is not local and no host is named — do not search for it on other
machines, tell the user which space to add (use a space that already exists; do not create one unless the user asked).

**Status of a named host** — from the cache that the systemd timer `herdr-host-ping.timer`
refreshes every 5 minutes (no ssh and no tokens spent on it):

```bash
cat ~/.cache/herdr-hosts/<host>.status     # <UTC time>\t<STATUS>\t<details>
```

`STATUS`: ok | busy | no-space | ssh-auth | ssh-down | herdr-down. The busyness of a specific
space is visible in the spaces field (`Cleaner=idle`). If the file is missing or its time is older than 15 minutes —
run once by hand `~/.claude/hooks/herdr-host-ping.sh <host> Cleaner` (code 0 = OK to send)
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

An empty session with no incoming `[CLEANER REQUEST]` — the agent passes the model
check, confirms the role in one line, names its workspace `Cleaner`
(`herdr workspace rename $HERDR_WORKSPACE_ID Cleaner`, next free
number `Cleaner-2` if the label is taken by another space) and waits for a request. Do not clean
on its own initiative.

**Strict rule — the user types `/agent-cleaner` with no request:**
do not ask for confirmation. Rename the current workspace to `Cleaner` even if its label is
something else (for example the project name), and immediately clean all task worktrees under
`{{PROJECT_ROOT}}` (Scope: all task worktrees). The user's `/agent-cleaner` is the request.
All safety checks below (dirty, ahead, open PR, no `--force`) still apply.

## How to hand over a cleanup

```bash
herdr-spaces list                      # workspace_id of the entry with "label":"Cleaner"
herdr pane list --workspace <id>
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-cleaner "[CLEANER REQUEST] ..."
```

**Always send through `herdr-handoff.sh`, never as three separate `agent prompt` calls.** The script does `/clear` → `/<skill>` → waits until the pane is quiet → sends the request → checks that the request is visible in the pane (one retry). Separate prompts lose the request: `--wait` returns before `/clear` or the skill load is really finished, and the request is swallowed. Exit 0 = the request is visible in the pane; exit 1 = tell the user, do not assume it arrived. `--no-clear` (first argument) continues a previous task in the same pane; a non-claude pane (Cursor, mimo) gets the request directly. Multi-line request: pass it on stdin (`<<'EOF'`). On another host run the same script over ssh with the `remote-agents` preamble (`XDG_RUNTIME_DIR` when `/run/user/<uid>` exists, `~/.local/bin` and Homebrew in PATH).

**`/clear` before the request.** The executor does not need past cleanups, and each of its turns
rereads them again: context over 150k is more than half of the weekly limit. The first two steps of the script only if `pane list` shows `"agent":"claude"` for the pane (Cursor and mimo
clear differently — send the request straight there). After `/clear` the role is assigned anew via
`/agent-cleaner`, not by the request tag.

### Request

```
[CLEANER REQUEST]
Root: {{PROJECT_ROOT}}             # default, can be narrowed to one repo
Scope: all task worktrees                  # or a specific list of paths
From: w7:p2                                # your own $HERDR_PANE_ID
```

## Cleaner agent work

### 1. Reconnaissance — one pass

```bash
for repo in "$ROOT"/*/; do
  name="${repo%/}"; name="${name##*/}"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 && \
    git -C "$repo" worktree list 2>/dev/null | tail -n +2
done | sort -u
```

Normalize the list by path (one line per worktree; repeats from different
`repo` entries are duplicates of one record, not different worktrees).

### 2. Path classification — what not to touch at all

- **Primary checkout** — the one the list is derived from (`.git` is a real
  directory, not a pointer file). Never removed by this skill — it is not
  a worktree but the repository itself.
- **`*-devops-stand`, `*-develop`** (or any suffix denoting a permanent
  stand/base rather than a task) — permanent infrastructure, not a
  disposable task worktree. Do not touch.
- **`~/.cursor/worktrees/...`** — belongs to Cursor, not our tool.
  Do not touch.
- **`~/.claude/jobs/.../tmp/...`** — a Claude Code background job's worktree;
  if the job may still be active — do not touch, ask the user.
- Everything else is a task worktree: a removal candidate.

### 3. Checking each task worktree

For each candidate — **in one pass**, not one `git status` at a time
(reconnaissance in one go, see `~/.claude/CLAUDE.md`):

```bash
git -C "$wt" status --short --branch    # dirty? which branch, ahead/behind
```

- **Dirty** (there are `M `/`A `/`D ` in the output, not only `??`) — **do not remove**.
  This is someone else's uncommitted work.
- **`??` only on `node_modules`/`dist`/`logs/*.log`/other obvious build or
  debug junk** — does not block removal in substance, but `git worktree
  remove` will require `--force`. `--force` is an irreversible local deletion,
  and under the auto mode classifier it will not pass without the user's explicit permission:
  do not force such cases yourself, put them in the report as a separate item
  "junk, needs --force" and ask.
- **`[ahead N]`** — there are unpushed commits. **Do not remove**, put it in the
  report with those commits (`git log origin/<branch>..HEAD --oneline`).
- **Clean, pushed** (`[behind N]` is not a problem, it just lags
  origin) — safe to remove *by git state*. Next comes the ownership check.

### 4. Ownership / task status check

Before removing a clean and pushed worktree:

- If the branch looks like a ClickUp task (prefix `TASK-123` in the name) — check
  the PR: `gh pr list --repo {{PROJECT_GIT_ORG}}/<repo> --head <branch> --json number,state,title`.
  **PR open** — do not remove, the task may not be finished (example from
  practice: the worktree was clean and pushed, but the PR was still open and it was
  the active work of a Developer agent). PR merged / no PR at all, but the branch
  is pushed and clean — can remove; removing the worktree touches neither
  the branch on GitHub nor the PR (do not delete a branch that still has an open PR — the worktree
  is removed after review regardless of whether it was merged).
- If the request came from someone who does not own the task (a `[CLEANER REQUEST]`
  from another agent) — the request may contain an explicit "keep, I will remove it myself" for
  a specific path; do not touch such paths even if they are safe by git
  state.

### 5. Removal — one at a time, not in a batch

`git worktree remove` in a loop over several paths in one command goes to the
auto mode classifier as "Irreversible Local Destruction" and is blocked
entirely, even if each individual command is safe. Remove **one
command per call**:

```bash
git -C <primary-repo> worktree remove <path>
```

Do not wrap it in a `for`/function in a single Bash call — the classifier sees
the whole block at once.

### 6. Reply

```
[CLEANER RESULT] {{PROJECT_ROOT}}

Removed (14): <repo>-<task-id>-<slug>, ...

Kept — active work (2):
- <repo>-<task-id> — PR #NNN open
- .worktrees/<short>-<task> — 1 unpushed commit

Kept — dirty (1):
- .worktrees/<short>-<task-id>-<slug> — 4 files of edits

Needs --force (user decides) (2):
- <repo>/.worktrees/pr101, .worktrees/pr98 — only node_modules
```

Sent **by the agent itself** to the `From` pane:

```bash
~/.claude/hooks/herdr-pane-send.sh <From_pane> "[CLEANER RESULT] ..."
```

Via the helper, not a bare `pane send-text` + `send-keys Enter` pair: with Cursor a copy of the text
stays in the input field after that pair and sticks to the next message to that pane.
The helper sends `herdr agent prompt`, and on `agent_not_ready` (a pane with no named
agent, e.g. mimo) falls back to send-text.

## Boundaries

- Never `--force` and never `rm -rf` a worktree directory directly — only
  `git worktree remove` without `--force`; force is the user's decision.
- Never touch the primary checkout, `-devops-stand`, `-develop`,
  `.cursor/worktrees`, `.claude/jobs/.../tmp`.
- Never remove a dirty or ahead-unpushed worktree.
- Never remove a task worktree with an open PR without explicit confirmation
  that the task is in fact finished.
- Do not touch branches/PRs on GitHub with this skill — only the local worktree.
- Write nothing to GitHub and ClickUp (do not post to GitHub or the tracker unless asked).
