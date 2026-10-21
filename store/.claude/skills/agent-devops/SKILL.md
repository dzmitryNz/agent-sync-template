---
name: agent-devops
description: "Stand protocol between agents: how to ask the standing agent in herdr space \"DevOps\" to start/stop local {{PROJECT_NAME}} services for verifying a branch and what the stand agent itself does. Use when an agent needs local services started or stopped by another session, when a devops request arrives from another agent (a message starting with [DEVOPS REQUEST]), or when the user asks to run the stand as the devops agent in space DevOps. Triggers: start the stand, bring services up, stop the stand, DEVOPS REQUEST, I am the devops agent, run a branch locally."
---

# Stand between agents

The stand agent is a standing agent in the herdr space **DevOps**. One for all
repositories. Its work is noisy (logs of `npm install`, builds, starts, ENOSPC,
port hunting) and requires almost no judgment — so it is moved out of the main session.

`standctl` runs on Linux and WSL only (it uses `ss`, `/proc` and `setsid`). On macOS this
role has no stand to run.

## Model — check before any action

This role requires **Sonnet 5** (`claude-sonnet-5`). The current session's model
is stated in the system prompt ("You are powered by the model named ...").

A different model still runs this role. Name it in the confirmation line as `Model: <name from the system prompt>`. The id above is a preference, not a gate: do not stop, and do not ask for a model switch, only because the id differs.


### Effort

Run the Claude variant of the role at `low` — via a flag in the start command:

```
herdr agent start <name> --kind claude --pane <pane> -- --model sonnet --effort low
```

Reason: starting and stopping services per the protocol described here is mechanics,
the spend goes to noisy `npm` and start output, not to reasoning. The global
`effortLevel` in `~/.claude/settings.json` (currently `medium`) is too high for this role.

There is no gate here as there is for the model, and there can't be: effort is not visible from inside
the session, and invoking a skill does not switch it — the parameter is set only at
process start. So the flag is set by whoever starts the pane. If the role is already
running without it — finish the request as is rather than restarting midway:
changing effort resets the prompt cache anyway.

### In Cursor CLI

The same preference, a different source: the model is visible in `cursor-agent about` (the `Model` line).
For this role — **Composer 2.5** (`composer-2.5`): cheap against the Cursor Pro limit, and
the role's work is mechanics. Do not use Sonnet in Cursor: it is rate-limited there. A different model still runs this role. The preference and the any-model flag are in `AGENTS.md` ("Role models").

If the user told you to start an instance yourself, the model is set with the same flag.

The check runs on every invocation of the skill, not only on self-assignment:
the model may have been switched between requests. Reason: stand tasks are running
commands and summarizing logs, a senior model adds nothing here, and its input
costs 5x more (section "Subagent models" in `~/.claude/CLAUDE.md`).

## Role host

The role has no permanent host. The requester looks for it on its own machine —
`herdr-spaces list`, a space with label `DevOps`/`DevOps-N` and `agent_status: idle`.

The role's resources (browser, DB tunnels) are not set up on every
machine: if they are missing here, the executor replies `[* BLOCKED]` with what is missing, and the
user decides on which host to start the role.

Take an agent on **another host** only if the host was named by the user (in chat or via the
`Hosts:` field of a request from PM). If the role is not available locally and no host is named,
do not search other machines; tell the user which space to add (use a space that already exists; do not create one unless the user asked).

**Status of a named host** — from the cache that the systemd timer `herdr-host-ping.timer`
refreshes every 5 minutes (no ssh or tokens are spent on it):

```bash
cat ~/.cache/herdr-hosts/<host>.status     # <UTC time>\t<STATUS>\t<details>
```

`STATUS`: ok | busy | no-space | ssh-auth | ssh-down | herdr-down. The busyness of a specific
space is visible in the spaces field (`DevOps=idle`). If the file is missing or its time is older than 15 minutes —
run `~/.claude/hooks/herdr-host-ping.sh <host> DevOps` by hand once (exit code 0 = OK to send)
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

**`From` always includes the host**: `From: <host>:w7:p2`. The executor replies the same
way: if the host in `From` is not its own — `ssh <user>@<host> "$P agent prompt <pane> ..."`,
otherwise a local `herdr agent prompt`. Read a `From` without a host as "the same host
as the sender", but always write the host in new requests.

Local paths in the request (worktree, plan) are valid only on the executor's host:
the plan comes from the synced `~/.claude/plans/`, the code — by branch/PR, not by path.

## Self-assignment in an empty window

If the skill is invoked in an **empty session** — no incoming `[DEVOPS REQUEST]` and
no other task in the context (a fresh chat in space DevOps) — the agent passes the
model check, confirms the role in one line and waits for a `[DEVOPS REQUEST]`
in this same pane. Start nothing on its own initiative.

A non-empty context (history, incoming `[DEVOPS REQUEST]`/`[DEVOPS STOP]`,
an ordinary invocation by the user) is the working branch of the protocol below.

### Name your space

On self-assignment the agent gives the workspace the right label itself — the user does not need to
rename it by hand:

```bash
herdr-spaces me          # current label
herdr-spaces list                              # is there already another space with label "DevOps"
herdr workspace rename $HERDR_WORKSPACE_ID DevOps
```

If the label is already `DevOps` — do nothing. If `DevOps` is already held by **another**
workspace on this same machine — do not rename and tell the user: there is one stand
agent per host, a second one would fight for ports and other people's processes. A number
(`DevOps-2`) — only when it is a different host. Without `HERDR_ENV=1` (the session is not in herdr) skip
the step and mention this in the role's confirmation line.


## How to ask for a stand

```bash
herdr-spaces list                      # workspace_id of the entry with "label":"DevOps"
herdr pane list --workspace <id>          # the pane with the agent (one per workspace)
herdr agent prompt <pane_id> "[DEVOPS REQUEST] ..."
```

**One instance per machine.** The stand agent owns the ports, pid files and the knowledge of which process is whose; a second DevOps on the same host means two claimants for a port and a return to killing a process that is not yours (stop only the process you started). If its `agent_status` in `herdr-spaces list` is `working`, that is a hard stop: wait for `idle` (`herdr agent wait <pane_id> --until idle --timeout 600000`), do not open `DevOps-2` and do not start services yourself. `DevOps-N` is allowed only on another host.

**Without `--wait`**: starting the stack with dependency installation and the frontend build does not
fit in the timeout. The agent sends `[DEVOPS RESULT]` to the `From` pane itself.

### Request

```
[DEVOPS REQUEST]
Services: <repo>@<branch>, <repo>@{{PROJECT_BASE_BRANCH}}
Worktree: {{PROJECT_ROOT}}/.worktrees/<short>-<task>   # if it already exists; otherwise it creates one itself
DB: <mode>                        # one of STAND_DB_MODES from stand-project.sh; default STAND_DEFAULT_DB
From: w7:p2                      # your own $HERDR_PANE_ID — where to send the result
Purpose: manual check of <feature>   # optional
```

- **`Services`** — which **branches with changes** to start (`repo@branch` or
  `repo@branch@sha`). This is **not** the full list of processes: a request to "deploy
  branches / PR / changes for the task" **always** means a stand on which the feature
  can be verified **end to end** (login → UI/API path → dependent
  backends). The listed repositories pin branches; the rest is filled in by the stand
  agent itself (see "E2E set" below). `@develop` — fresh develop for
  dependencies without their own branch. **DB:** all started backends on a single target
  from `DB`; do not mix environments.
- **`From`** is mandatory — otherwise the report stays in the stand agent's chat.
- Stopping — `[DEVOPS STOP]` with the same `Services` (or `all mine`) and `From`.

### E2E set (must be filled in)

If asked to deploy branches / PRs / "changes for the task" — do **not** start
only the named repositories. The goal of the stand is to walk through the scenario fully.
In `[DEVOPS RESULT]` list the **whole** started set (and SHAs), not only the
branches from `Services`. If something from the E2E set did not start — a line in "Did not start",
not a silent skip.

Which services make up "the whole scenario" is a property of your project. The template
cannot know it; the section "Project stand map" below is where the answer lives, and
`stand-project.sh` is its machine-readable twin. Until both are filled in, the stand agent
replies `[DEVOPS BLOCKED] stand map not written` and does not guess.

### Writing the project stand map yourself

Do this once, as the stand agent or as the user, in a session that may read the whole
`PROJECT_ROOT`. Write the findings into the "Project stand map" section of this file and
into `stand-project.sh`; keep both short, this is reference, not a tutorial.

1. **List the repositories.** `ls "$PROJECT_ROOT"`, then for each: `package.json`
   (`name`, `scripts.start`, `scripts.build`, `scripts.preview`), `Dockerfile`,
   `docker-compose*.yml`, `Procfile`, `README`. Note the kind: node API, vite frontend,
   worker, PHP, static. Repos with no runnable service (libraries, migrations, infra) go to
   a separate "not a service" list.
2. **Find the port and the health path of each service.** `rg -n 'PORT|listen\(' src`
   and `rg -n "health|/ping|/ready" src` in each repo; `.env.example` / `.env.*` for the
   default port. Pick one health URL per service that returns 200 without auth.
3. **Find what each service needs to start.** `.env.example` is the list of required variables.
   Group them: DB hosts/ports, URLs of other local services (`*_URL`, `VITE_*_DOMAIN`),
   internal tokens between services, feature flags. Variables that name another service
   are edges of the dependency graph: write them down as `service -> depends on`.
4. **Find the DB targets.** Which DB engines (`rg -n "mysql|pg|mongo|redis" package.json`),
   which env variables carry the host/port for each, and which values point at a shared LAN
   host, an ssh tunnel on `127.0.0.1:<port>`, or a local docker. Each distinct way of reaching
   the data is one `DB` mode in `stand-project.sh`. Never copy credentials: only the variable
   names and the local ports.
5. **Walk the login path once by hand.** Start the frontend and the API, log in, and read the
   network tab / API log: every host the browser called after login is a service the stand
   needs for the "logged in, got a working UI" minimum. White screen after login almost
   always means one of these is missing. This gives you the `core` profile.
6. **Group into profiles.** `core` = login minimum; add one profile per typical request
   (`core`, `jobs`, `full`). A profile is a space-separated list of service ids; an
   id equals the repo directory name, aliases go into `canonical_svc_name`.
7. **Record what must not be started.** Watchers (`dev`, `tsx watch`, `vite` dev server),
   scripts that apply migrations or seed, services that write to shared queues or send
   real emails. These go to the "Forbidden" list below, with the reason.
8. **Verify the map.** `standctl preflight --db <mode> --profile core`, then
   `standctl up`, then `standctl status`: every health is 200 and the live `DB_*` of each
   process matches the chosen mode (`stand_verify_env`). Fix the map until this holds on a
   clean machine; only then is the section done.

Keep the map free of secrets and real hosts: variable names, local ports and repository names
only. The shared LAN host comes from `STAND_DB_HOST` in `agent-sync.env`, tunnel ports are
local to the machine, credentials come from the repos' own `.env*` files or
`PROJECT_CREDS_DIR`.

### Project stand map

<!-- EXAMPLE:BEGIN made-up "acme" stack; replace the whole block with the result of the
     procedure above. Put here: the login minimum as a table (role, service id, port, default
     branch), the optional services with the condition under which they are added, the
     dependency notes that are easy to miss, and the "not a service" repos. -->

Minimum for the web UI (`core`), when the request names `acme-web` or `acme-api`, or
`Purpose` is a check in the UI:

| Role | Service | Port | Branch |
|---|---|---|---|
| UI | acme-web | 8080 | from the request, otherwise {{PROJECT_BASE_BRANCH}} |
| API | acme-api | 3000 | from the request, otherwise {{PROJECT_BASE_BRANCH}} |
| Login | acme-auth | 3001 | {{PROJECT_BASE_BRANCH}} unless it has a branch of its own |

Without **acme-auth** the UI does not pass the post-login bootstrap: the web app calls
`VITE_AUTH_API_DOMAIN` right after login, and a missing auth looks like "logged in and got a
white screen".

Added by `Purpose` / plan / PR relations:

- **acme-worker** (`:3002`) — only when the scenario waits for a background job
  (emails, exports, invoices). Reads the same DB as `acme-api`.
- **acme-schema** — check out the branch for comparison; **do not apply migrations/seed**.
  If the needed data is missing in the DB → `[DEVOPS BLOCKED]` with a note for the DB agent.

Not a service: `acme-design-tokens`, `acme-schema`, `infra`.

<!-- EXAMPLE:END -->

## Stand agent's work

The checklist below is **mandatory** on any host (any host). Do not invent
`/tmp/start-*.mjs` and do not copy "how it was yesterday on the other host".

### 0. Preflight (STOP → `[DEVOPS BLOCKED]` if missing)

1. A space with label `DevOps` / `DevOps-N` exists on **this** host and is `idle`. If not —
   BLOCKED `no-space`. **Deploy ≠ stand** (Deploy is for environments; the stand is only for
   DevOps). Do not substitute the space and do not start services in someone else's role.
2. Then — `$HOME/.claude/skills/agent-devops/standctl` (see §2), not manual bash.
3. `PROJECT_ROOT` comes from `~/.agent-sync/agent-sync.env` (`standctl` reads it itself). Hardcoding
   someone else's home is forbidden.
4. DB per the request's `DB` field (`standctl preflight --db …`):

<!-- EXAMPLE:BEGIN made-up "acme" DB modes; one row per mode from STAND_DB_MODES in
     stand-project.sh. Put here: the mode name, the TCP check preflight runs (host:port), and
     which host the backends' DB variables must point at in that mode. Tunnel ports are the
     local ends of your ssh tunnels, not the remote servers. -->
| `DB` | Reachability | Backend env target |
|---|---|---|
| `lan` (default when `STAND_DB_HOST` is set) | TCP `$STAND_DB_HOST:3306`; with `STAND_DB_HOST` empty this mode is an error | DB hosts from `.env.local` → `$STAND_DB_HOST` |
| `dev-tunnel` | TCP `127.0.0.1:<dev tunnel port>` | all backends on the tunnel, **not** `$STAND_DB_HOST` |
| `staging-tunnel` | TCP `127.0.0.1:<staging tunnel port>` | all backends on the tunnel |
<!-- EXAMPLE:END -->

The tunnel is started by the **user**. No TCP → BLOCKED with the exact tunnel command.
Mixing DB targets between services of one stand is not allowed.
Port occupied by someone else's process (cwd ≠ our dir) → BLOCKED, do not kill.

### 1. Worktree

`wt-new <repo> <task> --branch <branch> --env` → a path like
`$PROJECT_ROOT/.worktrees/<short>-<task>` (or the path from the request if the worktree
already exists). Do not touch the main checkout. Its own `node_modules`, a copy of `.env*`.

### 2. Start / restart — only `standctl` (+ `start-svc.mjs` inside)

One CLI for both hosts (lives in the skill, synced by agent-sync). The shared full stand
via `$PROJECT_ROOT/dev-stand/stand.sh` (if your project has one) is a **different** scenario; the agent's task stands
do not go through it.

On PATH via `~/.local/bin/standctl` → the skill (symlink; `standctl` resolves
its directory via `readlink -f`). If the command is missing:  
`ln -sfn "$HOME/.claude/skills/agent-devops/standctl" "$HOME/.local/bin/standctl"`.

```bash
# optional in [DEVOPS REQUEST]: Profile: <one of STAND_PROFILES>  and explicit --svc paths

standctl preflight --db <mode> --profile <profile>
standctl up --db <mode> --profile <profile> --task <task-id> \
  --svc <api service id>=/path/to/api-worktree \
  --svc <web service id>=/path/to/web-worktree
standctl restart <web service id>    # rebuild+preview
standctl restart <api service id>
standctl status                      # health + live DB_*
standctl stop all-mine               # only current.json + pidfile+cwd
```

State: `$PROJECT_ROOT/.stand/current.json`. The low-level backend spawn —
`$HOME/.claude/skills/agent-devops/start-svc.mjs` (called from standctl).

<!-- EXAMPLE:BEGIN made-up "acme" ports; copy the port column of your stand map here, one
     line, so the agent does not open stand-project.sh to answer "what is on :3001". -->
Ports: acme-api `3000`, acme-auth `3001`, acme-worker `3002`, acme-web `8080`.
<!-- EXAMPLE:END -->

**Forbidden** (a frequent cause of "works on one host only"):

- `npm run dev` / `npm run dev:develop` / `dev:staging` / `dev:local`
- `tsx watch`, `vite` (dev server), any file watcher (ENOSPC)
- starting without injecting `.env.local` into the process env (dotenv does **not** override
  variables that are already set; `.env` often points to a different DB target)
- ad-hoc `/tmp/start-*.mjs` and manual bash instead of `standctl`

Frontend inside `standctl`: `build` + `vite preview :<web port>`. `VITE_*` — pointing at the local backends.

### 3. Readiness (both items)

1. `curl` health → 200: the health path of each service (`svc_defaults` in stand-project.sh). Wait 30–40 s; the log has no
   DB connection / shutdown errors (write the exact strings of your stack into the stand map, e.g. the
   driver's "server selection" and "pool timeout" messages).
2. **Check the live listener's env** (`/proc/<pid>/environ` or the starter's output):
   - the DB host/port env of the process matches the chosen `DB` mode (`stand_verify_env` in stand-project.sh)
   Health 200 with wrong `DB_*` = **not ready** → restart via `standctl`.

### 4. Stopping

Only your own pid files. Before `kill` check `ps -o args= -p <pid>` and/or
`readlink /proc/<pid>/cwd`. Forbidden: `kill -$pgid`, `pkill -f`,
`lsof | xargs kill`. Stopping auth/backend breaks the UI session — warn about it in the report.

### 5. Logs in the report

Not in full: one line of cause per failed service + the path to the log.

## Reply

```
[DEVOPS RESULT] Services: <repo>@<branch>, <repo>@{{PROJECT_BASE_BRANCH}}

Frontend: http://localhost:<web port>  (worktree $PROJECT_ROOT/.worktrees/…)
Backend:  :<api port>  DB <host:port/db from live environ>
<one line per other started service: name :port>
<frontend env that points at local backends, e.g. VITE_API_DOMAIN=http://localhost:<api port>, ...>
PIDs: <worktree>/logs/*.pid
Did not start: — (or service → reason in one line → path to the log)
Starter: standctl (~/.claude/skills/agent-devops/standctl) + DB from live environ
```

Sent **by the agent itself** to the `From` pane:

```bash
~/.claude/hooks/herdr-pane-send.sh <From_pane> "[DEVOPS RESULT] ..."
```

Via the helper, not a bare `pane send-text` + `send-keys Enter` pair: with Cursor, after that pair
a copy of the text stays in the input field and gets glued to the next message to this pane.
The helper sends `herdr agent prompt`, and on `agent_not_ready` (a pane without a named
agent, e.g. mimo) falls back to send-text.

Host/port/DB for each service (from live environ) and `VITE_*` are mandatory,
passwords — never.

## Boundaries

- Do not edit code or tests in the started worktree — only the environment (`.env`,
  symlinks). A build failing because of code — `[DEVOPS BLOCKED]` with the error; the
  author fixes it.
- Do not touch `.env.develop`/`.env.staging` or other people's `.env`; edits only in
  the worktree's `.env` / `.env.local` (or process-env extras via `standctl`).
- Do not apply migrations, do not start docker with an empty schema while the chosen
  DB target is available.
- `sudo`/sysctl (inotify limit) — only via the user.
- Does not run tests itself: once the stand is up, hand the run and triage to QA via `[QA REQUEST]`.
  Code review — `[REVIEW REQUEST]` to Review, database queries — `[DB REQUEST]` to DB.
- Write nothing to GitHub and ClickUp without an explicit request from the user.
