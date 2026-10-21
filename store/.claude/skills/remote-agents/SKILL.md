---
name: remote-agents
description: "Communicating with agents (Claude, Cursor, any others) on other hosts: find out who works where, message a live agent on another machine, read its reply, pick up its pane from a phone or another computer. Use when the user wants to message, check on, or hand a task to an agent running on another machine — a test stand on the work desktop, a session left running while away, an agent on the home server. Triggers: message an agent on another host, check the stand, message an agent from a phone, remote agent."
---

# Communicating with agents on other hosts

Channel: **ssh over Tailscale + the herdr socket API**. Works for any agent, because
herdr sees a pane as a terminal and does not know whether Claude or Cursor is there. Nothing
to deploy — Tailscale, ssh and herdr are already installed on all machines.

## 1. Which hosts exist at all

```bash
tailscale status          # online hosts; discard offline rows immediately
```

**The username on the other host is its own, not yours.** If it is `alice` on `<host>` and `bob` here,
the tailnet policy can reject `ssh bob@<host>`. Find out without guessing:

```bash
jq -r '.home' ~/.agent-sync/sessions/<host>/*.json | sort -u   # /home/alice -> alice@<host>
```

## 2. Preamble for every ssh command

A non-interactive shell arrives without `~/.local/bin` (or Homebrew on macOS) in `PATH`
and, on Linux, without `XDG_RUNTIME_DIR`, and without it herdr will not find its socket.
macOS has no `/run/user`, so the export runs only where that directory exists. So always:

```bash
ssh <user>@<host> '[ -d /run/user/$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/$(id -u); PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr <command>'
```

Without the `export` you get `command not found` or silence instead of a pane list — this is not
"herdr is broken", it is a stripped-down environment.

## 3. Who is alive there and what they are doing

**One command (preferred):** hooks in `~/.claude/hooks/`, in PATH as
`herdr-spaces` (a symlink from `~/.local/bin/` after agent-sync).

```bash
herdr-spaces                              # host, state, name, pane, agent — all machines from agent-sync
herdr-spaces list <other-host>                # one host
herdr-spaces hosts                        # host names only

~/.claude/hooks/herdr-host-ping.sh <other-host>   # quick cache ~/.cache/herdr-hosts/<host>.status
```

Direct Tailscale SSH does not listen on :22 on some hosts — `herdr-spaces` and
`herdr-host-ping.sh` try **tailcat** themselves (`~/.config/herdr-hosts.conf`).

**Manually** (if the hook is missing): a person names a session by its space name, look for the addressee
through workspaces:

```bash
herdr-spaces list     # label — the human name, plus agent_status
herdr pane list          # pane_id, agent, cwd
```

On the remote machine — the preamble from §2. Check `agent_status` (`idle` / `working`)
before sending (§4).

## 4. Message the agent and read the reply

**To another host by space label (preferred):**

```bash
export HERDR_FROM=$(hostname):${HERDR_PANE_ID}   # in a herdr pane; the reply will be returned here

herdr-spaces send <other-host> Review --file request.txt
herdr-spaces send <other-host> PM <<'EOF'
[PM REQUEST] ...
EOF
```

The same channel: `~/.claude/hooks/herdr-agent-send.sh <other-host> --label Review < request.txt`.
The body goes via **base64** over ssh/tailcat — long text and quotes `"..."` inside
do not break the command. Do **not** wrap a large `[PM REQUEST]` in a single pair of `"..."` in
the shell: inner `"` will truncate the argument; use `--file` or a heredoc.

Codes: `sent` — ok; `busy` — the space is `working`, do not send (you would cut in); `ssh-down` /
`ssh-auth` — see `herdr-host-ping.sh`.

Local machine: `herdr-spaces send $(hostname) QA "..."` → `herdr-pane-send.sh`.

**Low level** (Cursor / no named agent):

```bash
P='[ -d /run/user/$(id -u) ] && export XDG_RUNTIME_DIR=/run/user/$(id -u); PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH; herdr'
ssh <user>@<host> "$P pane run wB:p1 'check the tasks on the stand'"
ssh <user>@<host> "$P pane send-keys wB:p1 enter"     # mandatory, see below
sleep 5
ssh <user>@<host> "$P pane read wB:p1 | tail -20"
```

**`pane run` does not always press Enter.** With Cursor the text stays hanging in the input
line until you send `send-keys <pane> enter` separately. If `pane read`
shows your text after `→` and no reply — do not resend the text, send
Enter.

**A busy agent does not need Enter, and it is harmful.** With Cursor in the `working` state the text
goes into the `follow-ups` block and is applied by itself when the agent finishes the current step.
The caption under the block (`enter steer`) means Enter will cut into the work
immediately, mid-task. So: `idle` — send and press Enter; `working` —
send and leave it in the queue, unless you need to interrupt the work right now.

The reply is read from `pane read` (the tail of the pane screen). `herdr-pane-reply` is local only; it does not exist on a remote pane over ssh. Instead of an unconditional `sleep` you can use
`pane wait-output <pane> <pattern>`.

## 5. For a human — from a phone or another computer

Termius over Tailscale, then live interaction rather than commands:

```bash
ssh <user>@<host>    # then herdr — attach to the persistent session, live agent panes
herdr --remote <host> --handoff     # the same from a laptop, attach via ssh
```

This way you write to the agent as if at its desk, including permission confirmations that
cannot be passed through `pane run`.

## 6. When the channel is different

- **Both Claude sessions on one machine** — not ssh, but the standard `SendMessage` by name
  from `ListAgents`: delivery through a unix socket, nothing leaves the machine.
- **Claude ↔ Claude between machines** — `Remote Control` (`remoteControlAtStartup`,
  `/rc`): sessions on other machines appear in `ListAgents`. Requires a claude.ai
  login, messages go through Anthropic servers, Cursor cannot be reached this way.
- **Delivery straight into a live Claude session, bypassing herdr** — its inbox socket:
  the line `{"type":"auth","token":"$CLAUDE_CODE_MESSAGING_TOKEN"}`, then
  `{"type":"user","message":{"role":"user","content":"…"}}` into
  `$CLAUDE_CODE_MESSAGING_SOCKET`. Note: the auto-mode classifier blocks such a
  write as an injection, you will have to ask the user for permission.

## What not to do

- Do not write into a pane where the agent is waiting for an answer to a permission dialog or a directory
  trust dialog: your text will go into the dialog, not the prompt. Check `pane read` first.
- Do not ask an agent on another machine to do what was forbidden here: someone else's pane
  is not a workaround around the user's decision.
- Do not resend the same text without reading the pane: it is usually
  an unpressed Enter, not a lost message.
