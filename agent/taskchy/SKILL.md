---
name: taskchy
description: "Track project work in Taskchy (the user's Omarchy todo / task-log app) through the `taskchy` CLI. Use when the user starts a multi-step project, feature or build with you (plan it as a Taskchy todo with sub-todos, then start / log / finish them as you go), when they mention Taskchy, or when they ask you to pick up, update or report on a Taskchy todo. Skip one-off questions and single quick edits."
---

# Taskchy

Taskchy is the user's todo / task-log / progress app (an Omarchy shell overlay).
Everything is plain markdown in `~/Documents/Taskchy`; the `taskchy` CLI is the
same backend the app uses, and the app re-reads it every two seconds while
open, so the user watches your sub-todos move across the lanes and your log
fill in live. Every command prints JSON; errors go to stderr, exit status 1.

## When a project starts with you

If the user starts a project in chat rather than in Taskchy, write the plan
into Taskchy before you begin:

1. Check it isn't there already: `taskchy find "<words from the title>"`.
2. Plan it — one todo, one sub-todo per real step (3–10, in order, short
   imperative text). Put it in a group if one fits (`taskchy list` shows the
   groups); otherwise leave `--group` off.

   ```bash
   taskchy plan "Taskchy keybind" --group "Plugins" \
     --sub "Find a free key combo" --sub "Add the bind" --sub "Test it" \
     --by claude --note "one line on what the project is"
   ```

   `plan` reuses an active todo with the same title and only adds sub-todos
   it doesn't have yet, so re-running it (or extending a plan later) is safe.
   It prints the todo; its `id` and each sub-todo's `i` are what the other
   commands take.
3. Tell the user in one line that the plan is in Taskchy.

## While you work

- Picking a step up: `taskchy start <id> <n> "what you're doing" --by claude`
- Progress, findings, output: `taskchy log <id> "markdown…" --by claude --sub <n>`
- Step done: `taskchy finish <id> <n> "what came of it" --by claude`
- A new step turns up: `taskchy sub-add <id> "text"` (or `plan` again)

`<n>` is the sub-todo's 0-based position. The user may reorder sub-todos in
the app while you work, so re-read positions (`taskchy find`, or the JSON a
command returns) instead of trusting old numbers, and pass
`--expect "<sub-todo text>"` whenever you change one (`sub-set`, `sub-edit`,
`sub-move`, `sub-delete`) so a row that changed is refused rather than hit.

Log what the user would want to glance at later: decisions, results, what
failed and why, file paths. Keep entries short; markdown and code blocks work,
and pasted output is safe (a line that looks like an entry heading is escaped).

Go through `taskchy`, not the markdown files: the user may keep their own
notes in a todo file, and the CLI changes only the lines it means to.

## Don't

- Don't archive, delete, rename or regroup the user's todos unless asked
  (deleted ones go to `.taskchy/trash/`, but ask first all the same).
- Don't mark the whole todo `done` — the user does that (finishing every
  sub-todo is enough).
- Don't plan trivial one-step requests.

`taskchy --help` lists every command (groups, super groups, archive, pictures,
reordering, `log-all`, `search`).
