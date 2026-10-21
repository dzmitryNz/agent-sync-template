# {{PROJECT_NAME}} workspace — pointers for agents

Shared agent rules (language, TDD, plans, code search, QA/handoff) live in `~/.claude/CLAUDE.md`
(agent-sync). Rules of a specific service live in the `CLAUDE.md` / `AGENTS.md` of the git root
that receives the commits.

## Memory

All persistent memory for every project under this directory is stored at:

`~/.claude/projects/{{PROJECT_KEY}}/memory/`

Use that path for all Read/Write memory operations regardless of which sub-project you are in.
Do **not** write to a sub-project-specific memory path.
