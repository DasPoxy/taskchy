# Changelog

Taskchy follows [semantic versioning](https://semver.org): until 1.0, a minor
version (0.x.0) may change how things work; patch versions only fix. Each
release is a git tag:

```sh
git -C ~/.config/omarchy/plugins/taskchy checkout v0.2.0
```

Your todos are plain markdown files in your notes folder; no release changes
their format in a way your notes app can't read.

## 0.2.0 - 2026-10-09

- **Uninstall**: `install.sh --uninstall` (asks first): the plugin, the
  command, the skill only if Taskchy installed it, its key commented out.
  Your todos are never touched.
- **Safety**: todo titles, sub-todos and other text from your notes files
  are shown as plain text; log entries still render as Markdown, but
  pictures in them become links and raw HTML shows as text, so nothing in a
  note can make Taskchy load anything from the internet.
- **Tests and CI**: the agent workflow (plan, start, log, finish, find),
  delete / archive, pictures; run on every push.

## 0.1.0 - 2026-10-03

The first public version: a standalone, Omarchy-themed fork of Slime-Tasks.

- Todos, sub-todos (several lines, pictures), groups and super groups, a
  task log and progress view, fully keyboard driven; plain markdown files
  any notes app (Obsidian...) can edit.
- The `taskchy` command for scripts and agents, with `plan` for agents
  starting a project, and an opt-in Claude Code skill.
- Audit fixes: in-place saves that keep what your notes app wrote, safe todo
  ids, stale-position checks (`--expect`), every delete asked twice.
