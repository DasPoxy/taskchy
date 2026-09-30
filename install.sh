#!/usr/bin/env bash
# Install Taskchy from this checkout: the shell plugin, the `taskchy` CLI and
# (if Claude Code is here) the agent skill — all as links back to this folder,
# so a `git pull` updates everything.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

link() {
  local target="$1" at="$2"
  mkdir -p "$(dirname "$at")"
  if [[ -e $at && ! -L $at ]]; then
    echo "skipping $at: something that isn't a link is already there" >&2
    return
  fi
  ln -sfn "$target" "$at"
  echo "linked $at -> $target"
}

link "$here" "$HOME/.config/omarchy/plugins/taskchy"
link "$here/bin/taskchy" "$HOME/.local/bin/taskchy"
[[ -d $HOME/.claude ]] && link "$here/agent/taskchy" "$HOME/.claude/skills/taskchy"

taskchy folder >/dev/null
echo "notes folder: $(taskchy folder | python3 -c 'import json,sys; print(json.load(sys.stdin)["folder"])')"

if command -v omarchy-shell >/dev/null && omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null || true
  omarchy-shell shell setPluginEnabled taskchy true >/dev/null || true
  echo "enabled the taskchy plugin"
fi

cat <<'MSG'

Open it with:   omarchy-shell shell toggle taskchy '{}'
A key for it, in ~/.config/hypr/bindings.lua:
  o.bind("SUPER + CTRL + ALT + RETURN", "Taskchy", "omarchy-shell shell toggle taskchy '{}'")
MSG
