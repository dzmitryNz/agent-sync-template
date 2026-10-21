## Language

The user's native language is {{USER_LANGUAGE}}. Chat with the user is split by size: large analyses, explanations and
multi-part answers in {{USER_LANGUAGE}} (the user reads them closely); short replies, status lines and
one-sentence answers in English (cheaper, and the user is moving to English over time).
Everything that goes to GitHub (PRs, comments, commits, issues): English only.

The split works per piece, not per message. A long {{USER_LANGUAGE}} answer still opens with its
one-line result and closes with its question in English ("Done: both new tests fail on the old
script and pass on the new one." / "Run daemon-reload and check a live notification?"). Any
English text for the user is plain English, level B1: short sentences, common words, no idioms,
no phrasal verbs where a plain verb exists, no jargon the user did not use first. The user
should never get stuck on a sentence that is simple to say in English.

Everything the model reads, not the user, is written in English: instructions (AGENTS.md, skills),
memory files, plans, inter-agent messages (`[REVIEW REQUEST]`, `[DEV REQUEST]`, etc.). Reason: Claude's
tokenizer spends ~3x more tokens on {{USER_LANGUAGE}} than on English, and these files load every session.
Quote {{USER_LANGUAGE}} only when it is a literal (UI text, a user's phrase).

## Reply verbosity

In chat: short and to the point. No preambles ("Sure!"), no polite closings or "hope this helps",
no unsolicited advice beyond the question. Length matches the complexity of the question: a one-line
fix needs no paragraph of explanation, and a multi-step task must not be cut down to the point of
losing meaning. Code changes are surgical (Edit), not whole-file rewrites, unless a refactor was requested.

## Credentials

Never store passwords, tokens or keys on your own initiative anywhere: not in CLAUDE.md/AGENTS.md,
not in memory files, not in `settings*.json` (including inside permissions rules), not in the scratchpad.
If access is needed, ask the user and use it within the session only. Standard credential stores:
gitignored `.env*` next to the service and `{{PROJECT_CREDS_DIR}}/` next to the {{PROJECT_NAME}} checkout
(outside it, not inside): `.{{PROJECT_NAME}}-{replica,dev,staging,pg}.cnf` and password files.
Connect via `--defaults-extra-file`; never put the password on the command line.

## Test-Driven Development

Default for new features and bug fixes: test first (RED), then minimal implementation (GREEN),
then refactor under green tests. The test is the specification: it removes misunderstanding before
work starts, so write it before asking questions about names and code placement.
Agree the test structure with the user before implementing.

No TDD needed for: obvious one-liners (typo, syntax) and refactoring already-covered code, where
tests act as a check, not a spec. Any other deviation from TDD requires the user's consent.

## Plans and limits

Start a plan as soon as it is clear the work won't fit in one or two steps, without waiting for it
to grow. In hindsight you always realize it too late: the conversation starts with a "small" request,
and an hour later it has a dozen files and no handoff point.

Run a multi-step task through a plan file. Default: `~/.claude/plans/<project>-<task>.md`:
it is personal, syncs between machines and doesn't drag a service file into the PR.
Put the plan into the repo's `docs/plans` only when someone else needs it: colleagues must review it,
or a big task is done by several people and needs shared context.

<!-- EXAMPLE:BEGIN optional tooling the author uses; delete or replace -->
ralphex doesn't conflict with a personal plan: pass the file as an argument
(`ralphex ~/.claude/plans/<plan>.md`), and `plans_dir` in the config accepts an absolute path.
A git root is needed only for the working directory: run from a specific repo, not from `{{PROJECT_ROOT}}/`.
ralphex moves a finished plan to `<plans_dir>/completed/`.

Format follows ralphex plans, because the agent picking up the task needs more than checkboxes:
<!-- EXAMPLE:END -->

```markdown
# <Task> — <what the changes are about>

**Date:** 2026-09-04
**Source:** review / tracker TASK-123 / bug analysis
**Implementation status:** code in worktree, not committed
**Herdr space:** api-cache

Branches:
- acme-api: `feat/<task>`
- acme-web: `feat/<task>`

PRs:
- [acme-api #12](link) — worktree `.worktrees/api-cache`
- [acme-web #34](link) — worktree `.worktrees/web-login-redirect`

Deploy order: **api → web**. Don't merge the web app before the API — otherwise <what breaks>.

## Before merge

### 1. <Short item title> — api #12 (required)

- [x] **api** — what exactly was done, in which file.
- [x] **api tests:** which cases are covered.
- [ ] **QA:** what to check manually.

<paragraph with the reason, if it is not obvious from the code>
```

Mandatory: date, implementation status (especially "not committed", otherwise the next agent will
look for a nonexistent commit), branches per repo (the `Branches:` list may stay empty when the plan
is created; add each branch as soon as it exists), PRs with worktrees, deploy order for cross-repo tasks, a repo tag
(a short repo name: **api** / **web** / ...) before every item. Tick items as you go, not at the end: the limit can
cut you off at any moment.

`**Herdr space:**` is the name of the space where the task runs: after `/clear` the `plan-resume.sh`
hook finds the plan by it and prompts the agent. So before `/clear`, append to the plan everything
that is not in the code and PR: answers from DB/Logs agents, decisions made, and rejected options
with the reason.

An `[agent-sync]` limit warning is a signal to first update the plan and write down where you
stopped and what the next step is, and only then continue. Plans sync between machines, so another
agent, on this computer or the second one, will pick the task up.

When a plan is ready for ExitPlanMode, immediately write a ready `[PM REQUEST]` message for the PM
agent in chat (skill `agent-pm`): task link, plan path, repos, essence, steps, deploy order.
Do not include this block in the plan file.

## Subagent models

Search subtasks ("find where X lives", "read and summarize", `Explore`) run with `model: haiku`;
if the search requires analyzing logic, `sonnet`. Review, planning and anything requiring judgment
run on the default model.

Reason: code search pulls tens of thousands of read-file tokens into context and returns a kilobyte
of result. The senior model's quality doesn't matter there, while its input costs 5x more.

`fork` inherits the parent's model; specifying one there is useless.

## Role models

Each role skill names a preferred model. That id is a preference, not a gate: a different model still runs the role. Name the actual model in the confirmation line. Do not stop, and do not ask for a switch, only because the id differs.

An optional flag file `~/.cache/agent-roles/any-model` (`touch` to set, `rm` to clear) lets the role run on a cheaper model than the preference when this machine is out of limits. It does not allow a more expensive model than the preference. The file is per machine and is not synced. With the flag, write `Model: <model> (any-model override)` in the confirmation line and as the first line of every `[* RESULT]`.

Cursor mechanical roles (DevOps, QA, Logs) prefer Composer. Review stays on Claude. Do not refuse a role only because the Cursor model id differs from the preference.

<!-- EXAMPLE:BEGIN optional tooling the author uses; delete or replace -->
## Code search: codegraph, not grep

The codegraph index covers the {{PROJECT_NAME}} repos. Therefore:

- "where is it defined / what is it": `codegraph_search`, `codegraph_node`;
- "how is it structured, where to start": `codegraph_context` (replaces a series of grep + file reads);
- "who calls it / what breaks": `codegraph_callers`, `codegraph_impact`;
- to view several related symbols: one `codegraph_explore` instead of a bunch of `Read`s.

`grep` and `find` stay for what is outside the index: logs, configs, migrations, texts, git history
search. Don't read a whole file when you need one symbol: `codegraph_node` returns only it.

When searching by text anyway, use `rg` with flags, not bare `grep -rn`: `rg -l` (file names only)
for "where does it occur", `rg -c` for counts, `--max-columns=200` against minified blobs.
Structural code search ("calls of X without await", "empty catch") is `ast-grep run -p '<pattern>'`
(exactly `ast-grep`, not `sg`, which is a different utility); codegraph can't do that.

Always use `gh` with `--json` and the needed fields, with `--jq` if necessary: `gh pr view N --json
title,state,reviewDecision` instead of `gh pr view N`. Without it, one call brings kilobytes of
excess.

Filter Bash output in place (`| tail`, `| head`, `grep`, `sed -n '100,200p'`) instead of dumping it
whole.

For `git diff`, start with `--stat`, then diff only the files you need.

## Saving steps and context

Source: benjamin-plus (github.com/JetBrains/benjamin-plus-skill), merged with the existing
codegraph/rg/gh rules above; don't duplicate them, extend them.

- **Reconnaissance in one pass.** Before edits, gather all independent facts in one go: several
  tool calls in one message, or commands joined by `;` with labeled sections (`echo '== deps ==';
  head -30 package.json`, quoted: in zsh a bare `==` fails with `= not found` and kills the whole
  chain with exit 1). A second round only for questions the first one raised. When copying a
  convention (schema, format, DSL), look at two examples of the construct, not one.
- **Check dependencies and environment with one probe, not error by error.** Before running code
  with several dependencies, check all at once and install the missing ones in one command, instead
  of catching traceback after traceback.
- **Green means the task's own check.** If the task names verification commands, run them as
  written; exit code 0 is done. A failure caused by the environment is still your fault: fix and
  rerun, don't write it off as "unrelated to my change". If the same check fails a second time with
  the same approach, the approach is wrong: name an alternative instead of patching the symptom
  further. When green, stop: no victory lap and no rereading of what you just wrote.
- **Polling is a step too.** A command that hasn't finished is not new information; every status
  check rereads the whole context. Wait in large intervals (from 30 seconds, minutes for
  builds/tests), don't hammer once a second.
- Don't build a verification harness/tests the task didn't ask for: verify the claim with the
  shortest command that measures it. If saving a step risks a wrong result, don't save:
  correctness and the task's explicit requirements matter more.

## Delegating to ralphex-cursor

Give mechanical work from a ready plan to the cursor-agent + mimo pair instead of doing it on the
main model: review fixes, migrations, adding tests, uniform changes across many files. Don't hand
off bug diagnosis, architectural decisions and tasks with implicit requirements: half the work there
is understanding what is happening.

```bash
cd <repository>                      # git root, not {{PROJECT_ROOT}}/
RALPHEX_CONFIG_DIR=~/.config/ralphex-cursor ralphex --worktree ~/.claude/plans/<plan>.md
```

`--worktree` is mandatory: the checkout is shared, and an autonomous agent in it will overwrite
others' changes.

Success condition is an executable plan: files, signatures, which tests must turn green, what counts
as done. A weaker model doesn't fill in what is left unsaid.

Two review rounds: the first is done by mimo inside the ralphex loop: mechanics, conformance to
the plan, forgotten imports, unclosed items. The second round is always Claude: `[REVIEW REQUEST]`
in space Review (skill `agent-review`) plus a test run. Don't run your own `/code-review` before it:
it is the same review twice, and `/code-review` is the most expensive skill anyway. Don't treat
mimo's review as final: it is a second weak model checking the first.
<!-- EXAMPLE:END -->

## {{PROJECT_NAME}}: QA and task completion

When working in a git repo under `{{PROJECT_ROOT}}/`, also read that repo's `CLAUDE.md` / `AGENTS.md` and
PR template.
<!-- EXAMPLE:BEGIN optional tooling the author uses; delete or replace -->
The separate file `{{PROJECT_ROOT}}/CLAUDE.md` (monorepo root, not git) holds only pointers for Cursor (memory, mimo); do **not** duplicate QA there.
<!-- EXAMPLE:END -->

A worktree for a task is created only via `wt-new <repo> <task> --branch <branch>` (puts it into
`{{PROJECT_ROOT}}/.worktrees/` and prints the path). Direct `git worktree add` / `move` and
Claude `EnterWorktree` are blocked by a hook in {{PROJECT_NAME}}.

Before a PR (if behavior, config or deploy changes):

1. **Deploy actions** in the PR description: env, secrets, migrations (a migration must be idempotent, and both the author and the reviewer check that a second run is a no-op), on which environments;
   ping DevOps if anything must be done by hand.
2. **Do not edit** a frozen checklist file if the repo has one: parallel PRs collide on a shared
   unreleased section.
3. **QA verification**: scenarios in the PR (`## QA verification`) **and** as a comment on the
   linked tracker task. Format: Precondition → Action → Expected → Where to observe.

When the task is done (or the user says "task completed"), leave **one comment** on the tracker task:

- **PRs**: links to all PRs (repo + URL).
- **QA verification**: the same scenarios as in the PR (or one shared list for several PRs).

Do **not** write the deploy order on the tracker and do **not** duplicate Deploy actions: those go only
on the PR (and the cross-repo order, if the team records it there).
