#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
builder="$repo_dir/skill/scripts/build-monorepo.sh"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cloud-claude-test.XXXXXX")
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

plan="$tmp_dir/plan.json"
jq -n \
  --arg slug company-context \
  --arg md '# Company context

## Repositories

- acme/api (`main`): API service.

## How repositories relate

The API is the only selected repository.

## User conventions

No additional conventions were observed.

## Connectors available to you

- GitHub: use for pull requests, issues, and repository metadata. It is account-provided; query it only when relevant.

## Session log (warm start)

At the start of every session:

- Read `sessions/INDEX.md`, then read the most recent relevant session records in `sessions/` before starting work.

At the end of meaningful work:

1. Write exactly one concise, factual record to `sessions/<YYYY-MM-DD>-<short-task-slug>.md` using this template:

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

2. Append one line to `sessions/INDEX.md` in the form `YYYY-MM-DD | short-task-slug | one-line summary`.
3. Commit the session record and index update, then push both back to this context repository.

Keep each record short and factual: it is a work record, not reflective "lessons learned" commentary. Write one file per session and never duplicate a record or index entry. If nothing meaningful happened, write nothing.

Session push-back depends on this context repository being selected in the session and the GitHub proxy allowing push. Proxy push support is currently unverified.' \
  '{slug: $slug, repos: [{name: "acme/api", origin: "https://github.com/acme/api.git", branch: "main"}], connectors: ["GitHub"], company_claude_md: $md}' \
  > "$plan"

CLOUD_CLAUDE_NO_PUSH=1 CLOUD_CLAUDE_OUT_DIR="$tmp_dir/out" \
  "$builder" "$plan" > "$tmp_dir/build.out"

target="$tmp_dir/out/company-context"
[ -f "$target/CLAUDE.md" ]
[ -f "$target/sessions/README.md" ]
[ -f "$target/sessions/INDEX.md" ]
[ ! -s "$target/sessions/INDEX.md" ]

actual_files=$(git -C "$target" ls-files | LC_ALL=C sort)
expected_files=$(printf '%s\n' CLAUDE.md sessions/INDEX.md sessions/README.md)
[ "$actual_files" = "$expected_files" ] || {
  printf 'unexpected generated files:\n%s\n' "$actual_files" >&2
  exit 1
}

git -C "$target" diff --quiet
git -C "$target" diff --cached --quiet
grep -Fqx '## Session log (warm start)' "$target/CLAUDE.md"
grep -Fq 'one file per session' "$target/sessions/README.md"
grep -Fq 'YYYY-MM-DD | short-task-slug | one-line summary' "$target/sessions/README.md"

bad_plan="$tmp_dir/bad-plan.json"
jq '.slug = "bad-headings" | .company_claude_md |= sub("## Repositories"; "## Repository map")' \
  "$plan" > "$bad_plan"
if CLOUD_CLAUDE_NO_PUSH=1 CLOUD_CLAUDE_OUT_DIR="$tmp_dir/out" \
  "$builder" "$bad_plan" > "$tmp_dir/bad.out" 2> "$tmp_dir/bad.err"; then
  printf 'builder accepted a plan without the exact required headings\n' >&2
  exit 1
fi
grep -Fq 'plan does not match the thin context-repository schema' "$tmp_dir/bad.err"

setup_plan="$tmp_dir/setup-plan.json"
jq '.slug = "setup-not-allowed" | .setup_script = "#!/usr/bin/env bash"' \
  "$plan" > "$setup_plan"
if CLOUD_CLAUDE_NO_PUSH=1 CLOUD_CLAUDE_OUT_DIR="$tmp_dir/out" \
  "$builder" "$setup_plan" > "$tmp_dir/setup.out" 2> "$tmp_dir/setup.err"; then
  printf 'builder accepted a setup script in a thin context repository\n' >&2
  exit 1
fi
grep -Fq 'plan does not match the thin context-repository schema' "$tmp_dir/setup.err"

printf 'build-thin-repo: PASS\n'
