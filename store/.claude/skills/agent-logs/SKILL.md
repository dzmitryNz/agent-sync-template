---
name: agent-logs
description: "Protocol for log analysis between agents: how to hand a question about {{PROJECT_NAME}} logs (staging Loki via Grafana MCP, local stand logs, service logs by order/user/error) to the standing agent in herdr space \"Logs\" and what the logs agent itself does. Use when an agent needs an answer from logs without pulling log lines into its own context, when a logs request arrives from another agent (a message starting with [LOGS REQUEST]), or when the user asks to dig through logs as the logs agent in space Logs. Triggers: look in the logs, LOGS REQUEST, I am the logs agent, find logs for a record, why a 503 is in the logs."
---

# Logs between agents

The logs agent is a standing agent in herdr space **Logs**. Its input is thousands of
lines of Loki and local logs, its output is a five-line chronology. That is
why the work is moved out of the main session.

## Model — check before any action

This role needs **Sonnet 5** (`claude-sonnet-5`). The current session's model is
stated in the system prompt ("You are powered by the model named ...").

A different model still runs this role. Name it in the confirmation line as `Model: <name from the system prompt>`. The id above is a preference, not a gate: do not stop, and do not ask for a model switch, only because the id differs.


### Effort

Bring up the Claude variant of the role at `low` — with a flag in the start command:

```
herdr agent start <name> --kind claude --pane <pane> -- --model sonnet --effort low
```

Reason: the role filters logs and retells what it found — the spend goes on input,
not on reasoning. Sonnet 5 here is also for the window: 1M versus 200K for Haiku,
walls of Loki do not fit in 200K. The global `effortLevel` in
`~/.claude/settings.json` (currently `medium`) is too high for this role.

There is no gate here as there is for the model, and there cannot be: effort is not visible from inside
the session, and invoking a skill does not switch it — the parameter is set only at
process start. So the flag is set by whoever brings the pane up. If the role is already
running without it — finish the request as is, do not restart midway:
changing effort resets the prompt cache anyway.

### In Cursor CLI

The same preference, a different source: the model is visible in `cursor-agent about` (the `Model` line).
For this role — **Composer 2.5** (`composer-2.5`): cheap on the Cursor Pro limit, and
the role's work is mechanics. Do not use Sonnet in Cursor: it is rate-limited there. A different model still runs this role. The preference and the any-model flag are in `AGENTS.md` ("Role models").

If the user told you to bring up an instance yourself, the model is set with the same flag.

The check happens on every skill invocation, not only on self-assignment. Reason:
log search is filtering and retelling, judgment is needed only for assembling the
chronology; a senior model does not pay off (the "Subagent models" section in
`~/.claude/CLAUDE.md`).

## Role host

The role has no permanent host. The requester looks for it on its own machine —
`herdr-spaces list`, a space with label `Logs`/`Logs-N` and `agent_status: idle`.

The role's resources (MCP `grafana-staging`) are not set up on every
machine: if they are not here, the executor replies `[* BLOCKED]` with what is missing, and the
user decides on which host to bring up the role.

Take an agent on **another host** only if the user named the host (in chat or by the
`Hosts:` field of a request from PM). If the role is not local and no host is named — do not look for it on other
machines, but tell the user which space to add (use a space that already exists; do not create one unless the user asked).

**Status of a named host** — from the cache that the systemd timer `herdr-host-ping.timer`
refreshes every 5 minutes (no ssh and no tokens are spent on it):

```bash
cat ~/.cache/herdr-hosts/<host>.status     # <UTC time>\t<STATUS>\t<details>
```

`STATUS`: ok | busy | no-space | ssh-auth | ssh-down | herdr-down. The busyness of a specific
space is visible in the spaces field (`Logs=idle`). If the file is missing or the time is older than 15 minutes —
run once by hand `~/.claude/hooks/herdr-host-ping.sh <host> Logs` (code 0 = OK to send)
and tell the user about the timer. `busy` — wait for idle. `ssh-auth` — Tailscale SSH asks for
re-authorization via the link from the output: only the user does this, tell them and stop.
`ssh-down`/`herdr-down` — report to the user, do not take over the role's work.

**A request to another host** — via ssh over Tailscale (the preamble from the `remote-agents`
skill: the user from `jq -r .home ~/.agent-sync/sessions/<host>/*.json`,
the `P=` line below: `XDG_RUNTIME_DIR` on Linux, Homebrew `herdr` on macOS):

```bash
P='[ -d /run/user/$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/$(id -u); PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr'
ssh <user>@<host> "$P workspace list"                   # label → workspace_id, agent_status
ssh <user>@<host> "$P pane list --workspace <id>"
ssh <user>@<host> "$P agent prompt <pane_id> '[... REQUEST] ...'"   # without --wait over ssh
```

**`From` always with the host**: `From: <host>:w7:p2`. The executor replies by the same
route: if the host in `From` is not its own — `ssh <user>@<host> "$P agent prompt <pane> ..."`,
otherwise a local `herdr agent prompt`. Read a `From` without a host as "the same host
as the sender", but always write the host in new requests.

Local paths in the request (worktree, plan) are valid only on the executor's host:
the plan — from the synced `~/.claude/plans/`, the code — by branch/PR, not by path.

## Self-assignment in an empty window

An empty session with no incoming `[LOGS REQUEST]` (a fresh chat in space Logs) —
the agent passes the model check, checks that the MCP `grafana-staging` is visible
(`list_datasources`), confirms the role in one line and waits for a request.
If the MCP is not visible — say so immediately: the server is registered only on this
machine and requires a session restart after registration.

### Naming your space

On self-assignment the agent gives the workspace the needed label itself — the user does not need to
rename it by hand:

```bash
herdr-spaces me          # current label
herdr-spaces list                              # is there already another space with label "Logs"
herdr workspace rename $HERDR_WORKSPACE_ID Logs
```

If the label is already `Logs` or `Logs-N` — do nothing. If `Logs` is already worn by an
**other** workspace (a second instance for a parallel task) — take
the next free number: `Logs-2`, `Logs-3`, ... Do not create two spaces with the same label:
requests choose an agent by label and status. Without `HERDR_ENV=1` (the session is not in herdr) skip the
step and mention this in the role confirmation line.


## How to hand over a question

```bash
herdr-spaces list                      # workspace_id of the entry with "label":"Logs"
herdr pane list --workspace <id>
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-logs "[LOGS REQUEST] ..."   # without --wait: the answer comes by itself
```

**Always send through `herdr-handoff.sh`, never as three separate `agent prompt` calls.** The script does `/clear` → `/<skill>` → waits until the pane is quiet → sends the request → checks that the request is visible in the pane (one retry). Separate prompts lose the request: `--wait` returns before `/clear` or the skill load is really finished, and the request is swallowed. Exit 0 = the request is visible in the pane; exit 1 = tell the user, do not assume it arrived. `--no-clear` (first argument) continues a previous task in the same pane; a non-claude pane (Cursor, mimo) gets the request directly. Multi-line request: pass it on stdin (`<<'EOF'`). On another host run the same script over ssh with the `remote-agents` preamble (`XDG_RUNTIME_DIR` when `/run/user/<uid>` exists, `~/.local/bin` and Homebrew in PATH).

**`/clear` before a request.** The executor does not need past analyses, and each of its turns
rereads them again: context over 150k is more than half of the weekly limit. The first two steps of the script — only if the pane in `pane list` has `"agent":"claude"` (Cursor and mimo
clear differently — send the request there directly). After `/clear` the role is assigned anew via
`/agent-logs`, not by the request tag. From another host — the same via `$P`.

**Several instances.** Spaces are looked up by label `Logs` and `Logs-N`; in `herdr-spaces list`
each has an `agent_status`. Take the one that is `idle`. All `working` — do not send into a
busy one (the request would wedge into someone else's context): queue the request and send it
when an instance becomes `idle`; several requests — one at a time, in the order of dependencies.
Do not create a new space or ask for one unless the user said so (use a space that already exists; do not create one unless the user asked).

**Do not wait for the answer.** Do not set `--wait` even on a single question about one time
window: while the logs agent digs, the requester sits idle, and on an incident analysis across
several services the timeout expires anyway. Sent — told the user where it went,
and returned to your own work. The answer comes by itself into the pane from `From`, as an ordinary incoming
message; there is no need to poll someone else's pane.

### Request

```
[LOGS REQUEST]
Source: staging                     # staging | local:<worktree path> | prod (see boundaries)
Services: acme-api, acme-worker                 # what to look at; empty = the agent decides from the question
Window: 2026-09-10 12:00–12:40 UTC  # or "last hour"; a request without a window is not accepted
Key: orders.id 12345              # what to search for: order id, userId, requestId, error text
Question: why did /orders/12345/events return 503 UPSTREAM_UNAVAILABLE
From: w7:p2                         # your own $HERDR_PANE_ID
```

- **`Window`** is mandatory: without a window the Loki query either times out or
  brings back junk. State the time in UTC, the agent gives the answer in UTC too.
- **`Question`** is mandatory even with an exact `Key`: the agent answers the question,
  it does not forward a selection of lines.
- **`From`** is mandatory.

## The logs agent's work

1. Model check (see above).
2. `staging` — MCP `grafana-staging`:
   first `list_loki_label_values` for the `service` label (values like
   `<service>-<region>`), then `query_loki_logs` filtered by `Key`, the window from
   `Window`, limit 200 lines; go wider not by raising the limit but with an aggregate
   `count_over_time(...)` in the same `query_loki_logs` (for example by `log_level`)
   or `query_loki_stats`. `query_loki_patterns` and all Sift tools
   (`find_error_pattern_logs`, `find_slow_requests`) may be unavailable on your Grafana — if they return 404, do not call them again.
3. `local:<path>` — the files `<worktree>/logs/*.log` written by the stand
   agent (the agent-devops skill). Read with `rg -n <Key>` and `sed -n` around the matches,
   not a full `cat`. Check the order of events by timestamps, remembering that
   local services write time in the process's zone.
4. Assemble the chronology: for each service — the first relevant line,
   the turning line (error/timeout/retry), the last. Between services —
   by `requestId`/order, not by coinciding seconds.
5. Known traps (project-specific — add yours here): a generic 5xx from a gateway may hide the
   upstream status, so look at the upstream service's own logs; a crash from an unavailable
   cache/database can arrive after a timeout as `unhandledRejection`, not as a connect error;
   shared environments carry noise from test bots.
6. Log lines in the report — no more than three, and only those that prove the conclusion.
   The full selection goes to the file `<scratchpad or worktree>/logs/<key>-<window>.log`,
   the path in the report.

## Reply

```
[LOGS RESULT] staging — <key>, 12:00–12:40 UTC

Answer: <service-b> did not go down — it returned 500 after a database timeout; <service-a> masked this as 503.
12:17:03 <service-a>  POST /endpoint → <service-b>
12:17:08 <service-b>  database timeout → 500
12:17:08 <service-a>  503 UPSTREAM_UNAVAILABLE
Repeats: 4 in the window, all with the same pattern; before 12:15 requests passed in <300 ms.
Selection: <path>/<key>-1200-1240.log (212 lines)
```

Sent **by the agent itself** to the `From` pane — without this the answer hangs
in space Logs, and the asker will not see it until they look themselves:

```bash
~/.claude/hooks/herdr-pane-send.sh <From_pane> "[LOGS RESULT] ..."
```

Via the helper, not a bare `pane send-text` + `send-keys Enter` pair: with Cursor, after it a
copy of the text stays in the input field and sticks to the next message into this pane.
The helper sends `herdr agent prompt`, and on `agent_not_ready` (a pane without a named
agent, for example mimo) falls back to send-text.

If there is no data — say "no lines for the key in the window", that is also an answer.
If the source is unavailable — `[LOGS BLOCKED]` with a specific reason.

## Boundaries

- `prod` is not connected through Grafana (adjust if yours is); prod logs live elsewhere, to which the
  agent has no access. On `Source: prod`
  — `[LOGS BLOCKED]` immediately, do not look for workarounds. Anything that needs prod data is
  done by the user.
- Read-only: do not create annotations, incidents, alerts and dashboards in
  Grafana, even if the tool allows it.
- Do not diagnose code: state the service, the line and the sequence, and the
  cause in code is looked for by the author or the main session.
- Personal data from logs (phone, e-mail, address) is not to be carried into the answer;
  on staging and dev the data is test.
- Do not read or print the Grafana token.
- Other roles — by request: data and query plans — `[DB REQUEST]` to DB (do not
  go into MySQL/PG yourself), bringing up services for logs — `[DEVOPS REQUEST]`
  to DevOps, test runs — `[QA REQUEST]` to QA.
- Write nothing to GitHub and ClickUp (do not post to GitHub or the tracker unless asked).
