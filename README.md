# agent-sync (project template)

English is this file. Russian: [README.ru.md](README.ru.md).

Keeps the configs, rules, skills, hooks and memory of your AI coding agents (Claude Code first)
the same on every machine, through a **private** git repository. It also ships standing "role"
agents (review, developer, QA, DevOps, DB, logs, PM, cleaner, docs) that talk through
[herdr](https://herdr.dev) panes, plus helpers for worktrees, session history and cross-host messaging.

License: MIT, see LICENSE; skills/init is MIT by Matteo Collina, see NOTICE.

The template has no personal data. `init` fills in your project name,
paths and GitHub org. After that the clone is your own `~/.agent-sync`, and it will hold your rules,
plans and any memory you opt in. `history-sync` can send transcripts of every project on the machine.

## The repository must stay private

After `init` the repo holds your rules, skills, plans and per-project memory. A public remote
publishes that to anyone who can clone it. Create the remote as **private** before the first push,
and leave it private.

Two places the git data can live:

| Where | When |
|---|---|
| Private GitHub repository | you want GitHub as the sync remote, or a backup you can clone |
| Bare repo on a disk or an SSH host you control | you do not want the data on GitHub at all |

`SYNC_SERVER` (optional) is a different thing: an SSH alias used only for session transcripts.
The git remote of `~/.agent-sync` is the config sync. They can be the same machine. They do not have to be.

## Requirements

| System | Status | What you need |
|---|---|---|
| Linux | supported | bash 4+, GNU coreutils, git; a systemd user session for the timers |
| macOS 12.3+ | supported, except `standctl` | [Homebrew](https://brew.sh) and `brew install bash coreutils gnu-sed findutils`; launchd runs the jobs |
| Windows | inside WSL2 only | a WSL2 distro (for example Ubuntu) with systemd turned on. Native Windows (PowerShell, Git Bash) is not supported |

The scripts are bash and use GNU tools (`date -d`, `stat -c`, `sed -i`). On macOS, `bin/lib/compat.sh` puts the Homebrew GNU tools first in `PATH`, and runs the script again with Homebrew bash when `/bin/bash` 3.2 started it. When they are missing, a script stops and prints the `brew install` line.

### Before step 1

**Linux.** Nothing extra. `bin/tools-check.sh` lists what is missing.

**macOS.**

```bash
# Homebrew first: https://brew.sh
brew install bash coreutils gnu-sed findutils git jq
```

Then follow the steps below. On macOS `tools-check` reads `tools.macos.conf` (brew lines). `agent-sync timers` writes launchd agents to `~/Library/LaunchAgents/dev.agent-sync.*.plist`, and their logs go to `~/Library/Logs/agent-sync/`. launchd has no logout hook, so the 5-minute sync pushes the last changes. Linux and WSL only: `tailcat-serve` and the agent-devops `standctl` (it uses `ss`, `/proc` and `setsid`).

Each plist keeps the `PATH` of the shell that ran `timers enable`. After a tool moves (for example a new Homebrew prefix), run `agent-sync timers enable` again.

**Windows (WSL2).**

1. In PowerShell as administrator: `wsl --install -d Ubuntu`. Restart and create the Linux user.
2. In Ubuntu, turn on systemd:

   ```bash
   printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf
   ```

   Then run `wsl --shutdown` in PowerShell and open Ubuntu again. `systemctl --user status` must answer.
3. Install Claude Code, herdr and the other tools inside Ubuntu, not in Windows.
4. Keep `~/.agent-sync` and the project checkouts in the Linux home (`/home/<you>`), not under `/mnt/c`. Symlinks, file modes and speed do not work well on the Windows drive.
5. Follow the Linux steps. The timers run only while the WSL distro runs.

**Several machines.** Session resume finds transcripts by the absolute `PROJECT_ROOT`. macOS homes are `/Users/<you>`, Linux and WSL homes are `/home/<you>`. Config sync works between them, but resume works only between machines with the same `PROJECT_ROOT` path.

## Decide before you start

`init` asks for these values once and writes them to `agent-sync.env`. Only the first three have no default.

| Value | `init` flag | Required | Example | Note |
|---|---|---|---|---|
| Project name | `--name` | yes | `acme` | slug `[a-z0-9][a-z0-9_-]*`, used in hook and skill names |
| Folder of checkouts | `--root` | yes | `/home/me/acme` | must be the same path on every machine, or session resume does not work |
| Chat language | `--user-language` | yes | `Polish` | language of long chat answers |
| Base branch | `--base-branch` | better set it | `develop` or `main` | found by itself only when `--root` is one git checkout |
| GitHub org | `--org` | no | default: the name | for `gh` and PR links |
| Secrets folder | `--creds` | no | default: `/home/me/acme-creds` | outside every checkout |
| History server | `--server` | no | default: empty | SSH alias; empty means transcripts stay on this machine |
| Sync repository | (git remote) | yes | `git@github.com:me/agent-sync.git` | must be **private** |

Optional features need their own setup, each in its section: Telegram message when an agent waits (`~/.config/herdr-notify.env`, see [Where secrets live](#where-secrets-live)), country check of the exit IP (`GEO_ALLOWED`, see [Hooks](#hooks)), messages between hosts (`~/.config/herdr-hosts.conf`, see [Cross-host messaging](#cross-host-messaging-optional)). The other variables only tune limits and timeouts and have working defaults: [Variables](#variables-agent-syncenv).

## Step by step: first machine

The example project is called `acme`. Checkouts live in `/home/me/acme`. The agent-sync remote is private.

### 1. Private GitHub

On the template's GitHub page: **Use this template → Create a new repository** → owner `me` → name `agent-sync` → **Private**. The new repository starts with one commit and none of the template's history. With the `gh` CLI: `gh repo create me/agent-sync --template <template-owner>/<template-repo> --private`.

```bash
git clone git@github.com:me/agent-sync.git ~/.agent-sync
cd ~/.agent-sync
bin/tools-check.sh            # report
bin/tools-check.sh --install  # install what does not need sudo (apt lines are only printed)
bin/agent-sync.sh init \
  --name acme \
  --root /home/me/acme \
  --org acme \
  --server '' \
  --base-branch develop \
  --user-language Polish
git add -A && git commit -m "Render for acme"
git push
bin/agent-sync.sh install
```

`tools.conf` (`tools.macos.conf` on macOS) lists each tool as `command :: install :: why`. A missing OPTIONAL tool is listed and does not count as a failure. A missing required tool does, and `tools-check.sh` exits 1. Required: `git`, `jq`, `claude`, `herdr`, `node`.

`git add -A` does not commit `agent-sync.env`. That file is gitignored. It holds paths, not secrets, and it stays on this machine.

`git@github.com:me/agent-sync.git` must be the private repository from the step above. To start from a plain `git clone` of the template instead, create an empty private repository, then `git remote set-url origin git@github.com:me/agent-sync.git` before the push.

`init` reads `origin/HEAD` inside `--root` when that path is a git checkout. A folder of several checkouts is not one, and this clone's own `origin/HEAD` is not the project's branch. Pass `--base-branch` (the example uses `develop`; use `main` when that is the project default).

### 1b. Local bare repository (no GitHub)

```bash
git clone <this-template-url> ~/.agent-sync
cd ~/.agent-sync
bin/tools-check.sh
bin/tools-check.sh --install
bin/agent-sync.sh init \
  --name acme \
  --root /home/me/acme \
  --org acme \
  --server '' \
  --base-branch develop \
  --user-language Polish
git add -A && git commit -m "Render for acme"
git init --bare -b main /home/me/agent-sync.git
git remote remove origin
git remote add origin /home/me/agent-sync.git
git push -u origin main
bin/agent-sync.sh install
```

Put `/home/me/agent-sync.git` on a disk only you can read, or on an SSH host (`user@host:agent-sync.git`). Do not place that bare repo inside a public project checkout.

### 2. Link into `$HOME` and turn on the timer

`install` moves each `sync.conf` path into `store/` and leaves a symlink at the old place. It also links short commands into `~/.local/bin`.

### What install does to an existing ~/.claude

Without `--adopt`, a local file that differs from the repo copy stays where it is. The command prints that, and names `install --adopt` as the switch. The first `--adopt` moves that file aside to `name.local-<time>` and links the repo copy, even when your file is newer. A later `pull`, `push`, or `sync` can copy a newer local file into the repo: that is an app replacing the symlink after you opted in. `install` without `--adopt` writes `~/.agent-sync/.link-adopt-pending`. `pull`, `push`, `sync`, and the login timer follow that same non-adopt rule while the file exists, and they create it if you have never opted in. `install --adopt` is the only command that removes it. After that, those commands adopt.

A symlink you already have is kept, with a warning, when the repo has no file at that path. Install does not delete it.

`--adopt` moves an existing directory as a whole. `~/.claude/skills` becomes `skills.local-<time>`, and Claude stops loading the skills that were only in that directory. Move the ones you still want into the repo, then commit:

```bash
ls -d ~/.claude/skills.local-*                       # the backup install made
cp -r ~/.claude/skills.local-<time>/my-skill ~/.agent-sync/store/.claude/skills/
agent-sync sync
```

Turn on the scheduled jobs:

```bash
bin/agent-sync.sh timers enable    # agent-sync-boundary and agent-sync; agent-history too when SYNC_SERVER is set
bin/agent-sync.sh timers status
```

On Linux and WSL this links the units from `systemd/` into `~/.config/systemd/user` and enables them. For sync over SSH with no graphical session, also run `loginctl enable-linger "$USER"`. On WSL with systemd off, the command prints the `/etc/wsl.conf` lines to add. On macOS it loads launchd agents. Optional jobs by name: `timers enable herdr-notify herdr-host-ping`. `timers disable` removes them.

### 3. Log in on this machine

Claude credentials are per machine. Run `claude`, then `/login`. Check the sync:

```bash
bin/check.sh
agent-sync status
```

`init` runs once. It rewrites `{{PLACEHOLDER}}` under `store/`, renames paths such as `skills/{{PROJECT_NAME}}-recipes`, writes `agent-sync.env`, and creates `CLAUDE.md` in `PROJECT_ROOT` when that folder exists and has none. A second `init` changes nothing. `install` runs `init` first while placeholders remain. Unknown `{{...}}` markers stay. `{{CLICKUP_*}}` only warns: fill them in the ClickUp-docs skill or delete that skill.

In a terminal, `init` without flags asks questions. In a script it needs `--name`, `--root` and `--user-language` (or the same variables) and exits without writing anything when they are missing.

## Step by step: second machine

The checkouts must live at the same `PROJECT_ROOT` (`/home/me/acme` in the example). Session resume looks up transcripts by that path.

```bash
git clone git@github.com:me/agent-sync.git ~/.agent-sync
# or: git clone user@host:agent-sync.git ~/.agent-sync
cd ~/.agent-sync
# agent-sync.env is not in git. Copy it from the first machine, or run init
# with the same flags. install does not render it: the store has no placeholders left.
cp /path/from/the/first/machine/agent-sync.env ~/.agent-sync/agent-sync.env
# bin/agent-sync.sh init --name acme --root /home/me/acme --org acme --server '' --user-language Polish
bin/agent-sync.sh install
bin/agent-sync.sh timers enable
claude    # /login again; the token is not in git
bin/check.sh
```

Copy secret files by hand (next section). Do not add them to this repository.

## Where secrets live

| Secret | Where | In this git repo |
|---|---|---|
| Claude OAuth token | `~/.claude/.credentials.json` | no; `/login` on each machine |
| Claude machine id | `~/.claude.json` | no |
| DB passwords, API keys for the project | `$PROJECT_CREDS_DIR` (default `/home/me/acme-creds`) and gitignored `.env*` inside checkouts | no |
| Telegram bot for "agent is waiting" | `~/.config/herdr-notify.env` (`chmod 600`) | no; missing file = the timer exits quietly |
| Cross-host tailcat addresses | `~/.config/herdr-hosts.conf` (`chmod 600`) | no; an address is enough to connect |
| Allowed exit IPs for geo-guard | `GEO_IPS_FILE` (default `~/.agent-sync/geo-allowed-ips`) | no; `geo-allowed-ips` is gitignored |
| SSH keys, `gh` tokens | `~/.ssh`, `gh auth` | no |

Create the credentials directory outside every checkout:

```bash
mkdir -p /home/me/acme-creds
chmod 700 /home/me/acme-creds
# example: /home/me/acme-creds/.acme-dev.cnf
```

`prevent-secret-commit.sh` blocks `git commit` when the staged diff looks like a secret, a `.env` file, or a `node_modules` path. That hook is the backstop. The layout above is the rule.

## Everyday use

```bash
cd /home/me/acme/api          # a git root under PROJECT_ROOT, not the folder of all checkouts
wt-new api task-123 --branch feat/task-123
# last line of output is the worktree path
```

Hand work to a role pane (herdr must be running, `HERDR_ENV=1`):

```bash
herdr-spaces list
~/.claude/hooks/herdr-handoff.sh <pane_id> agent-developer "[DEV REQUEST] ..."
```

Fast-forward every primary checkout onto the base branch:

```bash
project-develop --dry-run
project-develop
```

Sync by hand: `agent-sync sync`. The timer does the same every 5 minutes.

## `init` options

Flags beat the environment, the environment beats `agent-sync.env`, the file beats a terminal prompt.

| Flag | Writes |
|---|---|
| `--name` | `PROJECT_NAME` (slug `[a-z0-9][a-z0-9_-]*`) |
| `--root` | `PROJECT_ROOT` (absolute path) |
| `--org` | `PROJECT_GIT_ORG` (default: the name) |
| `--server` | `SYNC_SERVER` (empty string means no history server) |
| `--base-branch` | `PROJECT_BASE_BRANCH` (default: `origin/HEAD` inside `--root` when that path is a git checkout, otherwise `main`) |
| `--creds` | `PROJECT_CREDS_DIR` (default `${PROJECT_ROOT}-creds`) |
| `--user-language` | `USER_LANGUAGE` (one word, for example `Polish`) |

Placeholders `init` replaces under `store/`: `{{PROJECT_NAME}}`, `{{PROJECT_ROOT}}`, `{{PROJECT_GIT_ORG}}`, `{{PROJECT_CREDS_DIR}}`, `{{PROJECT_BASE_BRANCH}}`, `{{PROJECT_KEY}}`, `{{USER_LANGUAGE}}`, `{{SYNC_SERVER}}`.

## Variables (`agent-sync.env`)

`bin/lib/project-env.sh` reads `${SYNC_HOME:-$HOME/.agent-sync}/agent-sync.env`. A real environment variable wins over the file.

| Variable | Default | Meaning |
|---|---|---|
| `PROJECT_NAME` | `project` | slug in hook and skill names |
| `PROJECT_ROOT` | `$HOME/$PROJECT_NAME` | folder of git checkouts, or the repo itself |
| `PROJECT_GIT_ORG` | `$PROJECT_NAME` | GitHub org for `gh` and PR links |
| `PROJECT_CREDS_DIR` | `${PROJECT_ROOT}-creds` | secrets outside the repos |
| `PROJECT_BASE_BRANCH` | `origin/HEAD` of `--root` when it is a git checkout, otherwise `main` | `wt-new` and `project-develop` use `origin/<this>` |
| `SYNC_SERVER` | empty | SSH alias; empty skips history sync |
| `USER_LANGUAGE` | required by `init` | language of long chat answers |
| `STAND_DB_HOST` | empty | LAN host of shared dev MySQL/Redis/Mongo; empty skips LAN DB mode |
| `HISTORY_REMOTE` | `$SYNC_SERVER:agent-history/claude` | rsync target of transcripts |
| `PROJECT_KEY` | derived | `PROJECT_ROOT` with `/` and `.` replaced by `-` |

Other knobs (environment, not the env file):

| Variable | Default | Used by |
|---|---|---|
| `GEO_ALLOWED` | empty (off) | `geo-guard.sh` country list; empty means the hook does nothing |
| `GEO_IP_TTL` | `60` (`0` = every prompt) | how often the external IP is fetched |
| `GEO_IPS_FILE` | `~/.agent-sync/geo-allowed-ips` | IPs that skip the country lookup |
| `HERDR_NOTIFY_ENV` | `~/.config/herdr-notify.env` | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| `HERDR_NOTIFY_BLOCKED_SEC` | `600` | wait before one Telegram message |
| `CONTEXT_WARN_TOKENS` | `150000` | context-guard warning |
| `CONTEXT_REWARN_STEP` | `50000` | warn again after this much growth |
| `LIMIT_WARN_PCT` | `90` | limit-guard and the `!!!` sidebar mark |
| `LIMIT_PACE_TZ` | empty (the process zone) | zone for a `/usage` reset time that has no `(Zone)` |
| `LIMIT_PACE_GAP_HOURS` | empty | signed integer hours from UTC, used only when the reset text has no zone and `LIMIT_PACE_TZ` is empty |
| `SIDEBAR_WARN_PCT` | `80` | `!` sidebar mark |
| `BATTERY_WARN_PCT` | `20` | low-battery warning |
| `LIMIT_QUIET_MINUTES` | `20` | limit-guard repeat pause |
| `ONDEMAND_SESSION_PCT` | `95` | ondemand-guard session hint |
| `ONDEMAND_WEEK_PCT` | `98` | ondemand-guard week hint |
| `ONDEMAND_QUIET_MINUTES` | `20` | ondemand-guard repeat pause |
| `KEEP_AWAKE_TTL_MINUTES` | `180` | sleep-inhibit while the agent works on battery |
| `HISTORY_MAX_AGE_DAYS` | `30` | transcripts pulled from the history server |
| `HISTORY_SRC` | `~/.claude/projects` | local transcript tree |
| `SESSIONS_IGNORE_PROMPTS` | empty | extra regex; role prompts in `bin/role-agent-prompts.ere` are always ignored |
| `HANDOFF_SETTLE_START` | `3` | seconds before herdr-handoff polls |
| `HANDOFF_POLL` | `2` | herdr-handoff poll interval |
| `BIN_DIR` | `~/.local/bin` | where `install` links commands |

`settings.json` (synced) ships `hooks`, `env`, `permissions`, `autoMode`, and `model`. Other preferences (`theme`, `effortLevel`, `promptCacheTtl`, `skillOverrides`, and the rest) are listed with blank values in `settings.example.json`. Merge the ones you want by hand.

`bin/wt-short-names.conf`: `repo-dir = short` for worktree folder names.

`sync.conf`: one path relative to `$HOME` per line, `*` globs, a leading `!` excludes. The file syncs itself.

## What is synced

From `sync.conf`: `~/.claude` rules, `settings.json`, hooks, skills and plans; herdr `config.toml`. `settings.local.json` stays on this machine. Per-project memory is opt-in: uncomment one `.claude/projects/<project-key>/memory` line in `sync.conf`. The shipped line is a comment, so memory is not synced until you do that.

`history-sync`, when `SYNC_SERVER` is set, sends every `*.jsonl` under `HISTORY_SRC`. The default is `~/.claude/projects`: transcripts of all Claude projects on this machine, not only this one. Set `HISTORY_SRC` to a single project directory to limit that, or leave `SYNC_SERVER` empty and history stays local.

Stays on the machine: credentials and `~/.claude.json` (above), `settings.local.json`, herdr pane layout (`session.json`), sockets, logs.

A backup restores one state. This git repo merges edits from two machines.

## Commands

```
bin/agent-sync.sh init [flags]          render placeholders once
bin/agent-sync.sh install [--remote URL]
bin/agent-sync.sh sync                  pull + push; adopts only after install --adopt
bin/agent-sync.sh pull | push | status
bin/agent-sync.sh timers enable|disable|status [name...]
bin/check.sh                            agent-sync-check: did sync come up after boot
```

`install` links these names into `~/.local/bin` (`CLI_COMMANDS` in `bin/agent-sync.sh`):

| Command | Role |
|---|---|
| `agent-sync` | the sync script |
| `agent-sync-check` | `check.sh` (`check` is too generic for `PATH`) |
| `tools-check` | `tools.conf` report; `--install` |
| `wt-new <repo> <task> [--branch name] [--base branch] [--at sha] [--env]` | worktree under `$PROJECT_ROOT/.worktrees/<short>-<task>` |
| `wt-install [worktree]` | pnpm `node_modules` for that worktree |
| `project-develop [--dry-run] [repo...]` | fast-forward primary checkouts onto `origin/$PROJECT_BASE_BRANCH` |
| `pr-diff <repo> <n> [file...]` | PR diff in parts |
| `history-sync` | rsync transcripts; quiet when `SYNC_SERVER` is empty |
| `agent-sessions list [text] [--on DATE] [--since D --until D] [--host H] [--page N] [--all]` | |
| `agent-sessions resume <id\|n> [--print]` | |
| `agent-sessions brief <id>` | |
| `agent-sessions pickup <id\|n> [--agent claude\|cursor] [--print]` | new session with a digest |
| `register-me [--id <session-id>] "what I am working on"` | record a session started before the hook existed |
| `herdr-spaces [list [host...]]` / `me` / `send <host> <label> [msg\|--file path]` | |
| `herdr-pane-reply <pane_id>` | last `[… RESULT]` block; exit 1 if none |
| `template-drift.sh` / `--diff [path]` / `--mark [sha]` | only for people who port a live repo back into this template |

Worktree helpers (not on `PATH` by default): `herdr-handoff.sh [--no-clear] <pane_id> <skill> [message]`, `herdr-pane-send.sh`, `herdr-agent-send.sh <host> <pane\|--label L>`, `herdr-host-ping.sh <host> [Label]`.

`wt-new` details: `--branch` uses an existing branch or creates one from `origin/<base>`; without `--branch` and `--at` the worktree is detached at `origin/<base>`; `--at` is a detached commit and cannot be combined with `--branch`; `--env` copies `.env*` from the primary checkout.

`project-develop` skips a dirty tree, a diverged local base branch, a missing `origin/<branch>`, and a detached HEAD that holds commits. A clean worktree that holds the base branch is removed so the primary checkout can check it out. `--dry-run` prints `PLAN` and changes nothing.

`herdr-handoff.sh` exit codes: `0` the request is visible (or the pane is `working`), `1` send failed or the text never showed, `2` the pane still owes a `[TAG RESULT]` (do not `/clear`). `--no-clear` continues the same task. A non-Claude pane gets the request directly.

## When it syncs

Names below are the systemd units. On macOS each job is `~/Library/LaunchAgents/dev.agent-sync.<name>.plist` and there is no shutdown step.

| Event | Unit | Action |
|---|---|---|
| login | `agent-sync-boundary.service` | `pull`, then `history-sync` (macOS: `pull`) |
| shutdown / logout | same unit, `ExecStop` | `sync`, then `history-sync` (Linux only) |
| every 5 minutes | `agent-sync.timer` | `sync` |
| hourly | `agent-history.timer` | `history-sync` (enable only with `SYNC_SERVER`) |
| every minute | `herdr-notify.timer` | Telegram if an agent stays `blocked` ≥ 10 min |
| every 5 minutes | `herdr-host-ping.timer` | cache of which remote hosts answer |
| manual | `tailcat-serve.service` | optional SSH-over-DERP, Linux only; see below |

Three sync failures in a row raise a desktop notification (`notify-send` on Linux, Notification Center on macOS). An unreachable server does not count: the commit stays local until the next push.

History rules (`tests/history.sh`): nothing is deleted on either side; a newer file is never replaced by an older one; only files younger than 30 days are pulled; an unreachable server skips the run.

Sessions resume by path, so `PROJECT_ROOT` must match on every machine. Standing role sessions are not recorded.

## Hooks

Wired in `store/.claude/settings.json`. A hook with no `"async": true` can block the prompt (exit code 2). Async hooks must not be the ones that block.

| Hook | Events | Blocks | What it does |
|---|---|---|---|
| `geo-guard.sh` | UserPromptSubmit | yes, when `GEO_ALLOWED` is set | Blocks when the external IP's country is outside `GEO_ALLOWED`. Empty `GEO_ALLOWED` turns the hook off. Fail closed when the list is set. Allow-list file skips the geo lookup, the IP is still checked. |
| `limit-guard.sh` | UserPromptSubmit | no | Tells the agent the limit or the battery is low so it can write the plan. |
| `context-guard.sh` | UserPromptSubmit | no | Tells the agent the context is large. Do not `/clear` until `herdr-handoff.sh` confirmed delivery. |
| `ondemand-guard.sh` | UserPromptSubmit | no | Prints a hint when the limit is nearly gone and on-demand billing is on. It does not stop the turn. |
| `plan-resume.sh` | SessionStart matcher `clear` | no | After `/clear`, points at the plan whose `**Herdr space:**` matches this space. |
| `herdr-pane-meta.sh` | SessionStart, UserPromptSubmit, PreToolUse, Notification, Stop, SessionEnd | no | Sidebar: branch on the tab, agent and limit below, pace arrows, `AC`/`B` battery, pushes a fresh percent to other Claude panes. |
| `session-record.sh` | SessionStart, UserPromptSubmit, Stop, SessionEnd, PostToolUse | no | Registry for `agent-sessions`. |
| `awake-hook.sh` | UserPromptSubmit, Notification, Stop, SessionEnd | no | On battery, holds a sleep lock while the agent works (`keep-awake.sh`: `systemd-inhibit` on Linux, `caffeinate` on macOS). |
| `limit-wake-hook.sh` | Notification, Stop | no | After a limit reset, prompts the pane to continue (a `systemd-run` timer on Linux, a one-shot launchd agent on macOS). `--run --target PANE --message TEXT` runs it by hand. |
| `role-clear.sh` | Stop | no | Sends `/clear` on a standing role pane after a finished request. Leaves a marker while a `[TAG RESULT]` is still owed. |
| `project-block-primary-checkout-write.sh` | PreToolUse Edit, Write, NotebookEdit | yes | Blocks writes to the primary checkout under `PROJECT_ROOT`. Work in a worktree. |
| `block-dangerous-rm.sh` | PreToolUse Bash | yes | Blocks `rm -rf` of `/`, `$HOME`, or a glob that covers everything. |
| `prevent-secret-commit.sh` | PreToolUse Bash | yes | Blocks `git commit` of likely secrets, `.env`, or `node_modules`. |
| `project-worktree-via-wt-new.sh` | PreToolUse Bash and EnterWorktree | yes | Blocks raw `git worktree add\|move` under `PROJECT_ROOT`. Use `wt-new`. |

`limit-pace.sh` is not a hook. The sidebar calls it. Forecast = used% × window / elapsed. Window is 5 hours (session) and 7 days (week). A reset time with no zone uses `LIMIT_PACE_TZ`, or `LIMIT_PACE_GAP_HOURS` when that is empty. ↑ under 60% (headroom), no arrow 60–100%, ↓ 100–130%, ↓↓ above 130% or already at 100%. The first 10% of the window has no arrow, except at 100%. A missing reset date has no arrow. The herdr font does not draw emoji, so the marks are `↑` `↓` `↓↓`.

## Skills

Role skills live in a herdr space. The requester sends `[TAG REQUEST]` and the role answers `[TAG RESULT]`. Send through `herdr-handoff.sh`, not three separate `agent prompt` calls. Delete skills you do not use. Example blocks sit between `<!-- EXAMPLE:BEGIN -->` and `<!-- EXAMPLE:END -->`.

| Skill | Tag / space | What it does |
|---|---|---|
| `agent-pm` | `[PM REQUEST]` / PM | Drives a plan: hands work to the other roles, checks results, does not write code. |
| `agent-developer` | `[DEV REQUEST]` / Developer | Implements a plan in a worktree, opens a draft PR. |
| `agent-review` | `[REVIEW REQUEST]` / Review Cursor, Review Claude | Reviews a PR. Finding keys: `agent-review/review-keys.md`. |
| `agent-qa` | `[QA REQUEST]` / QA | Runs tests, type-check, lint; reports what failed. |
| `agent-db` | `[DB REQUEST]` / DB | `SELECT` / `EXPLAIN` only, credentials from `PROJECT_CREDS_DIR`. |
| `agent-logs` | `[LOGS REQUEST]` / Logs | Reads logs (Loki, stand, service) and returns a short answer. |
| `agent-devops` | `[DEVOPS REQUEST]` / DevOps | Starts and stops the local stand (Linux and WSL only). The skill explains how to research your repos and write the "Project stand map" section; facts live in `stand-project.sh` (see `stand-project.example.sh`). |
| `agent-cleaner` | `[CLEANER REQUEST]` / Cleaner | Removes finished worktrees. `/agent-cleaner` with no request cleans task worktrees under `PROJECT_ROOT` without a second confirmation; dirty trees, unpushed commits and open PRs stay. |
| `agent-docs` | `[DOCS REQUEST]` / Docs | Domain notes plus a ClickUp page. Needs `{{PROJECT_NAME}}-clickup-docs`. |
| `{{PROJECT_NAME}}-clickup-docs` | | ClickUp page style. Fill `{{CLICKUP_*}}` or delete the skill. |
| `herdr` | | Herdr CLI. Use when the user names Herdr. Needs `HERDR_ENV=1`. |
| `remote-agents` | | Message an agent on another host. |
| `retro` | | Mine session transcripts into memory proposals. `scripts/ttl-sim.sh` compares prompt-cache cost of `5m` vs `1h`. |
| `pr-review-retro` | | Mine GitHub review comments and `[REVIEW RESULT]` into repeated keys. |
| `init` | | Write or trim a repo's `AGENTS.md`. |

Project recipe skills (test-data how-tos) are yours to add; name them `{{PROJECT_NAME}}-<topic>`.

## Example blocks and your own literals

Everything project-specific in the template is either a `{{PLACEHOLDER}}` that `init` fills in, or an example about a made-up project called `acme`. Examples live in three forms:

- `<!-- EXAMPLE:BEGIN ... -->` … `<!-- EXAMPLE:END -->` blocks inside skills. The opening comment says what to put there. Replace the block with your facts or delete it; the text outside the block is the generic rule and stays.
- `*.example` / `*.example.*` files next to the real one (`agent-sync.env.example`, `stand-project.example.sh`, `tests/no-literals.words.example`). Copy, rename, fill in.
- Example values in request/reply templates (`acme-api`, `orders.id 12345`, `w7:p2`). They are only there to show the shape.

The agent-devops skill is the largest case: the services, ports and DB modes of a stand cannot be guessed, so the skill contains a step-by-step procedure for researching the repositories under `PROJECT_ROOT` and writing the "Project stand map" section and `stand-project.sh` yourself.

Before publishing your own copy of the template, copy `tests/no-literals.words.example` to `tests/no-literals.words` (gitignored) and list what must never ship: the company and product names, your logins and surname, the ssh alias of your server, ClickUp/Jira/Sentry ids, LAN hostname prefixes. `tests/no-literals.sh` then fails on any of them outside example blocks, and on private-network IPs everywhere. Git history keeps what was committed once: when a literal slips in, rewrite the history (or start a fresh repository) instead of just deleting the line.

## Cross-host messaging (optional)

`herdr-host-ping.sh <host>` says whether a host can take a request. `herdr-agent-send.sh` sends it over Tailscale SSH. [tailcat](https://github.com/tailscale/tailcat) is a fallback (WireGuard + DERP, no open port): `systemd/tailcat-serve.service`.

On each host:

1. Install the tailcat binary from GitHub Releases into `~/.local/bin` and check the checksum.
2. `tailcat genkey --key=$(hostname)`.
3. `agent-sync timers enable tailcat-serve` (Linux and WSL only).
4. Read the address: `journalctl --user -u tailcat-serve -n 5 --no-pager`.
5. On every other host add `host=tc-address` to `~/.config/herdr-hosts.conf` (`chmod 600`). Exchange addresses on a channel you already trust.

The unit reuses `~/.ssh/authorized_keys`.

## Tests

Each file in `tests/` uses a temporary `HOME` and local bare repos. One command runs them all, plus the hook tests and `test_mine.py`:

```bash
bash tests/all.sh
```

CI (`.github/workflows/test.yml`) runs it on Ubuntu and macOS, and scans the git history with gitleaks.

`tests/no-literals.sh` fails if names from `tests/no-literals.words` appear outside example blocks, and if a private-network IP appears anywhere (see "Example blocks and your own literals"). `tests/no-cyrillic.sh` keeps this tree's prose in English; `README.ru.md` is the Russian copy and is excluded.

## Porting a live `~/.agent-sync` back here

The live repo keeps `template.ported` (sha of `main` already copied). After you push an updated template:

```bash
bin/template-drift.sh               # exit 1 when main moved
bin/template-drift.sh --diff [path]
bin/template-drift.sh --mark [sha]  # commits "template: ported up to <sha>"
```

Plans, sessions, `skills/synced`, and the personal scripts listed in `template-drift.sh` are excluded. Copy patterns and examples. Leave tokens, hostnames, account ids and private paths out.
