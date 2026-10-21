---
name: retro
description: Analyzes transcripts of past Claude Code sessions in this project and proposes new or refined memory files so the same mistakes are not repeated. Use when the user asks for a retrospective over past sessions, wants to know what mistakes keep repeating, asks to mine session logs/transcripts/history for lessons, or asks to update memory from past work. Triggers: retro, retrospective, session review, recurring mistakes, update notes from session logs.
---

# /retro — learn from past sessions

Goal: turn recurring mistakes from transcripts into **memory**, not into a report.
A report is read once, memory mixes itself in at the right moment.

## 1. Collect signals

```bash
python3 ~/.claude/skills/retro/scripts/mine.py --min-repeat 3
```

By default the window is all sessions since the last retro: the date lives in `~/.claude/skills/retro/last-run`
and travels between machines via agent-sync. Do not count the window in sessions (`-n`): herdr standing
agents spawn dozens of sessions a day, and `-n 40` covers only today. If the file is missing, the script takes
the last 40 and says so in the header. `--min-repeat` is the threshold for the failures block.
`--min-sessions` (default 5) is the session threshold for the Bash shapes in the third block.
The script prints three blocks: user corrections, recurring tool failures
(normalized to a command "shape" so identical errors across different sessions merge)
and expensive commands (output volume by tool and Bash shape).

Transcripts live in `~/.claude/projects/{{PROJECT_KEY}}/*.jsonl` — that is 100+ MB,
they cannot be read whole, only through the script. The script itself supplements them with `~/.claude/history.jsonl`
(the shared history of the user's prompts across all projects, without tool_use/tool_result — cheap to read whole) — from there it takes
corrections from sessions that fell outside the `-n` window, filtered by the current
project (`{{PROJECT_ROOT}}`). The `--no-history` flag turns this off if only
transcripts are needed. **Important:** corrections in history.jsonl are caught by the same `CORRECTION` regex as in
transcripts. The shipped pattern is English. Phrases for another language belong in a local file
next to the script (not in this template). One missed spelling hides a recurring pattern.

## 2. Filter out noise — this is the main step

A candidate deserves memory only if it passes all four filters:

- **Repeats** — in at least two different sessions. A single mistake is not a pattern.
- **Not derivable from the environment** — if the prohibition is already written in the tool description,
  in the schema or in `CLAUDE.md`, memory will not help: everything is already said there, and the mistake was
  not from ignorance. Discard such ones.
- **Not outdated** — check that the pitfall is alive *now*: reproduce the command,
  see whether the file/branch/PR exists. A transcript describes the past.
- **About a fact or pitfall, not a procedure** — facts go to memory; multi-step
  procedures (if they are really needed) go to a separate skill.

Separately check whether a memory file on this topic already exists: then it is **refined**, not
duplicated. `grep -l` over the memory directory before creating any file.

## 3. Propose, do not write silently

Show the user a list of candidates: what the pitfall is, how many times and in which sessions
it occurred, and what is proposed to be written (a new file or an edit to an existing one). Write
only what they confirmed — otherwise memory fills with noise and becomes unreadable.

The memory file format and the one-line-in-`MEMORY.md` rule are as in the memory directory itself.
After writing, check that every path you named exists in this checkout.

When the user has gone through the candidates (even if nothing was written), mark the review:
`mine.py --mark`. Do not mark earlier: a repeated run within the same retro will see an empty window.

## 4. What to do with findings that do not fit memory

- Failures due to missing infrastructure (no index, a service not running) — propose
  fixing the infrastructure, rather than memorizing a workaround.
- Recurring permission-classifier denials — propose a rule in `settings.local.json`
  if the action is truly safe, or memorize a workaround tool.
- Pre-existing build/test errors — not our fault and not memory; mention at most.
- The same mistake/workaround repeats mechanically across sessions (not a fact but a procedure
  that is easier to just keep doing right) — propose an edit to an existing skill,
  not memory: a skill applies itself every time, memory still has to be recalled.
- The reviewer/user regularly asks for something there is no tool for (an integration with an external
  service that has to be done by hand) — propose looking for a ready MCP for it
  or sketching a plan for a new skill/MCP. Do not connect it yourself — only propose
  with a rationale (the pitfall, how many times it repeated, what would close it) and wait for the user's
  decision. Specifically for fixes after code review — see the pr-review-retro skill.
- An expensive Bash/tool shape in ≥5 sessions (the third block of mine.py) — a candidate for a script
  or for an edit to the skill that prescribes it; measure the gain before planning.

## 5. Prompt cache TTL check

```bash
bash ~/.claude/skills/retro/scripts/ttl-sim.sh   # window = last-run; pass a date to override
```

`promptCacheTtl` in `~/.claude/settings.json` is `"1h"`. The API accepts only `5m` and `1h`.
Report:

- **Actual writes**: `1h=0` while `promptCacheTtl` is `"1h"` means the setting stopped working
  (renamed key, new client logic) — check the TTL logic in the binary.
- **Cost ratio 1h/5m**: keep `1h` while the ratio stays near 1 and limits are not tight;
  propose `5m` if the ratio grows or the user hits limits (1h writes cost 2x on overage).
