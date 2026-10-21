---
name: pr-review-retro
description: Analyzes reviewer comments from merged GitHub PRs and results of the agent-review reviewer ([REVIEW RESULT] in transcripts), classifies recurring fixes by bug category and proposes memory (or skill/MCP improvements) so the same mistakes are not repeated. Use when the user asks to review recurring code-review feedback, learn from past PR comments, reduce repeated review fixes, or improve skills/tools based on review history. Triggers: pr review retro, recurring reviewer comments, do not repeat a review mistake.
---

# /pr-review-retro — learn from code-review comments

The goal is the same as the retro skill: turn recurring fixes into **memory**, not into a report.
The difference is the source: not session transcripts, but (1) results of the agent-review reviewer
(`[REVIEW RESULT]`) and (2) real reviewer comments in GitHub.

## 0. Read the previous protocol

The latest file in `~/.claude/skills/pr-review-retro/retros/`. Its "Actions" table is a
list of hypotheses "this action will remove the key". In step 2 first check whether
those keys show up in reviews after the protocol date. The escalation rule is written at the end of the protocol.

## 1. Collect signals

The two scripts are independent and can run in parallel:

```bash
python3 ~/.claude/skills/pr-review-retro/scripts/mine_review_results.py --min-repeat 2
python3 ~/.claude/skills/pr-review-retro/scripts/mine_pr_reviews.py -n 15 --min-repeat 1
```

`mine_review_results.py` is the main source. The agent-review reviewer sends its result only
to the herdr pane, not to GitHub, so the script reads `[REVIEW RESULT]` directly from the
transcripts of all `~/.claude/projects/{{PROJECT_KEY}}*` (the root and service
subdirectories), discarding blocks without `Verdict:` (those are the author's reports about fixes). It groups findings
by the key `[<category>/<key>]` from `~/.claude/skills/agent-review/review-keys.md` — a key repeated
across different PRs is a candidate. Findings without a key (reviews from before keys were introduced) go
in a list: classify them against the dictionary by hand or with a subagent, and if a cluster repeats
and there is no key — add a key to the dictionary. Takes a second, no network.

`mine_pr_reviews.py` walks all repos in `{{PROJECT_ROOT}}/` with `.git`, takes the last `-n` merged
PRs of the current GitHub user (`gh auth status`) and pulls reviewers' inline comments,
excluding trivial "LGTM" and everything from your own gh login — so it is only humans and bots.
`--min-repeat 1`, because textual duplicates almost never occur (out of 125 comments —
none): you have to group by meaning yourself. A long step (hundreds of `gh api` calls);
if there are many repos, narrow with `--repos acme-api acme-web ...`.
Takes several minutes — run it in the background.

## 2. Classify

The scripts do **not** classify semantics — they only group similar text. Classifying
by bug category is the agent's judgment:

- **correctness** — a logic error that the reviewer would catch with a test
- **simplification / reuse** — "helper X already exists", "this can be shorter"
- **efficiency** — an extra query/loop/allocation
- **security** — what `/security-review` would cover
- **style / convention** — formatting, naming, PR template structure

Run every recurring group from both scripts through these categories. If a group
is clearly about a specific service (not about {{PROJECT_NAME}} in general), tag it with the service — useful
for per-repo memory, like the other project memories in the directory.

## 3. Filter out noise

The same four filters as in the retro skill:

- **Repeats** — in at least two different PRs/sessions, not one reviewer nitpick.
- **Not derivable from the environment** — if the rule is already in `CLAUDE.md`, the service's `AGENTS.md`
  or a memory file, repetition by itself is no reason to create a duplicate — it adds a vote to
  the existing memory (see below), it does not create a new one.
- **Not outdated** — the PR may have been about code that has since been rewritten; check that the
  pattern is still reproducible in the current code.
- **About a fact/pitfall, not a reviewer's personal taste nitpick** — if the comment was
  one-off and subjective ("I would like it better another way"), and does not repeat as a systematic
  error — it is not memory.

`grep -l` over the memory directory before creating any new file — refine an existing one,
do not create a second on the same topic.

## 4. Propose, do not write silently

As in the retro skill: show the user the candidates (the pitfall, how many times, in which PRs/repos,
what is proposed to be written) and wait for confirmation before writing. The memory file format is
as in the `~/.claude/projects/{{PROJECT_KEY}}/memory/` directory, see the type descriptions
there. After writing, check that every path you named exists in this checkout.

## 5. If the fix is not about memory but about a tool

Not every recurring fix is solved by memory. For each group that did not pass step 3
or is clearly about *process* rather than a fact, evaluate separately:

- **The same mechanical fix repeats** (the same refactoring, the same import
  pattern, the same check) **across different PRs/services** → propose not memory but an edit to
  an existing skill (for example, add a checklist to `code-review` or `simplify`) —
  so that the fix is caught *before* sending for review, not after.
- **The reviewer regularly asks for something Claude Code currently has no tool for** (for example,
  comments about Sentry alerts that Claude cannot see, or about a Figma mockup it
  did not check against) → propose looking for a ready MCP server for that integration or, if
  there is no suitable one, sketch a plan for a new skill/MCP. Do not connect or create it
  yourself — only propose with a rationale (what the pitfall is, how many times it repeated,
  which tool/MCP would close it) and wait for the user's decision.
- **A comment about something already covered by an existing skill, but the skill does not catch it** →
  this is a skill bug, not a memory gap — propose a targeted edit to the skill prompt
  (for example, add an item to the `code-review` checklist), rather than creating a new one.

Proposal format is as in step 4: what the pattern is, how many times, what exactly is proposed
(file and edit / new skill / MCP search), and why memory is not enough here.

## 6. Write the protocol

After the user confirms what to write — `retros/<YYYY-MM-DD>.md` in
the skill directory, modeled on the previous one: **Data** (volume, sources, how accurate the
numbers are), **Results** (key — findings / distinct PRs), **Conclusions**, **Actions** (key →
what was done → type: memory / checklist / tool), separately — what was not taken and why,
and the outcome of the check against the previous protocol. Without a protocol the next retro will not know which
actions to check, and the effect of memory will remain unmeasurable.
