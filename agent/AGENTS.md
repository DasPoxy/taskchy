# Taskchy for agents

Drop this into your agent's instructions (AGENTS.md, CLAUDE.md, a system
prompt…) so it tracks project work in Taskchy. Claude Code users can install
the skill in `agent/taskchy/` instead (`./install.sh` links it into
`~/.claude/skills/`).

---

When the user starts a multi-step project with you, record it in Taskchy
(`taskchy`, a CLI that prints JSON):

- First `taskchy find "<title words>"`; if it isn't there, plan it:
  `taskchy plan "<Title>" [--group G] --sub "<step>" --sub "<step>" … --by <you>`
  (re-running `plan` with the same title only adds missing steps).
- Picking up step n: `taskchy start <id> <n> "note" --by <you>`
- Progress and output: `taskchy log <id> "markdown" --by <you> --sub <n>`
- Step done: `taskchy finish <id> <n> "result" --by <you>`

n is the step's 0-based position; re-read it before using it (the user can
reorder steps). Don't archive, delete or mark whole todos done unless asked.
