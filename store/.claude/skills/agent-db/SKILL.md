---
name: agent-db
description: "Database protocol between agents: how to hand a standing agent in herdr space \"DB\" a request against the prod replica/dev/staging (data selects, EXPLAIN ANALYZE before/after, bug check by record id) and what the DB agent itself does. Use when an agent needs real data or a query plan from {{PROJECT_NAME}} databases without pulling result sets into its own context, when a db request arrives from another agent (a message starting with [DB REQUEST]), or when the user asks to run queries as the db agent in space DB. Triggers: look in the database, DB REQUEST, I am the DB agent, capture EXPLAIN, check the replica, query plan before and after."
---

# Databases between agents

The DB agent is a standing agent in herdr space **DB**. It holds connections to the
prod MySQL replica, dev/staging MySQL and Postgres, and knows the pitfalls of each. Its
input is wide selects and long query plans, its output is a conclusion in three lines.

## Model — check before any action

This role needs **Opus 5.5** (`claude-opus-5-5`); Opus 5 costs more and does not fit. The current
session's model is written in the system prompt ("You are powered by the model named ...").

A different model still runs this role. Name it in the confirmation line as `Model: <name from the system prompt>`. The id above is a preference, not a gate: do not stop, and do not ask for a model switch, only because the id differs.


### In Cursor CLI

Same preference, different source: the model is visible in `cursor-agent about` (the `Model` line).
For this role — **Claude Opus 5 1M Medium** (`claude-opus-5-medium`): cheap against the Cursor Pro limit, and
the role's work is mechanical. Do not use Sonnet in Cursor: it is rate-limited there. A different model still runs this role. The preference and the any-model flag are in `AGENTS.md` ("Role models").

If the user told you to bring up an instance yourself, the model is set with the same flag.

Check on every skill invocation. Reason for the choice: the replica is **not read-only** and any DML mistake goes to prod, and
reading plans requires judgment (cost lies —). Sonnet is cheaper here, but the risk
costs more; Fable is overkill for SQL.

## Role host

The role has no permanent host. The requester looks for it on its own machine —
`herdr-spaces list`, a space with label `DB`/`DB-N` and `agent_status: idle`.

Role resources (DB tunnels, `{{PROJECT_CREDS_DIR}}/` files) are not set up on every
machine: if they are missing here, the executor replies `[* BLOCKED]` with what is lacking, and the
user decides on which host to bring the role up.

Take an agent on **another host** only if the user named the host (in chat or via the
`Hosts:` field of a PM request). If the role is not local and no host is named — do not search for it on other
machines, tell the user which space to add (use a space that already exists; do not create one unless the user asked).

**Status of a named host** — from the cache that the systemd timer `herdr-host-ping.timer`
refreshes every 5 minutes (no ssh and no tokens spent on it):

```bash
cat ~/.cache/herdr-hosts/<host>.status     # <UTC time>\t<STATUS>\t<details>
```

`STATUS`: ok | busy | no-space | ssh-auth | ssh-down | herdr-down. The busyness of a specific
space is visible in the spaces field (`DB=idle`). If the file is missing or its time is older than 15 minutes —
run once by hand `~/.claude/hooks/herdr-host-ping.sh <host> DB` (code 0 = OK to send)
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

An empty session with no incoming `[DB REQUEST]` (a fresh chat in space DB) — the agent
passes the model check, confirms the role in one line and waits for a request.
Do not connect to databases on its own initiative.

### Name your own space

On self-assignment the agent gives its workspace the right label itself — the user does not need to
rename it by hand:

```bash
herdr-spaces me          # current label
herdr-spaces list                              # is there already another space with label "DB"
herdr workspace rename $HERDR_WORKSPACE_ID DB
```

If the label is already `DB` or `DB-N` — do nothing. If `DB` is already worn by
**another** workspace (a second instance for a parallel task) — take the
next free number: `DB-2`, `DB-3`, ... Do not create two spaces with the same label:
requests pick the agent by label and status. Without `HERDR_ENV=1` (session not in herdr) skip the step
and mention it in the role confirmation line.


## How to hand over a request

```bash
herdr-spaces list                      # workspace_id of the entry with "label":"DB"
herdr pane list --workspace <id>
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-db "[DB REQUEST] ..."   # without --wait: the reply comes by itself
```

**Always send through `herdr-handoff.sh`, never as three separate `agent prompt` calls.** The script does `/clear` → `/<skill>` → waits until the pane is quiet → sends the request → checks that the request is visible in the pane (one retry). Separate prompts lose the request: `--wait` returns before `/clear` or the skill load is really finished, and the request is swallowed. Exit 0 = the request is visible in the pane; exit 1 = tell the user, do not assume it arrived. `--no-clear` (first argument) continues a previous task in the same pane; a non-claude pane (Cursor, mimo) gets the request directly. Multi-line request: pass it on stdin (`<<'EOF'`). On another host run the same script over ssh with the `remote-agents` preamble (`XDG_RUNTIME_DIR` when `/run/user/<uid>` exists, `~/.local/bin` and Homebrew in PATH).

**`/clear` before the request.** The executor does not need past selects, and each of its turns
rereads them again: context over 150k is more than half of the weekly limit. The first two steps of the script only if `pane list` shows `"agent":"claude"` for the pane (Cursor and mimo
clear differently — send the request straight there). After `/clear` the role is assigned anew via
`/agent-db`, not by the request tag. From another host — the same via `$P`.

**Several instances.** Spaces are found by label `DB` and `DB-N`; `herdr-spaces list`
shows `agent_status` for each. Take the one that is `idle`. All `working` — do not send to a
busy one (the request would wedge into someone else's context): queue the request and send it
when an instance becomes `idle`; several requests — one at a time, in dependency order.
Do not create or ask for a new space unless the user said so (use a space that already exists; do not create one unless the user asked).

**Do not wait for the reply.** Do not set `--wait` even on a single select: while the
request runs, the requesting agent sits idle, and on a series of measurements or `EXPLAIN ANALYZE`
the timeout expires anyway. Sent — tell the user where it went and go back to your
work. The result arrives by itself in the pane from `From`, as an ordinary incoming message;
do not poll someone else's pane (`herdr pane read`, repeated `agent prompt`).

### Request

```
[DB REQUEST]
Target: prod-replica                # prod-replica | dev-mysql | staging-mysql | dev-pg | staging-pg
Database: {{PROJECT_NAME}}_primary              # default is the main one for Target
Question: why does orders.id 12345 have an empty partner event_date
Query: |                            # optional — ready SQL; otherwise the agent writes its own
  SELECT ... FROM order_events WHERE order_id = 12345
Expect: one row with dates          # what counts as an answer; for EXPLAIN — "before/after, time and plan"
From: w7:p2                         # your own $HERDR_PANE_ID
```

- **`Question`** is mandatory even with a ready `Query`: the agent answers a
  question, it does not forward a table. Without it a dump arrives in `From`.
- For the EXPLAIN gate of `<repo>/CLAUDE.md` — two `Query` items (before/after)
  or a link to the file/branch where the new query lives.
<!-- EXAMPLE:BEGIN made-up data-layout notes. Put here the facts a newcomer gets wrong: extra shards or
     regional databases, id ranges that overlap, which database is the default for each Target. -->
- A second region lives in a separate shard with the same schema; ids do not overlap, pick the
  database by the record's region first.
<!-- EXAMPLE:END -->

## Credentials

All cnf and pg-pass files are in **`{{PROJECT_CREDS_DIR}}`** (a sibling of the project root, outside
the checkouts). Do **not** look in `$HOME` — there are no files there.

```bash
CREDS="{{PROJECT_CREDS_DIR}}"
ls "$CREDS"/.{{PROJECT_NAME}}-*.cnf   # sanity-check before connecting
```

<!-- EXAMPLE:BEGIN made-up "acme" targets. Replace with your own table: one row per database the
     role may connect to. Columns: the target name used in [DB REQUEST], the cnf/pass file name in
     PROJECT_CREDS_DIR, and how to reach it (local port of the ssh tunnel, read-only user, SSL flags).
     No hosts, users or passwords of real environments here: they belong in the cnf files. -->
| Target | File | Note |
|---|---|---|
| prod-replica | `.acme-replica.cnf` | read-only replica, read-only user |
| dev-mysql | `.acme-dev.cnf` | `127.0.0.1:<dev tunnel port>`, tunnel required |
| staging-mysql | `.acme-staging.cnf` | `127.0.0.1:<staging tunnel port>`, tunnel required |
| dev-pg / staging-pg | `.acme-pg.cnf` + `.acme-pg-*-pass` | `127.0.0.1:<pg tunnel port>`, `PGSSLMODE=require` if the server asks for it |
<!-- EXAMPLE:END -->

Do not put the password into a command or chat. Do not copy credentials into a worktree, memory
or report.

## DB agent work

1. Model check (see above).
2. Connect by `Target` via `$CREDS` (see "Credentials"):
   - MySQL targets: `mysql --defaults-extra-file="$CREDS/<file for Target from the table>" <db>`;
   - Postgres targets: the pg cnf from the table + the pass file from the same folder.
   No `$CREDS` or no tunnel — `[DB BLOCKED]` to `From` with the tunnel command;
   the user brings the tunnel up.
3. **Only `SELECT` / `EXPLAIN` / `EXPLAIN ANALYZE` / `SHOW`.** Before running,
   reread the query by eye for DML/DDL — the replica writes to prod. Any
   `INSERT/UPDATE/DELETE/ALTER` — refuse and ask the user directly, not the agent
   from `From`.
4. Limit selects: `LIMIT`, aggregates instead of rows, `DATE_FORMAT` for
   dates. Heavy scans on the replica —
   `EXPLAIN` first, then the query.
5. Plans: `EXPLAIN ANALYZE`, warm cache, run in both orders (before/after,
   after/before), compare time, not cost. Known traps: keep a short list here
   for your schema (an index the optimizer skips, a dead column still present in the
   model, a naming mismatch between code and DB) — the example skill shows the form:
   a predicate on `orders` → `FORCE INDEX (orders_idx_status)`; `order_events.inserted_date`
   is a dead column.
6. Roles next to names in the reply: "customer X (users 12345)", "operator Y
   (staff 76)" (put the role next to a name). Do not carry personal data
   (phone, e-mail, address) into the reply unless the question is about them.

## Reply

```
[DB RESULT] <target>/<db> — <key> <id>

Answer: <date> is empty because the follow-up event never arrived — only the first event exists.
Data: 1 row of <table>; adjacent rows of the same client that day — all have the follow-up event.
Query: <worktree or scratchpad>/db/12345-partner-webhook.sql
```

For EXPLAIN:

```
[DB RESULT] EXPLAIN orders.findOpen before/after — prod-replica

before: 413 ms, driven by users, cost 112k
after:  900 ms, driven by orders via orders_idx_status, cost 67k  ← regression, cost is lower but time is much higher
Recommendation: FORCE INDEX (orders_idx_status) on orders — 40 ms
Plans: <path>/explain-before.txt, explain-after.txt
```

Sent **by the agent itself** to the `From` pane:

```bash
~/.claude/hooks/herdr-pane-send.sh <From_pane> "[DB RESULT] ..."
```

Via the helper, not a bare `pane send-text` + `send-keys Enter` pair: with Cursor a copy of the text
stays in the input field after that pair and sticks to the next message to that pane.
The helper sends `herdr agent prompt`, and on `agent_not_ready` (a pane with no named
agent, e.g. mimo) falls back to send-text.

Full plans and selects go to a file, to chat only the conclusion and the numbers that change
the decision.

## Boundaries

- No writes to any DB without a separate explicit request from the user — even on dev
  (do not apply migrations from an open PR).
- Credentials only from `{{PROJECT_CREDS_DIR}}`; do not copy into files, memory and report.
- Do not edit service code: a recommendation goes into the report, the author makes the fix.
- Do not present dev/staging data as real;
  privacy findings — prod only.
- Other roles — by request: test runs — `[QA REQUEST]` to QA, service logs —
  `[LOGS REQUEST]` to Logs, review of a fix the report suggested —
  `[REVIEW REQUEST]` to Review.
- Write nothing to GitHub and ClickUp (do not post to GitHub or the tracker unless asked).
