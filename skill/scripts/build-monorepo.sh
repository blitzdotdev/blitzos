#!/usr/bin/env bash

set -euo pipefail
umask 077

usage() {
  printf 'Usage: %s plan.json\n' "${0##*/}" >&2
}

fail() {
  printf 'blitzos build: %s\n' "$1" >&2
  exit 1
}

reject_secret_material() {
  local file=$1 label=$2
  local assignment_status=0
  if LC_ALL=C grep -Eiq -- \
    '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|(^|[^A-Za-z0-9])(sk|rk)-(proj-)?[A-Za-z0-9_-]{20,}' \
    "$file"; then
    fail "$label appears to contain credential material; no repository was created"
  fi
  LC_ALL=C awk '
    {
      lower = tolower($0)
      if (match(lower, /(token|secret|password|passwd|api[_-]?key|private[_-]?key)[[:space:]]*[:=]/)) {
        value = substr($0, RSTART + RLENGTH)
        gsub(/^[[:space:]"`]+/, "", value)
        upper = toupper(value)
        if (value != "" && value !~ /^<[^>]+>/ && value !~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}/ && upper !~ /^(REDACTED|PLACEHOLDER|CHANGEME|YOUR_[A-Z0-9_]+|NONE|NOT SET|NAMES? ONLY|FROM (THE )?(CLOUD )?ENVIRONMENT|USE [A-Z_ ]+)([[:space:].]|$)/) {
          found = 1
          exit
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$file" 2>/dev/null || assignment_status=$?
  case "$assignment_status" in
    0) fail "$label appears to assign a secret value; use names or <PLACEHOLDER> templates only" ;;
    1) ;;
    *) fail "could not safely inspect $label for secret assignments; no repository was created" ;;
  esac
}

[ "$#" -eq 1 ] || {
  usage
  exit 2
}

plan_file=$1
[ -f "$plan_file" ] || fail "plan file not found: $plan_file"

for dependency in jq git; do
  command -v "$dependency" >/dev/null 2>&1 || fail "$dependency is required"
done
if [ "${BLITZOS_NO_PUSH:-0}" != 1 ]; then
  command -v gh >/dev/null 2>&1 || fail "gh is required"
fi

if ! jq -e '
  def valid_branch:
    type == "string"
    and length > 0
    and length <= 255
    and test("^[A-Za-z0-9._/-]+$")
    and (startswith("-") | not)
    and (contains("..") | not)
    and (contains("//") | not)
    and (endswith("/") | not);
  def valid_connector:
    type == "string"
    and length > 0
    and length <= 80
    and test("^[A-Za-z0-9][A-Za-z0-9 ._+&()/-]*$");
  def has_exact_heading($md; $heading):
    ($md | gsub("\r\n"; "\n") | split("\n") | index($heading)) != null;
  type == "object"
  and ((keys - ["slug", "repos", "connectors", "company_claude_md"]) | length == 0)
  and ((["slug", "repos", "connectors", "company_claude_md"] - keys) | length == 0)
  and (.slug | type == "string" and length > 0 and test("^[A-Za-z0-9._-]+$"))
  and (.repos | type == "array" and length > 0 and length <= 100)
  and (all(.repos[];
    (keys | sort) == ["branch", "name", "origin"]
    and (.name | type == "string" and length > 0 and length <= 200)
    and (.origin | type == "string" and test("^(https://github\\.com/|git@github\\.com:)") and (test("://[^/@]+@") | not))
    and (.branch | valid_branch)))
  and (([.repos[].origin | ascii_downcase] | unique | length) == (.repos | length))
  and (.connectors | type == "array" and length <= 25 and all(.[]; valid_connector))
  and (([.connectors[] | ascii_downcase] | unique | length) == (.connectors | length))
  and (.company_claude_md | type == "string" and length > 0 and length <= 100000 and (contains("\u0000") | not))
  and (.company_claude_md as $md
    | has_exact_heading($md; "## Repositories")
    and has_exact_heading($md; "## How repositories relate")
    and has_exact_heading($md; "## User conventions")
    and has_exact_heading($md; "## Connectors available to you")
    and has_exact_heading($md; "## Session log (warm start)")
    and ($md | contains("sessions/INDEX.md"))
    and ($md | contains("sessions/<YYYY-MM-DD>-<short-task-slug>.md"))
    and ($md | contains("## What changed"))
    and ($md | contains("## Key decisions"))
    and ($md | contains("## For next session"))
    and all(.repos[]; . as $repo | ($md | contains($repo.name)) and ($md | contains($repo.branch)))
    and all(.connectors[]; . as $connector | $md | contains($connector)))
' "$plan_file" >/dev/null 2>&1; then
  fail 'plan does not match the thin context-repository schema'
fi

slug=$(jq -r '.slug' "$plan_file")
case "$slug" in
  ''|.|..|*[!A-Za-z0-9._-]*) fail "invalid slug: $slug" ;;
esac

if [ "${BLITZOS_NO_PUSH:-0}" != 1 ]; then
  if ! gh auth status >/dev/null 2>&1; then
    fail 'GitHub CLI is not authenticated; run gh auth login, then retry'
  fi
  if gh repo view "$slug" >/dev/null 2>&1; then
    fail "GitHub repository already exists: $slug"
  fi
fi

output_root=${BLITZOS_OUT_DIR:-"$HOME/blitzos-out"}
target="$output_root/$slug"
[ ! -e "$target" ] || fail "output already exists: $target"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/blitzos-build.XXXXXX")
chmod 700 "$tmp_dir"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

claude_draft="$tmp_dir/CLAUDE.md"
jq -r '.company_claude_md' "$plan_file" > "$claude_draft"
chmod 600 "$claude_draft"
reject_secret_material "$claude_draft" 'company CLAUDE.md'

sessions_readme="$tmp_dir/sessions-README.md"
cat > "$sessions_readme" <<'EOF'
# Session log

This directory carries concise work records between Claude cloud sessions.

At session start, read `INDEX.md`, then open the most recent relevant session records. At the end of meaningful work, create one record named `<YYYY-MM-DD>-<short-task-slug>.md`, append one line to `INDEX.md` in the form `YYYY-MM-DD | short-task-slug | one-line summary`, and commit and push both changes back to this context repository.

Use this template:

```markdown
# Task
<concise task description>

## What changed
<PRs, commits, and files touched>

## Key decisions
<decisions that constrain later work>

## For next session
<remaining work or useful starting point>
```

Keep records short and factual. They are work records, not reflective "lessons learned" commentary. Write one file per session, never duplicate a record or index entry, and write nothing if no meaningful work happened.

Session push-back depends on this context repository being selected in the session and the GitHub proxy allowing push. Proxy push support is currently unverified.
EOF
chmod 600 "$sessions_readme"

mkdir -p "$target"
chmod 700 "$target"
if ! git -C "$target" init -b main >/dev/null 2>&1; then
  git -C "$target" init >/dev/null 2>&1 || fail "git init failed in $target"
  git -C "$target" branch -m main >/dev/null 2>&1 || fail "could not name the initial branch main"
fi

install -m 644 "$claude_draft" "$target/CLAUDE.md"
mkdir -m 700 "$target/sessions"
install -m 644 "$sessions_readme" "$target/sessions/README.md"
install -m 644 /dev/null "$target/sessions/INDEX.md"

unexpected=$(find "$target" -mindepth 1 -maxdepth 1 \
  ! -name .git ! -name CLAUDE.md ! -name sessions -print -quit)
[ -z "$unexpected" ] || fail 'unexpected output was generated; refusing to commit'
unexpected_session=$(find "$target/sessions" -mindepth 1 -maxdepth 1 \
  ! -name README.md ! -name INDEX.md -print -quit)
[ -z "$unexpected_session" ] || fail 'unexpected session scaffold output was generated; refusing to commit'
[ ! -s "$target/sessions/INDEX.md" ] || fail 'session index must be empty in a new context repository'

git -C "$target" add -- CLAUDE.md sessions/README.md sessions/INDEX.md
if ! git -c user.name=blitzos \
  -c user.email=blitzos@users.noreply.github.com \
  -C "$target" commit -m 'Add company context for Claude' >/dev/null 2>&1; then
  fail "git commit failed in $target; no GitHub repository was created"
fi

if [ "${BLITZOS_NO_PUSH:-0}" = 1 ]; then
  printf 'NO_PUSH: thin context repository built at %s\n' "$target"
else
  if ! gh repo create "$slug" --private --source "$target" --remote origin --push \
    > "$tmp_dir/gh-create.log" 2>&1; then
    partial_url=$(gh repo view "$slug" --json url --jq '.url' 2>/dev/null || true)
    if [ -n "$partial_url" ]; then
      fail "GitHub repository exists but the initial push did not complete: $partial_url; it is not ready"
    fi
    fail "private GitHub repository creation failed for $slug; no retry was attempted"
  fi

  repo_record=$(gh repo view "$slug" --json url,isPrivate --jq '[.url, .isPrivate] | @tsv' 2>/dev/null || true)
  repo_url=${repo_record%%$'\t'*}
  repo_private=${repo_record#*$'\t'}
  [ -n "$repo_url" ] || fail "GitHub repository was pushed but verification failed for $slug"
  [ "$repo_private" = true ] || fail "GitHub reported $slug as non-private; stop and inspect it immediately"
  printf 'Created private company context: %s\n' "$repo_url"
fi

printf 'Local checkout: %s\n' "$target"
