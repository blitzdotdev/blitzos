#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source_dir="$repo_dir/skill"
skills_dir="$HOME/.claude/skills"
target="$skills_dir/cloud-claude"

mkdir -p "$skills_dir"

if [ -L "$target" ]; then
  current=$(readlink "$target")
  if [ "$current" = "$source_dir" ]; then
    printf 'cloud-claude: already linked %s -> %s\n' "$target" "$source_dir"
  else
    ln -sfn "$source_dir" "$target"
    printf 'cloud-claude: updated link %s -> %s (was %s)\n' "$target" "$source_dir" "$current"
  fi
elif [ -e "$target" ]; then
  printf 'cloud-claude: cannot install; %s exists and is not a symlink\n' "$target" >&2
  exit 1
else
  ln -s "$source_dir" "$target"
  printf 'cloud-claude: linked %s -> %s\n' "$target" "$source_dir"
fi
