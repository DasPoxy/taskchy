#!/usr/bin/env bash
# Finish installing Taskchy: links the `taskchy` CLI into ~/.local/bin,
# pointing back at this folder, so `omarchy plugin update taskchy` (or a
# `git pull`) updates it too.
#
# After `omarchy plugin add`, run it from the plugin's folder:
#   ~/.config/omarchy/plugins/taskchy/install.sh
# From a copy elsewhere (for personal tweaks), it also links that
# checkout in as the plugin and enables it.
#
# Options:
#   --claude-skill   also install the Claude Code skill into
#                    ~/.claude/skills/taskchy. It's copied, not linked, so a
#                    plugin update never changes the instructions your agents
#                    load; run this again (with the option) to refresh it.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
plugin_dir="$HOME/.config/omarchy/plugins/taskchy"
skill_dir="$HOME/.claude/skills/taskchy"
marker=".installed-by-taskchy"

want_skill=false
for arg in "$@"; do
  case $arg in
    --claude-skill) want_skill=true ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

# Is this path one of ours: this checkout, or another Taskchy checkout (a
# folder with Taskchy's own plugin manifest)?
ours() {
  local p="$1" root
  p="$(readlink -f "$p" 2>/dev/null)" || return 1
  [[ $p == "$here" || $p == "$here"/* ]] && return 0
  root="$p"; [[ -d $root ]] || root="$(dirname "$root")"
  while [[ $root != / && $root != . ]]; do
    if [[ -f $root/manifest.json ]] && grep -q '"id": *"taskchy"' "$root/manifest.json" 2>/dev/null; then return 0; fi
    root="$(dirname "$root")"
  done
  return 1
}

# Link $at -> $target, but never over something that isn't ours: an existing
# file or folder is left alone, and so is a link pointing somewhere else.
link() {
  local target="$1" at="$2"
  mkdir -p "$(dirname "$at")"
  if [[ -L $at ]]; then
    if [[ $(readlink -f "$at" 2>/dev/null) == "$(readlink -f "$target")" ]]; then
      echo "already linked $at"; return
    fi
    if ! ours "$at"; then
      echo "skipping $at: it links to $(readlink "$at"), which isn't Taskchy's" >&2
      return
    fi
  elif [[ -e $at ]]; then
    echo "skipping $at: something that isn't a link is already there" >&2
    return
  fi
  ln -sfn "$target" "$at"
  echo "linked $at -> $target"
}

# a checkout outside the plugins folder: link it in as the plugin
if [[ $(readlink -f "$plugin_dir" 2>/dev/null) != "$here" ]]; then
  link "$here" "$plugin_dir"
  if [[ $(readlink -f "$plugin_dir" 2>/dev/null) == "$here" ]] \
     && command -v omarchy-shell >/dev/null && omarchy-shell shell ping >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null || true
    omarchy-shell shell setPluginEnabled taskchy true >/dev/null || true
    echo "enabled the taskchy plugin"
  fi
fi

link "$here/bin/taskchy" "$HOME/.local/bin/taskchy"

# the Claude Code skill: only when asked, as a copy we can recognise later
if $want_skill; then
  if [[ -L $skill_dir ]]; then
    if ours "$skill_dir"; then rm "$skill_dir"   # an old link from an earlier install
    else echo "skipping $skill_dir: it links to $(readlink "$skill_dir"), which isn't Taskchy's" >&2; want_skill=false; fi
  elif [[ -e $skill_dir && ! -f $skill_dir/$marker ]]; then
    echo "skipping $skill_dir: a skill that Taskchy didn't install is already there" >&2; want_skill=false
  fi
  if $want_skill; then
    rm -rf "$skill_dir"
    mkdir -p "$skill_dir"
    cp -R "$here/agent/taskchy/." "$skill_dir/"
    echo "installed from $here at $(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo "?")" > "$skill_dir/$marker"
    echo "installed the Claude Code skill (a copy) in $skill_dir"
  fi
elif [[ -d $HOME/.claude ]]; then
  echo "(the Claude Code skill isn't installed; run again with --claude-skill if you want it)"
fi

echo "notes folder: $("$here/bin/taskchy" folder | python3 -c 'import json,sys; print(json.load(sys.stdin)["folder"])')"

cat <<'MSG'

Open it with:   omarchy-shell shell toggle taskchy '{}'
A key for it, in ~/.config/hypr/bindings.lua:
  o.bind("SUPER + CTRL + ALT + RETURN", "Taskchy", "omarchy-shell shell toggle taskchy '{}'")
MSG
