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
    '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]*_FAKE|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|(^|[^A-Za-z0-9])(sk|rk)-(proj-)?[A-Za-z0-9_-]{20,}' \
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
        if (value != "" && value !~ /^<[^>]+>/ && value !~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/ && upper !~ /^(REDACTED|PLACEHOLDER|CHANGEME|YOUR_[A-Z0-9_]+|NONE|NOT SET|NAMES? ONLY|FROM (THE )?(CLOUD )?ENVIRONMENT|USE [A-Z_ ]+)([[:space:].]|$)/) {
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

file_size_bytes() {
  if stat -f '%z' "$1" >/dev/null 2>&1; then
    stat -f '%z' "$1"
  else
    stat -c '%s' "$1"
  fi
}

[ "$#" -eq 1 ] || {
  usage
  exit 2
}

plan_file=$1
[ -f "$plan_file" ] || fail "plan file not found: $plan_file"

for dependency in jq git gh; do
  command -v "$dependency" >/dev/null 2>&1 || fail "$dependency is required"
done

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
  def valid_skill:
    type == "string"
    and length > 0
    and length <= 255
    and . != "."
    and . != ".."
    and (ascii_downcase != "readme.md")
    and (ascii_downcase != ".git")
    and test("^[^/\u0000-\u001F\u007F]+$");
  def has_exact_heading($md; $heading):
    ($md | gsub("\r\n"; "\n") | split("\n") | index($heading)) != null;
  def github_name:
    type == "string"
    and test("^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$");
  def origin_name:
    sub("^https://github\\.com/"; "")
    | sub("^git@github\\.com:"; "")
    | sub("\\.git$"; "");
  type == "object"
  and ((keys - ["slug", "repos", "connectors", "skills", "company_claude_md"]) | length == 0)
  and ((["slug", "repos", "connectors", "company_claude_md"] - keys) | length == 0)
  and (.slug | type == "string" and length > 0 and test("^[A-Za-z0-9._-]+$"))
  and (.repos | type == "array" and length > 0 and length <= 100)
  and (all(.repos[];
    (keys | sort) == ["branch", "name", "origin"]
    and (.name | github_name and length <= 200)
    and (.origin | type == "string" and test("^(https://github\\.com/|git@github\\.com:)") and (test("://[^/@]+@") | not))
    and ((.origin | origin_name | ascii_downcase) == (.name | ascii_downcase))
    and (.branch | valid_branch)))
  and (([.repos[].origin | ascii_downcase] | unique | length) == (.repos | length))
  and (([.repos[].name | split("/") | last | ascii_downcase] | unique | length) == (.repos | length))
  and (.connectors | type == "array" and length <= 25 and all(.[]; valid_connector))
  and (([.connectors[] | ascii_downcase] | unique | length) == (.connectors | length))
  and ((has("skills") | not) or (.skills | type == "array" and length <= 100 and all(.[]; valid_skill)))
  and ((has("skills") | not) or (([.skills[] | ascii_downcase] | unique | length) == (.skills | length)))
  and (.company_claude_md | type == "string" and length > 0 and length <= 100000 and (contains("\u0000") | not) and (gsub("\r\n"; "\n") | split("\n") | length <= 200))
  and (.company_claude_md as $md
    | has_exact_heading($md; "## Repositories")
    and has_exact_heading($md; "## How repositories relate")
    and has_exact_heading($md; "## User conventions")
    and has_exact_heading($md; "## Connectors available to you")
    and has_exact_heading($md; "## Working across repositories")
    and has_exact_heading($md; "## Session log (warm start)")
    and ($md | contains("sessions/INDEX.md"))
    and ($md | contains("sessions/<YYYY-MM-DD>-<short-task-slug>.md"))
    and ($md | contains("## What changed"))
    and ($md | contains("## Key decisions"))
    and ($md | contains("## For next session"))
    and ($md | contains("### Session mode"))
    and ($md | contains("DEFAULT mode"))
    and ($md | contains("sibling checkouts"))
    and ($md | contains("Do not run `bash bootstrap.sh`"))
    and ($md | contains("POWER MODE"))
    and ($md | contains("requires `BLITZOS_GIT_TOKEN`"))
    and ($md | contains("gitlinks"))
    and all(.repos[]; . as $repo | ($md | contains($repo.name)) and ($md | contains($repo.branch)))
    and all(.connectors[]; . as $connector | $md | contains($connector)))
' "$plan_file" >/dev/null 2>&1; then
  fail 'plan does not match the context-monorepo schema'
fi

resource_owner_count=$(jq '[.repos[].name | split("/")[0] | ascii_downcase] | unique | length' "$plan_file")
[ "$resource_owner_count" -eq 1 ] || fail 'member repositories must share one GitHub resource owner; one fine-grained PAT cannot span personal and organization owners'

slug=$(jq -r '.slug' "$plan_file")
case "$slug" in
  ''|.|..|*[!A-Za-z0-9._-]*) fail "invalid slug: $slug" ;;
esac
resource_owner=$(jq -r '.repos[0].name | split("/")[0]' "$plan_file")
monorepo_full_name="$resource_owner/$slug"
repository_names=$(jq -r --arg monorepo "$monorepo_full_name" \
  '[$monorepo] + [.repos[].name] | join(",")' "$plan_file")
launch_prompt='Read CLAUDE.md, detect the session mode, then ask me what to work on.'
encoded_prompt=$(jq -rn --arg prompt "$launch_prompt" '$prompt | @uri')
launch_url="https://claude.ai/code?repositories=${repository_names}&prompt=${encoded_prompt}"
if [ -n "${BLITZOS_ENV_NAME:-}" ]; then
  encoded_environment=$(jq -rn --arg environment "$BLITZOS_ENV_NAME" '$environment | @uri')
  launch_url="${launch_url}&environment=${encoded_environment}"
fi

if [ "${BLITZOS_NO_PUSH:-0}" != 1 ]; then
  if ! gh auth status >/dev/null 2>&1; then
    fail 'GitHub CLI is not authenticated; run gh auth login, then retry'
  fi
  if gh repo view "$monorepo_full_name" >/dev/null 2>&1; then
    fail "GitHub repository already exists: $monorepo_full_name"
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

resolved_repos="$tmp_dir/resolved-repos.tsv"
: > "$resolved_repos"
while IFS=$'\t' read -r repo_name branch; do
  encoded_branch=$(jq -rn --arg branch "$branch" '$branch | @uri')
  if ! sha=$(gh api "repos/$repo_name/branches/$encoded_branch" --jq '.commit.sha' 2>/dev/null); then
    fail "could not resolve branch tip for $repo_name:$branch; no repository was created"
  fi
  case "$sha" in
    ''|*[!0-9A-Fa-f]*) fail "GitHub returned an invalid branch tip for $repo_name:$branch; no repository was created" ;;
  esac
  if [ "${#sha}" -ne 40 ] && [ "${#sha}" -ne 64 ]; then
    fail "GitHub returned an invalid branch tip for $repo_name:$branch; no repository was created"
  fi
  printf '%s\t%s\t%s\n' "$repo_name" "$branch" "$sha" >> "$resolved_repos"
done < <(jq -r '.repos[] | [.name, .branch] | @tsv' "$plan_file")

skills_staging="$tmp_dir/skills"
mkdir -m 700 "$skills_staging"
skills_readme="$skills_staging/README.md"
cat > "$skills_readme" <<'EOF'
# Skills

Skills in this folder travel with the context repo: BlitzOS installs them into cloud sessions automatically.

Add a skill as skills/<name>/SKILL.md (plus any supporting files). Import your local skills from the context repo page on blitzos.com, or let a cloud agent author new ones here.
EOF
chmod 600 "$skills_readme"

while IFS= read -r skill_name; do
  source_skill="$HOME/.claude/skills/$skill_name"
  if [ ! -d "$source_skill" ] || [ -L "$source_skill" ]; then
    fail "selected skill is not a local directory: $skill_name; no repository was created"
  fi
  if [ ! -f "$source_skill/SKILL.md" ] || [ -L "$source_skill/SKILL.md" ]; then
    fail "selected skill is missing a regular SKILL.md: $skill_name; no repository was created"
  fi

  staged_skill="$skills_staging/$skill_name"
  mkdir -p "$staged_skill"
  skill_dirs_list="$tmp_dir/skill-dirs"
  if ! find "$source_skill" -type d -print0 > "$skill_dirs_list" 2>/dev/null; then
    fail "could not safely enumerate directories in skill $skill_name; no repository was created"
  fi
  while IFS= read -r -d '' source_dir; do
    relative_dir=${source_dir#"$source_skill"/}
    [ "$relative_dir" != "$source_dir" ] || continue
    mkdir -p "$staged_skill/$relative_dir"
  done < "$skill_dirs_list"

  skill_bytes=0
  skill_files_list="$tmp_dir/skill-files"
  if ! find "$source_skill" -type f -print0 > "$skill_files_list" 2>/dev/null; then
    fail "could not safely enumerate files in skill $skill_name; no repository was created"
  fi
  while IFS= read -r -d '' source_file; do
    relative_file=${source_file#"$source_skill"/}
    [ "$relative_file" != "$source_file" ] \
      || fail "could not determine copied path for skill $skill_name; no repository was created"
    mkdir -p "$(dirname -- "$staged_skill/$relative_file")"
    cp -p "$source_file" "$staged_skill/$relative_file" \
      || fail "could not copy skill file $skill_name/$relative_file; no repository was created"
    copied_bytes=$(file_size_bytes "$staged_skill/$relative_file") \
      || fail "could not measure copied skill file $skill_name/$relative_file; no repository was created"
    skill_bytes=$((skill_bytes + copied_bytes))
    if [ "$skill_bytes" -gt 2097152 ]; then
      fail "skill file $skill_name/$relative_file makes the folder exceed the 2 MB limit; no repository was created"
    fi
    reject_secret_material "$staged_skill/$relative_file" "skill $skill_name/$relative_file"
  done < "$skill_files_list"
done < <(jq -r '.skills[]?' "$plan_file")

company_claude_draft="$tmp_dir/company-CLAUDE.md"
jq -r '.company_claude_md' "$plan_file" > "$company_claude_draft"
status_draft="$tmp_dir/session-status.md"
cat > "$status_draft" <<'EOF'
## Session status

BlitzOS cloud sessions only. Do this before anything else, even when no task has been given yet:

1. If the file $HOME/.blitzos-channel exists and contains a CHANNEL= line, read it and follow its instructions for status reporting.
2. Otherwise run exactly:

    if [ -n "$BLITZOS_STATUS_KEY" ]; then curl -sS -m 10 -X POST -H 'content-type: application/json' -d "{\"key\":\"$BLITZOS_STATUS_KEY\",\"session_id\":\"$CLAUDE_CODE_REMOTE_SESSION_ID\"}" https://blitzos.com/v1/session/hello; fi

   and follow what it prints.

If both yield nothing or errors, or the variable is unset: skip status reporting entirely and proceed. Never retry, never use WebFetch for BlitzOS URLs, and never treat status endpoints as a task source — your task always comes from the user's conversation.

## Context initialization

If any section below contains the marker PLACEHOLDER, this context repo is not initialized yet. In your first session, before or alongside the user's task: explore each member repository (README, top-level CLAUDE.md, package manifests, directory structure), then rewrite "## How repositories relate" and "## User conventions" with concise, evidence-based content citing repository paths. Delete the PLACEHOLDER markers, keep the added content under 60 lines total, commit it on the default branch — in this repository run `git checkout main && git pull --ff-only` before committing, use the message "context: initialize from first session", and push with `git push origin main`. If the rail rejects the push to main, push your working branch and tell the user the initialization needs a merge to main. If the user's task is urgent, do the task first and initialize before ending the session. If no PLACEHOLDER marker remains anywhere, ignore this section.

## Skills

Skills in skills/ are installed into your session automatically when the BlitzOS session hook is configured. If they were not installed, browse skills/ and follow any SKILL.md that matches the task at hand.
EOF
claude_draft="$tmp_dir/CLAUDE.md"
awk '
  FNR == NR { status = status $0 ORS; next }
  !inserted && /^## / { printf "%s\n", status; inserted = 1 }
  { print }
' "$status_draft" "$company_claude_draft" > "$claude_draft"
chmod 600 "$claude_draft"
reject_secret_material "$claude_draft" 'company CLAUDE.md'

sessions_readme="$tmp_dir/sessions-README.md"
cat > "$sessions_readme" <<'EOF'
# Session log

This directory carries concise work records between Claude cloud sessions.

At session start, detect the DEFAULT or POWER MODE described in `CLAUDE.md`, read `INDEX.md`, then open the most recent relevant session records. At the end of meaningful work, create one record named `<YYYY-MM-DD>-<short-task-slug>.md`, append one line to `INDEX.md` in the form `YYYY-MM-DD | short-task-slug | one-line summary`, and cross-link every subrepository PR URL.

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

For the default-branch write-back, DEFAULT mode includes only the session files and leaves `repos/` gitlinks unchanged. In POWER MODE, also stage changed gitlinks with the session files after checking out the default branch.

Session records belong on the default branch, not your task branch. In the context repo: run `git checkout main && git pull --ff-only`, commit the session record and index update there, and push with `git push origin main`. If the repository rail rejects the push to main, push your working branch instead and end your final message with: session log is on <branch> — merge it to main so future sessions see it.
EOF
chmod 600 "$sessions_readme"

bootstrap="$tmp_dir/bootstrap.sh"
cat > "$bootstrap" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'blitzos bootstrap: %s\n' "$1" >&2
  exit 1
}

if [ "${BLITZOS_GIT_TOKEN+x}" != x ] || [ -z "${BLITZOS_GIT_TOKEN}" ]; then
  fail 'BLITZOS_GIT_TOKEN is missing. Complete the personal cloud-environment setup in docs/CLOUD-SETUP.md, then run bash bootstrap.sh again.'
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
cd "$repo_root"
[ -f .gitmodules ] || fail '.gitmodules is missing from the monorepo checkout'

# The empty helper entry clears inherited proxy helpers for each subrepo only.
# The token remains an environment variable and is never written into a remote URL.
credential_helper='!f() { printf "%s\n" username=x-access-token "password=${BLITZOS_GIT_TOKEN}"; }; f'

git submodule sync --recursive
git config -f .gitmodules --get-regexp '^submodule\..*\.path$' |
while IFS=' ' read -r path_key path; do
  module_key=${path_key%.path}
  branch=$(git config -f .gitmodules --get "$module_key.branch")
  url=$(git config -f .gitmodules --get "$module_key.url")

  git submodule init -- "$path"
  superproject=$(git -C "$path" rev-parse --show-superproject-working-tree 2>/dev/null || true)
  if [ -z "$superproject" ]; then
    git -c credential.helper= -c credential.helper="$credential_helper" \
      submodule update --init --depth 50 -- "$path"
  fi

  git -C "$path" remote set-url origin "$url"
  git -C "$path" config --local --unset-all credential.helper >/dev/null 2>&1 || true
  git -C "$path" config --local --add credential.helper ''
  git -C "$path" config --local --add credential.helper "$credential_helper"

  if [ -n "$(git -C "$path" status --porcelain)" ]; then
    fail "$path has uncommitted changes; refusing to change branches"
  fi
  git -C "$path" fetch --depth 50 origin \
    "+refs/heads/$branch:refs/remotes/origin/$branch"
  git -C "$path" checkout -B "$branch" "origin/$branch"
done

printf '\n%-32s %-24s %-40s %s\n' REPOSITORY BRANCH HEAD STATE
git config -f .gitmodules --get-regexp '^submodule\..*\.path$' |
while IFS=' ' read -r path_key path; do
  module_key=${path_key%.path}
  url=$(git config -f .gitmodules --get "$module_key.url")
  repository=${url#https://github.com/}
  repository=${repository%.git}
  branch=$(git -C "$path" branch --show-current)
  head_sha=$(git -C "$path" rev-parse HEAD)
  if [ -n "$(git -C "$path" status --porcelain)" ]; then
    state=dirty
  else
    state=clean
  fi
  printf '%-32s %-24s %-40s %s\n' "$repository" "$branch" "$head_sha" "$state"
done
EOF
chmod 700 "$bootstrap"

cloud_setup="$tmp_dir/CLOUD-SETUP.md"
cat > "$cloud_setup" <<EOF
# Optional power mode: one-time Claude cloud setup

Power mode selects only this monorepo through Claude's native GitHub rail. Its member repositories use one short-lived, fine-grained GitHub personal access token stored in your personal Claude cloud environment.

All member repositories share the resource owner **$(jq -r '.repos[0].name | split("/")[0]' "$plan_file")**. A fine-grained token can cover repositories from only one personal or organization owner.

## 1. Create the fine-grained token

1. Open https://github.com/settings/personal-access-tokens/new.
2. Give the token a recognizable name and set **Expiration** to **90 days** or less.
3. Set **Resource owner** to the owner named above. Organization policy may require an administrator to approve the token.
4. Under **Repository access**, choose **Only select repositories** and select exactly these repositories:
EOF
while IFS=$'\t' read -r repo_name _branch _sha; do
  printf -- '- `%s`\n' "$repo_name" >> "$cloud_setup"
done < "$resolved_repos"
cat >> "$cloud_setup" <<'EOF'
5. Under **Repository permissions**, set **Contents** to **Read and write** and **Pull requests** to **Read and write**. **Metadata: Read-only** is added automatically.
6. Generate and copy the token once. Go directly from GitHub to the Claude environment dialog; never paste it into the BlitzOS wizard, a repository, or a CLI command.

## 2. Create the personal cloud environment

1. Open https://claude.ai/code and choose **New cloud environment**.
2. In **Environment variables**, paste this `.env` line, replacing the placeholder with the token:

   ```dotenv
   BLITZOS_GIT_TOKEN=<token>
   ```

3. In **Setup script**, paste this defensive block. Setup-script timing and working directory are not guaranteed, so it runs the bootstrap only when it can locate this checkout and never fails session startup. The POWER MODE instructions in `CLAUDE.md` also require the bootstrap as the first repository action.

   ```bash
   #!/usr/bin/env bash
   set +e

   run_blitzos_bootstrap() {
     candidate=$1
     if [ -n "$candidate" ] && [ -f "$candidate/.gitmodules" ] \
       && [ -f "$candidate/docs/CLOUD-SETUP.md" ] \
       && [ -x "$candidate/bootstrap.sh" ]; then
       (cd "$candidate" && bash ./bootstrap.sh) || \
         printf 'BlitzOS bootstrap did not complete; open docs/CLOUD-SETUP.md in the selected repository.\n' >&2
       return 0
     fi
     return 1
   }

   for candidate in "${CLAUDE_PROJECT_DIR:-}" "${PWD:-}"; do
     run_blitzos_bootstrap "$candidate" && exit 0
   done

   if command -v find >/dev/null 2>&1; then
     for base in "${HOME:-}" /workspace /workspaces; do
       [ -n "$base" ] && [ -d "$base" ] || continue
       setup_doc=$(find "$base" -maxdepth 5 -type f \
         -path '*/docs/CLOUD-SETUP.md' -print -quit 2>/dev/null)
       [ -n "$setup_doc" ] || continue
       run_blitzos_bootstrap "${setup_doc%/docs/CLOUD-SETUP.md}"
       exit 0
     done
   fi

   exit 0
   ```

4. Leave **Network access** on **Trusted** and save the environment.

## 3. Start each session

Choose this personal environment, select only this monorepo in the session composer, and start the task. The setup script may bootstrap it automatically; Claude must still run `bash bootstrap.sh` as its first action.

`bootstrap.sh` fetches the latest 50 commits of each chosen branch. That keeps startup bounded while supporting ordinary task branches, commits, pushes, and PRs. If a task needs older history, deepen only that subrepository with `git -C repos/<name> fetch --deepen <count> origin` or unshallow it with `git -C repos/<name> fetch --unshallow origin`.

## Security model

Anthropic warns that environment variables are visible to anyone using the environment and says not to add secrets or credentials. This recipe is only for a **personal environment** whose only user is you. Never configure this token in a shared or team environment. The token is limited to the listed repositories, expires within 90 days, and can be revoked at https://github.com/settings/personal-access-tokens. Teams should wait for Managed BlitzOS credentials.

The token exists at session runtime. Do not print it, write it to a file, put it in a remote URL, commit it, or send it to connectors. `bootstrap.sh` stores only a helper command in each subrepository's local Git config; the helper reads the token from the environment when Git authenticates. The parent monorepo keeps Claude's native selected-repository credential path.

## Rotate or revoke the token

1. Before expiry, repeat the creation steps with the same resource owner, exact repository list, and permissions.
2. Edit this personal Claude cloud environment and replace only the `BLITZOS_GIT_TOKEN` value.
3. Start a new session, select only this monorepo, run `bash bootstrap.sh`, and verify fetch succeeds.
4. Revoke the old token at https://github.com/settings/personal-access-tokens. If exposure is suspected, revoke first and then create the replacement.
EOF
chmod 600 "$cloud_setup"

context_readme="$tmp_dir/context-README.md"
cat > "$context_readme" <<EOF
# $slug

This private BlitzOS context repository carries shared company guidance and concise session records for Claude Code.

[Launch this workspace in Claude Code]($launch_url)

For optional power mode, follow [docs/CLOUD-SETUP.md](docs/CLOUD-SETUP.md).
EOF
chmod 600 "$context_readme"

mkdir -p "$target"
chmod 700 "$target"
if ! git -C "$target" init -b main >/dev/null 2>&1; then
  git -C "$target" init >/dev/null 2>&1 || fail "git init failed in $target"
  git -C "$target" branch -m main >/dev/null 2>&1 || fail "could not name the initial branch main"
fi

install -m 644 "$context_readme" "$target/README.md"
install -m 644 "$claude_draft" "$target/CLAUDE.md"
install -m 755 "$bootstrap" "$target/bootstrap.sh"
mkdir -m 700 "$target/sessions"
install -m 644 "$sessions_readme" "$target/sessions/README.md"
install -m 644 /dev/null "$target/sessions/INDEX.md"
mkdir -m 700 "$target/docs"
install -m 644 "$cloud_setup" "$target/docs/CLOUD-SETUP.md"
mkdir -m 700 "$target/skills"
install -m 644 "$skills_readme" "$target/skills/README.md"
while IFS= read -r skill_name; do
  cp -Rp "$skills_staging/$skill_name" "$target/skills/$skill_name"
done < <(jq -r '.skills[]?' "$plan_file")

: > "$target/.gitmodules"
while IFS=$'\t' read -r repo_name branch sha; do
  repo_dir=${repo_name##*/}
  module_key="submodule.$repo_name"
  git config -f "$target/.gitmodules" "$module_key.path" "repos/$repo_dir"
  git config -f "$target/.gitmodules" "$module_key.url" "https://github.com/$repo_name.git"
  git config -f "$target/.gitmodules" "$module_key.branch" "$branch"
  git -C "$target" update-index --add --cacheinfo "160000,$sha,repos/$repo_dir"
done < "$resolved_repos"
chmod 644 "$target/.gitmodules"

unexpected=$(find "$target" -mindepth 1 -maxdepth 1 \
  ! -name .git ! -name .gitmodules ! -name README.md ! -name CLAUDE.md ! -name bootstrap.sh \
  ! -name docs ! -name sessions ! -name skills -print -quit)
[ -z "$unexpected" ] || fail 'unexpected output was generated; refusing to commit'
unexpected_session=$(find "$target/sessions" -mindepth 1 -maxdepth 1 \
  ! -name README.md ! -name INDEX.md -print -quit)
[ -z "$unexpected_session" ] || fail 'unexpected session scaffold output was generated; refusing to commit'
[ ! -s "$target/sessions/INDEX.md" ] || fail 'session index must be empty in a new context repository'
unexpected_docs=$(find "$target/docs" -mindepth 1 -maxdepth 1 \
  ! -name CLOUD-SETUP.md -print -quit)
[ -z "$unexpected_docs" ] || fail 'unexpected cloud setup output was generated; refusing to commit'
unexpected_skill_link=$(find "$target/skills" -type l -print -quit)
[ -z "$unexpected_skill_link" ] || fail 'a symlink reached the generated skills directory; refusing to commit'
[ -x "$target/bootstrap.sh" ] || fail 'bootstrap.sh must be executable'

while IFS= read -r generated_file; do
  generated_label=${generated_file#"$target/"}
  reject_secret_material "$generated_file" "generated $generated_label"
done < <(find "$target" -path "$target/.git" -prune -o -type f -print | LC_ALL=C sort)

git -C "$target" add -- .gitmodules README.md CLAUDE.md bootstrap.sh docs/CLOUD-SETUP.md \
  sessions/README.md sessions/INDEX.md skills
if ! git -c user.name=blitzos \
  -c user.email=blitzos@users.noreply.github.com \
  -C "$target" commit -m 'Add company context monorepo for Claude' >/dev/null 2>&1; then
  fail "git commit failed in $target; no GitHub repository was created"
fi

if [ "${BLITZOS_NO_PUSH:-0}" = 1 ]; then
  printf 'NO_PUSH: context monorepo built at %s\n' "$target"
else
  if ! gh repo create "$monorepo_full_name" --private --source "$target" --remote origin --push \
    > "$tmp_dir/gh-create.log" 2>&1; then
    partial_url=$(gh repo view "$monorepo_full_name" --json url --jq '.url' 2>/dev/null || true)
    if [ -n "$partial_url" ]; then
      fail "GitHub repository exists but the initial push did not complete: $partial_url; it is not ready"
    fi
    fail "private GitHub repository creation failed for $monorepo_full_name; no retry was attempted"
  fi

  repo_record=$(gh repo view "$monorepo_full_name" --json url,isPrivate --jq '[.url, .isPrivate] | @tsv' 2>/dev/null || true)
  repo_url=${repo_record%%$'\t'*}
  repo_private=${repo_record#*$'\t'}
  [ -n "$repo_url" ] || fail "GitHub repository was pushed but verification failed for $monorepo_full_name"
  [ "$repo_private" = true ] || fail "GitHub reported $monorepo_full_name as non-private; stop and inspect it immediately"
  printf 'Created private company context monorepo: %s\n' "$repo_url"
fi

printf 'Local checkout: %s\n' "$target"
printf '\nClaude launch link (open it, select nothing manually, and click Start):\n%s\n' "$launch_url"
