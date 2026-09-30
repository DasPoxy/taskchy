#!/usr/bin/env bash
# Finish installing Taskchy: links the `taskchy` CLI into ~/.local/bin and (if
# Claude Code is here) the agent skill into ~/.claude/skills, both pointing back
# at this folder, so `omarchy plugin update taskchy` (or a `git pull`) updates
# them too.
#
# After `omarchy plugin add`, run it from the plugin's folder:
#   ~/.config/omarchy/plugins/taskchy/install.sh
# From a copy elsewhere (for personal tweaks), it also links that
# checkout in as the plugin and enables it.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
plugin_dir="$HOME/.config/omarchy/plugins/taskchy"

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

# a checkout outside the plugins folder: link it in as the plugin
if [[ $(readlink -f "$plugin_dir" 2>/dev/null) != "$here" ]]; then
  link "$here" "$plugin_dir"
  if command -v omarchy-shell >/dev/null && omarchy-shell shell ping >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null || true
    omarchy-shell shell setPluginEnabled taskchy true >/dev/null || true
    echo "enabled the taskchy plugin"
  fi
fi

link "$here/bin/taskchy" "$HOME/.local/bin/taskchy"
[[ -d $HOME/.claude ]] && link "$here/agent/taskchy" "$HOME/.claude/skills/taskchy"

echo "notes folder: $("$here/bin/taskchy" folder | python3 -c 'import json,sys; print(json.load(sys.stdin)["folder"])')"

cat <<'MSG'

Open it with:   omarchy-shell shell toggle taskchy '{}'
A key for it, in ~/.config/hypr/bindings.lua:
  o.bind("SUPER + CTRL + ALT + RETURN", "Taskchy", "omarchy-shell shell toggle taskchy '{}'")
MSG
