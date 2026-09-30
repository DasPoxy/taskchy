# Taskchy

Todos, sub-todos, a live task log and progress — in an Omarchy overlay that
follows your system theme, is fully keyboard driven, and that agents can drive
too. A standalone fork of Slime Shell's Slime-Tasks: same features, none of
the slime, and no Slime Shell needed.

| Tab | What it's for |
|---|---|
| **Todo** | Todos in groups and super groups (groups of groups), each with its own list of sub-todos that move *to do → in progress → done*. Pictures can hang off any sub-todo. |
| **Task Log** | The selected todo's sub-todos in *to do / in progress / done* lanes, and its log of progress notes and output. Agents fill it in as they work; so can you. The log can be shown newest first, by sub-todo, or across every todo by todo, group or super group. |
| **Progress** | How far along every super group, group and todo is. Archive finished lists; search the archive and restore one, a whole group or a whole super group. |

Press **?** inside for every key. Tab / 1 2 3 switch tabs, Esc backs out (or
closes), and the footer always shows the keys for where you are.

## Install

```sh
git clone <this repo> ~/Work/taskchy
~/Work/taskchy/install.sh
```

That links the plugin into `~/.config/omarchy/plugins/taskchy`, the CLI into
`~/.local/bin/taskchy`, the Claude Code skill into `~/.claude/skills/taskchy`
(if you use Claude Code), and enables the plugin. Open it with

```sh
omarchy-shell shell toggle taskchy '{}'        # or '{"tab":"log"}'
```

and give it a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + T", "Taskchy", "omarchy-shell shell toggle taskchy '{}'")
```

## Where it's stored

Plain markdown in **`~/Documents/Taskchy`** (change it with
`taskchy folder <path>`), so any notes app can read and edit it too:

```
Taskchy/
  Todos/<id>.md          one per todo: front matter + "- [ ]" sub-todos
  Logs/<id>.md           its task log: "## <time> · <who> · <sub-todo>" entries
  Archive/               archived todos (Archive/Logs/ their logs)
  Attachments/<id>/      pictures on that todo's sub-todos
  .taskchy/groups.json   group colours, order and super groups
  .taskchy/trash/        deleted todos, just in case
```

Sub-todo states are `- [ ]` to do, `- [/]` in progress, `- [x]` done. What
the app remembers about its view (folds, log view) is in
`~/.local/state/taskchy/ui.json`.

## For agents and scripts

`taskchy` is the same backend the app uses; every command prints JSON and the
app re-reads the folder every two seconds while it's open, so you can watch an
agent move sub-todos across the lanes and write its log.

```sh
taskchy plan "Overhaul the parser" --group Work \
  --sub "Read the old parser" --sub "Write the new one" --sub "Tests" --by claude
taskchy start <id> 0 "picking this up" --by claude     # -> in progress, logged
taskchy log <id> "findings, output…" --by claude --sub 0
taskchy finish <id> 0 "done: 12 tests pass" --by claude
taskchy --help                                          # everything else
```

`plan` makes a todo with its sub-todos in one go — for when a project starts
with an agent instead of in Taskchy. Re-running it with the same title reuses
the todo and only adds the sub-todos it doesn't have.

`agent/taskchy/SKILL.md` is a Claude Code skill that has Claude plan projects
into Taskchy and log its work there; `agent/AGENTS.md` is the same thing as a
paragraph for any other agent's instructions.

Writes are locked and atomic, so the app and an agent never clobber each
other; `--expect <text>` makes a sub-todo change refuse if its text changed
meanwhile.
