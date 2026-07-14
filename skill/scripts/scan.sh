#!/usr/bin/env bash

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  printf 'blitzos scan: jq is required\n' >&2
  exit 1
fi

projects_root=${CLAUDE_PROJECTS_DIR:-"$HOME/.claude/projects"}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/blitzos-scan.XXXXXX")
chmod 700 "$tmp_dir"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

encode_path() {
  LC_ALL=C sed 's/[^A-Za-z0-9]/-/g' <<EOF
$1
EOF
}

decode_project_path() {
  local project_dir=$1
  local encoded_name file candidate encoded_candidate naive

  encoded_name=${project_dir##*/}

  # Session JSONL contains the original cwd. Prefer it because Claude's
  # directory-name encoding is lossy for dashes and punctuation.
  while IFS= read -r candidate; do
    [ -d "$candidate" ] || continue
    encoded_candidate=$(encode_path "$candidate")
    if [ "$encoded_candidate" = "$encoded_name" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(
    for file in "$project_dir"/*.jsonl; do
      [ -f "$file" ] || continue
      head -n 20 "$file" 2>/dev/null || true
    done | jq -r 'select((.cwd? | type) == "string") | .cwd' 2>/dev/null || true
  )

  naive=${encoded_name//-/\/}
  [ -n "$naive" ] || naive=/
  if [ -d "$naive" ] && [ "$(encode_path "$naive")" = "$encoded_name" ]; then
    printf '%s\n' "$naive"
    return 0
  fi

  if [ "$encoded_name" = "-" ]; then
    printf '/\n'
    return 0
  fi

  return 1
}

mtime_epoch() {
  if stat -f '%m' "$1" >/dev/null 2>&1; then
    stat -f '%m' "$1"
  else
    stat -c '%Y' "$1"
  fi
}

epoch_to_iso() {
  local epoch=$1
  if date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

file_size_bytes() {
  if stat -f '%z' "$1" >/dev/null 2>&1; then
    stat -f '%z' "$1"
  else
    stat -c '%s' "$1"
  fi
}

frontmatter_field() {
  local file=$1 field=$2
  LC_ALL=C awk -v wanted="$field" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function emit(value, first, last) {
      value = trim(value)
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if (length(value) >= 2 && ((first == "\"" && last == "\"") || (first == "\047" && last == "\047"))) {
        value = substr(value, 2, length(value) - 2)
      }
      gsub(/[[:space:]]+/, " ", value)
      printf "%s", value
      emitted = 1
    }
    NR == 1 {
      sub(/\r$/, "")
      if ($0 != "---") exit
      frontmatter = 1
      next
    }
    frontmatter {
      line = $0
      sub(/\r$/, "", line)
      if (capture) {
        if (line ~ /^[[:space:]]+/) {
          line = trim(line)
          if (line != "") value = value (value == "" ? "" : " ") line
          next
        }
        emit(value)
        exit
      }
      if (line ~ /^[[:space:]]*---[[:space:]]*$/) exit
      pattern = "^[[:space:]]*" wanted "[[:space:]]*:"
      if (match(line, pattern)) {
        value = trim(substr(line, RSTART + RLENGTH))
        if (value ~ /^[>|][+-]?[0-9]*$/) {
          value = ""
          capture = 1
          next
        }
        emit(value)
        exit
      }
    }
    END {
      if (capture && !emitted) emit(value)
    }
  ' "$file"
}

valid_skill_folder() {
  jq -en --arg value "$1" '
    $value
    | length > 0
      and length <= 255
      and . != "."
      and . != ".."
      and (ascii_downcase != "readme.md")
      and (ascii_downcase != ".git")
      and test("^[^/\u0000-\u001F\u007F]+$")
  ' >/dev/null
}

sanitize_origin() {
  local origin=$1 scheme after_scheme
  case "$origin" in
    *://*@*)
      scheme=${origin%%://*}
      after_scheme=${origin#*://}
      origin="${scheme}://${after_scheme#*@}"
      ;;
  esac
  printf '%s\n' "$origin"
}

canonical_origin() {
  local origin=$1 remainder host path
  origin=$(sanitize_origin "$origin")
  case "$origin" in
    *://*)
      remainder=${origin#*://}
      host=${remainder%%/*}
      path=${remainder#*/}
      ;;
    *@*:* )
      remainder=${origin#*@}
      host=${remainder%%:*}
      path=${remainder#*:}
      ;;
    *:* )
      host=${origin%%:*}
      path=${origin#*:}
      ;;
    *)
      printf '%s\n' "$origin" | sed 's,/*$,,' | tr '[:upper:]' '[:lower:]'
      return
      ;;
  esac
  printf '%s/%s\n' "$host" "$path" \
    | sed 's,//*$,,' \
    | sed 's,\.git$,,' \
    | tr '[:upper:]' '[:lower:]'
}

extract_env_names() {
  local repo_path=$1 output=$2 env_file names_file
  : > "$output"

  # Read templates only. Real .env/.env.local/.dev.vars files may contain
  # values and are deliberately outside the scanner's input surface.
  while IFS= read -r env_file; do
    [ "$(file_size_bytes "$env_file")" -le 1048576 ] || continue
    names_file="$tmp_dir/env-names.$$.raw"
    LC_ALL=C sed -n -E \
      's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' \
      "$env_file" > "$names_file"
    LC_ALL=C sort -u "$names_file" >> "$output"
  done < <(
    find "$repo_path" -maxdepth 2 \
      -type d \( -name .git -o -name node_modules \) -prune -o \
      -type f \( \
        -name '.env.example' -o -name '.env.sample' -o -name '.env.template' \
        -o -name '.env.*.example' -o -name '.env.*.sample' -o -name '.env.*.template' \
        -o -name '*.env.example' -o -name '*.env.sample' -o -name '*.env.template' \
        -o -name '.dev.vars.example' -o -name '.dev.vars.sample' -o -name '.dev.vars.template' \
      \) -print 2>/dev/null | LC_ALL=C sort
  )

  LC_ALL=C sort -u "$output" -o "$output"
}

local_repos="$tmp_dir/local-repos.jsonl"
: > "$local_repos"

if [ -d "$projects_root" ]; then
  for project_dir in "$projects_root"/*; do
    [ -d "$project_dir" ] || continue
    if ! project_path=$(decode_project_path "$project_dir"); then
      continue
    fi
    [ -d "$project_path" ] || continue
    if ! repo_path=$(git -C "$project_path" rev-parse --show-toplevel 2>/dev/null); then
      continue
    fi
    repo_path=$(CDPATH= cd -- "$repo_path" && pwd -P)

    session_count=0
    newest_epoch=0
    for session_file in "$project_dir"/*.jsonl; do
      [ -f "$session_file" ] || continue
      session_count=$((session_count + 1))
      epoch=$(mtime_epoch "$session_file")
      if [ "$epoch" -gt "$newest_epoch" ]; then
        newest_epoch=$epoch
      fi
    done
    if [ "$newest_epoch" -gt 0 ]; then
      last_session=$(epoch_to_iso "$newest_epoch")
    else
      last_session=''
    fi

    origin=$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)
    origin=$(sanitize_origin "$origin")
    if [ -n "$origin" ]; then
      origin_key=$(canonical_origin "$origin")
      repo_id=$origin_key
    else
      origin_key=''
      repo_id="local:$repo_path"
    fi

    name=${repo_path##*/}
    name_with_owner=''
    case "$origin_key" in
      github.com/*/*)
        name_with_owner=${origin_key#github.com/}
        origin="https://github.com/${name_with_owner}.git"
        ;;
    esac

    branch_current=$(git -C "$repo_path" branch --show-current 2>/dev/null || true)
    branch_default=$(git -C "$repo_path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    branch_default=${branch_default#origin/}
    git -C "$repo_path" for-each-ref \
      --sort=-committerdate \
      --count=10 \
      --format='%(refname:short)' \
      refs/heads/ 2>/dev/null \
      | jq -Rn '[inputs | select(length > 0)]' > "$tmp_dir/branches-recent.json"

    env_names_raw="$tmp_dir/env-names.$$.all"
    extract_env_names "$repo_path" "$env_names_raw"
    jq -Rn '[inputs | select(length > 0)]' < "$env_names_raw" > "$tmp_dir/env-names.json"

    if [ -f "$repo_path/CLAUDE.md" ]; then
      has_claude_md=true
    else
      has_claude_md=false
    fi

    jq -cn \
      --arg id "$repo_id" \
      --arg name "$name" \
      --arg name_with_owner "$name_with_owner" \
      --arg local_path "$repo_path" \
      --arg origin "$origin" \
      --argjson session_count "$session_count" \
      --arg last_session "$last_session" \
      --arg branch_current "$branch_current" \
      --arg branch_default "$branch_default" \
      --argjson has_claude_md "$has_claude_md" \
      --slurpfile branches_recent "$tmp_dir/branches-recent.json" \
      --slurpfile env_var_names "$tmp_dir/env-names.json" \
      '{
        id: $id,
        source: "local",
        name: $name,
        name_with_owner: (if $name_with_owner == "" then null else $name_with_owner end),
        local_path: $local_path,
        origin: $origin,
        session_count: $session_count,
        last_session: (if $last_session == "" then null else $last_session end),
        branch_current: (if $branch_current == "" then null else $branch_current end),
        branch_default: (if $branch_default == "" then null else $branch_default end),
        branches_recent: $branches_recent[0],
        has_claude_md: $has_claude_md,
        env_var_names: $env_var_names[0],
        updated_at: null,
        is_private: null,
        description: ""
      }' >> "$local_repos"
  done
fi

github_repos="$tmp_dir/github-repos.jsonl"
: > "$github_repos"
if ! command -v gh >/dev/null 2>&1; then
  printf 'blitzos scan: GitHub CLI unavailable; only local repositories were scanned\n' >&2
elif ! gh auth status >/dev/null 2>&1; then
  printf 'blitzos scan: GitHub CLI is not authenticated; only local repositories were scanned\n' >&2
else
  collect_gh_repos() {
    local owner=$1 output_file="$tmp_dir/gh-list.$$.json"
    if ! gh repo list "$owner" --limit 1000 \
      --json nameWithOwner,updatedAt,isPrivate,description,defaultBranchRef \
      > "$output_file" 2>/dev/null; then
      printf 'blitzos scan: GitHub repository listing failed for %s; continuing\n' "$owner" >&2
      return
    fi
    jq -c '.[]
      | (.nameWithOwner | ascii_downcase) as $full_name
      | {
          id: ("github.com/" + $full_name),
          source: "github",
          name: ($full_name | split("/") | last),
          name_with_owner: .nameWithOwner,
          local_path: null,
          origin: ("https://github.com/" + .nameWithOwner + ".git"),
          session_count: 0,
          last_session: null,
          branch_current: null,
          branch_default: (.defaultBranchRef.name // null),
          branches_recent: [],
          has_claude_md: false,
          env_var_names: [],
          updated_at: .updatedAt,
          is_private: .isPrivate,
          description: (.description // "")
        }' "$output_file" >> "$github_repos"
  }

  if github_user=$(gh api user --jq '.login' 2>/dev/null) && [ -n "$github_user" ]; then
    collect_gh_repos "$github_user"
  else
    printf 'blitzos scan: GitHub user lookup failed; continuing with organization repositories\n' >&2
  fi

  if gh api user/orgs --paginate --jq '.[].login' > "$tmp_dir/gh-orgs.txt" 2>/dev/null; then
    while IFS= read -r org; do
      [ -n "$org" ] || continue
      collect_gh_repos "$org"
    done < "$tmp_dir/gh-orgs.txt"
  else
    printf 'blitzos scan: GitHub organization listing failed; continuing\n' >&2
  fi
fi

skills_root="$HOME/.claude/skills"
local_skills="$tmp_dir/local-skills.jsonl"
: > "$local_skills"
if [ -d "$skills_root" ]; then
  while IFS= read -r -d '' skill_dir; do
    [ ! -L "$skill_dir" ] || continue
    skill_file="$skill_dir/SKILL.md"
    [ -f "$skill_file" ] && [ ! -L "$skill_file" ] || continue
    folder=${skill_dir##*/}
    valid_skill_folder "$folder" || continue
    skill_name=$(frontmatter_field "$skill_file" name)
    [ -n "$skill_name" ] || skill_name=$folder
    skill_description=$(frontmatter_field "$skill_file" description)
    jq -cn \
      --arg folder "$folder" \
      --arg name "$skill_name" \
      --arg description "$skill_description" \
      '{folder: $folder, name: $name, description: $description}' >> "$local_skills"
  done < <(find "$skills_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi
jq -s 'sort_by([(.name | ascii_downcase), (.folder | ascii_downcase)])' \
  "$local_skills" > "$tmp_dir/local-skills.json"

scanned_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -s \
  --slurpfile skills "$tmp_dir/local-skills.json" \
  --arg scanned_at "$scanned_at" '
  group_by(.id)
  | map(
      . as $group
      | ($group | map(select(.source == "local")) | sort_by(.session_count) | reverse) as $locals
      | ($group | map(select(.source == "github")) | .[0]) as $github
      | if ($locals | length) > 0 then
          $locals[0]
          + {
              session_count: ($locals | map(.session_count) | add),
              last_session: ($locals | map(.last_session) | map(select(. != null)) | sort | last),
              name_with_owner: ($github.name_with_owner // $locals[0].name_with_owner),
              branch_default: ($locals[0].branch_default // $github.branch_default),
              updated_at: ($github.updated_at // null),
              is_private: ($github.is_private // null),
              description: ($github.description // "")
            }
        else
          $github
        end
    )
  | . as $repos
  | {
      schema_version: 1,
      repos: (
        ($repos | map(select(.source == "local")) | sort_by([-(.session_count), .name]))
        + ($repos | map(select(.source == "github")) | sort_by(.updated_at) | reverse)
      ),
      skills: $skills[0],
      scanned_at: $scanned_at
    }
' "$local_repos" "$github_repos" > "$tmp_dir/result.json"

jq -r '
  ([.repos[] | select(.source == "local")] | length) as $local_count
  | ([.repos[] | select(.source == "github")] | length) as $github_count
  | (.skills | length) as $skill_count
  | "blitzos scan: \(.repos | length) repositories after origin dedupe; \($local_count) local git roots; \($github_count) GitHub-only; \($skill_count) local skills available",
  (.repos
    | map(select(.source == "local"))
    | .[0:5][]
    | (.branch_current // .branch_default // "unknown") as $branch
    | "  \(.session_count) sessions  \(.local_path)  branch=\($branch)")
' "$tmp_dir/result.json" >&2

cat "$tmp_dir/result.json"
