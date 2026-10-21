---
name: herdr
description: "Control Herdr, a terminal multiplexer for coding agents. Use only when the user explicitly mentions Herdr or asks to use Herdr to inspect or control panes, tabs, workspaces, commands, or another agent. Do not use merely because a task could benefit from a background terminal, delegation, or parallel work. Requires HERDR_ENV=1."
---

# Herdr

Herdr organizes terminals into workspaces, tabs, and panes, recognizes coding agents running inside panes, and exposes the current session through the `herdr` CLI.

Before issuing any control command, verify that this agent is running inside a Herdr-managed pane:

```bash
test "${HERDR_ENV:-}" = 1
```

If the check fails, say that you are not running inside Herdr and stop. Do not inspect or control the focused Herdr session from outside Herdr.

When the check passes, the `herdr` binary in `PATH` talks to the current session. Use it to inspect adjacent work, create terminal layout, start agents and commands, read output, and wait for state changes.

## Learn the current CLI

The installed binary is the authority for command syntax. Start with:

```bash
herdr --help
```

Then print the relevant command group by running the group without a subcommand:

```bash
herdr agent
herdr pane
herdr workspace
herdr tab
herdr worktree
herdr terminal
herdr notification
herdr integration
herdr session
```

Do not run bare `herdr` for discovery; it launches or attaches the TUI. Do not probe a mutating nested command by omitting arguments. Commands such as `herdr workspace create` are valid with defaults and will execute.

Most control commands return JSON. Read identifiers and state from those responses instead of predicting them.

## Understand layout, panes, and agents

Choose the primitive that matches the job:

- Workspace, tab, and pane topology organize terminal locations.
- Pane commands control raw terminals, shells, tests, servers, input, and output.
- Agent commands control the recognized coding agent currently occupying a pane.

A pane exists whether or not it contains an agent. `agent start` requires an existing available shell pane and never creates, splits, or moves layout. Use pane commands for ordinary processes. Use agent commands when Herdr must validate agent identity or interpret `idle`, `working`, `blocked`, `done`, and `unknown` lifecycle states.

Agent commands accept either a unique live agent name or the pane ID currently hosting that agent. They do not accept terminal IDs or bare agent-kind labels. Names must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents. A name follows the current pane occupant and is cleared when that agent exits, is released, or is replaced.

`idle` means the agent is ready for input and its tab has been seen in the focused Herdr UI. `done` is the same underlying idle state after unseen background work finishes. Focusing the tab or targeting the pane or agent with a focus command marks it seen. CLI reads do not mark it seen. `blocked` means Herdr recognized an approval or question UI. `unknown` means an agent is present but Herdr cannot classify it confidently; it does not prove completion.

## Use IDs and caller context

Public IDs are opaque stable handles:

- workspace: `w1`
- tab: `w1:t1`
- pane: `w1:p1`

Closed tab and pane IDs are not reused. A pane moved into another workspace receives a new workspace-qualified pane ID. After `pane move`, continue with `.result.move_result.pane.pane_id` or the live agent name. The old value is reported as `.result.move_result.previous_pane_id`; only the moved process's inherited caller context keeps resolving that old ID, so do not use it as a general agent target.

Herdr injects the caller's context into each managed pane:

```bash
printf '%s\n' "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID"
```

Prefer `--current` when a pane command should target the calling pane. Omitting a target may use the UI-focused pane, which can belong to the user or another client.

Discover live state with:

```bash
herdr-spaces list
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr pane current --current
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
```

Creation responses expose the IDs to use next. `workspace create` returns `.result.workspace`, `.result.tab`, and `.result.root_pane`. `tab create` returns `.result.tab` and `.result.root_pane`. `pane split` returns the new pane as `.result.pane`.

## Start and coordinate an agent

Default to a sibling pane in the current tab and the current working directory. Do not create a workspace, tab, worktree, or different cwd unless the user explicitly requests that topology or location.

Honor a direction requested by the user. Otherwise inspect the caller pane:

```bash
herdr pane layout --pane "$HERDR_PANE_ID"
```

Split a wide pane to the right and a narrow or tall pane down. Avoid repeated same-direction splits that create unusably narrow columns or short rows. Keep the user's focus in the calling pane and explicitly preserve the caller's working directory:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
```

Replace `right` with `down` when appropriate. Read the new pane ID from `.result.pane.pane_id`.

An available shell pane must be at its interactive prompt, with the shell itself in the foreground and no foreground command, editor, or agent running. Start a supported agent in that pane with a useful unique name:

```bash
herdr agent start reviewer --kind codex --pane <returned-pane-id>
```

Use the kind requested by the user. Run `herdr agent` to inspect the installed kind list and options. Pass native agent arguments only after `--`:

```bash
herdr agent start reviewer --kind codex --pane <returned-pane-id> -- <agent-args...>
```

`agent start` returns only after Herdr detects the expected agent in the same pane and considers it ready for interactive input. It defaults to a 30-second startup timeout.

Submit work through the agent surface:

Generic herdr example, not a role review (`--wait` is not how a review starts):

```bash
herdr agent prompt reviewer "Summarize the files changed in this directory." --wait --timeout 120000
```

`agent prompt` atomically submits text and encoded Enter while honoring the pane's live bracketed-paste mode. For normal agent work, `--wait` is enough: it waits for the first settled `idle`, `done`, or `blocked` state. Do not repeat those defaults with `--until`.

A prompt sent from a non-working state must produce an observed lifecycle change within five seconds. Otherwise Herdr returns `agent_prompt_stalled` instead of waiting indefinitely. This wait tracks lifecycle state, not an individual turn; if the agent is already working, completion of the active turn may satisfy it.

Use `--until` only for a state-specific workflow, such as waiting for an already-running agent to request input:

```bash
herdr agent wait reviewer --until blocked --timeout 120000
```

Without `--until`, standalone `agent wait` uses the same settled-state defaults as `agent prompt --wait`.

Use logical keys for interactive agent UI controls:

```bash
herdr agent send-keys reviewer esc
herdr agent send-keys reviewer ctrl+c
```

Herdr validates all keys before writing any bytes. Read the result through the resolved agent:

```bash
herdr agent get reviewer
herdr agent read reviewer --source recent-unwrapped --lines 120
```

If a wait fails or returns `blocked`, inspect `agent get` and `agent read` before deciding what input to send. Use the pane surface only when raw terminal control is intentional.

## Run an ordinary command in another pane

Create a sibling pane with the same geometry rule, preserve the caller's working directory, and keep user focus unchanged:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
```

Read the new pane ID from `.result.pane.pane_id`, then run and inspect the command:

```bash
herdr pane run <returned-pane-id> "just test"
herdr pane wait-output <returned-pane-id> --match "test result" --timeout 120000
herdr pane read <returned-pane-id> --source recent-unwrapped --lines 120
```

`pane run` atomically sends command text and Enter. `pane wait-output` searches the selected snapshot immediately, so output that already exists can match. Use `--match <text>` for a literal substring or `--regex <pattern>` for a Rust regular expression. Omitting `--timeout` allows an indefinite wait.

Use the read source that matches the task:

- `visible`: the currently rendered viewport.
- `recent`: recent rendered output, including soft wraps.
- `recent-unwrapped`: recent output with soft wraps joined; prefer it for logs and transcripts.
- `detection`: the plain-text bottom-buffer snapshot used for agent detection.

Use `--format ansi` when colors and terminal styling are evidence. Otherwise use text.

`--lines` asks Herdr for more rows from the pane's available screen and host scrollback. If increasing it does not reveal more of a completed response, the pane is probably running the agent on the terminal's alternate screen. Rows that leave the alternate screen do not enter Herdr's host scrollback, so a larger line count cannot recover them.

After that failed read, ask the agent to write its complete response as Markdown in a temporary directory and reply only with the file path, then read the file directly. Use this only as a fallback; do not request file output in the initial prompt.

## Standing role agents in this setup

Nine role spaces each host one standing Claude Code agent with a fixed role. Before starting a new agent or a subagent for one of these jobs, hand the job to the matching space instead: find its `workspace_id` by `label` in `herdr-spaces list`, take the single pane from `herdr pane list --workspace <id>`, and send the tagged request. The request form, result form, and the role protocol live in the matching `agent-*` skill; load it rather than improvising the message.

| Space label | Host | Skill | Model | Request → result | `--wait` |
|---|---|---|---|---|---|
| Review Cursor / Review Claude | local | agent-review | Opus 5.5 (Claude only) | `[REVIEW REQUEST]` → `[REVIEW RESULT]` | no |
| Developer | local | agent-developer | Sonnet 5 / Cursor composer-2.5-fast (mechanical plans only) | `[DEV REQUEST]` → `[DEV RESULT]` / `[DEV BLOCKED]` | no |
| DevOps | local | agent-devops | Sonnet 5 / Cursor composer-2.5-fast | `[DEVOPS REQUEST]` / `[DEVOPS STOP]` → `[DEVOPS RESULT]` | no |
| QA | local | agent-qa | Sonnet 5 / Cursor composer-2.5-fast | `[QA REQUEST]` → `[QA RESULT]` | no |
| DB | local | agent-db | Opus 5.5 / Cursor claude-opus-5-medium | `[DB REQUEST]` → `[DB RESULT]` | no |
| Logs | local | agent-logs | Sonnet 5 / Cursor composer-2.5-fast | `[LOGS REQUEST]` → `[LOGS RESULT]` | no |
| PM | local | agent-pm | Opus 5.5 (Claude only) | `[PM REQUEST]` → `[PM RESULT]` / `[PM BLOCKED]` | no |
| Cleaner | local | agent-cleaner | Sonnet 5, effort low | `[CLEANER REQUEST]` → `[CLEANER RESULT]` | no |
| Docs | local | agent-docs | Sonnet 5 | `[DOCS REQUEST]` → `[DOCS RESULT]` / `[DOCS BLOCKED]` | no |

- No role has a fixed host: look for the role on your own machine first (`herdr-spaces list` by label). Use an agent on another host only when the user named that host (in chat, or in the `Hosts:` field of a `[PM REQUEST]`); if the role is missing locally and no host was named, ask the user which space to add instead of searching other machines. Cross-host addressing goes over ssh + herdr socket per the `remote-agents` skill; `From` is always `<host>:<pane>` (`<host>:w7:p2`). Before a cross-host request read `~/.cache/herdr-hosts/<host>.status` (refreshed every 5 min by the user timer `herdr-host-ping.timer`; if missing or older than 15 min run `~/.claude/hooks/herdr-host-ping.sh <host> <Label>` once by hand): `ok` with `<Label>=idle` means send; `ssh-auth` means Tailscale SSH wants re-authentication, which only the user can do; `ssh-down`/`herdr-down` means the host or its herdr is not up. Do not fall back to doing the role's work yourself.
- Every request carries `From: <host>:$HERDR_PANE_ID` of the caller; the role agent replies into that pane itself, so do not poll it.
- Several instances of one role are allowed for parallel tasks: labels are `<Label>` and `<Label>-N` (`Developer`, `Developer-2`). For Developer the caller normally creates its own instance per task (`herdr workspace create --cwd <repo> --label Developer-<task> --no-focus`, then `herdr agent start dev-<task> --kind claude --pane <pane_id> -- --model sonnet`, then `/agent-developer` and the request) and closes that workspace when the PR cycle is done; see agent-developer. Pick the instance whose `agent_status` is `idle` in `herdr-spaces list`; never prompt a `working` one, the message would land inside its current task. A role agent invoked in a fresh session renames its own workspace itself (`herdr workspace rename $HERDR_WORKSPACE_ID <Label>`), taking the next free number if the base label is held by another workspace. Do not create two workspaces with the same label. DevOps is the exception to multi-instance: exactly one per host, because it owns the ports and pid files; when it is `working`, wait for `idle` instead of starting a second one.
- No role runs on Fable. Pass `--model` when you want a specific one. If that id is missing, start without it; the role still runs on the account default.
- A role can run as a Cursor agent too (`herdr agent start <name> --kind cursor --pane <id> -- --model <id>`); the Cursor model per role is in the table, and the agent checks it via `cursor-agent about`. Review and PM stay on Claude.
- The Model column is a preference. Role agents name the model they are on. A different model id does not stop the role.
- If the space is missing or its pane does not answer, tell the user; do not do the role's work yourself and do not spawn a replacement agent.

## Safety and coordination rules

- Use `--no-focus` for background work unless the user asked to switch context.
- Use `--current`, an explicit pane ID, or a unique agent name. Do not rely on another client's focused pane.
- Parse IDs from JSON responses. Do not derive them from sidebar order or examples.
- Do not close workspaces, tabs, panes, or sessions you did not create unless the user explicitly asked.
- Never run `herdr server stop` from an active session unless the user explicitly intends to stop the server and its pane processes.
- Never kill the main Herdr process. Use named test sessions for experiments that need an isolated server.
- CLI server errors are JSON on stderr with exit status 1. CLI syntax errors exit with status 2.
