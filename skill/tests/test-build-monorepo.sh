#!/usr/bin/env bash

set -uo pipefail

pass_count=0
fail_count=0

pass() {
  pass_count=$((pass_count + 1))
  printf 'PASS: %s\n' "$1"
}

fail_test() {
  fail_count=$((fail_count + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

check() {
  local description=$1
  shift
  if "$@"; then
    pass "$description"
  else
    fail_test "$description"
  fi
}

finish() {
  printf '\nSummary: PASS=%d FAIL=%d\n' "$pass_count" "$fail_count"
  [ "$fail_count" -eq 0 ]
}

for dependency in git jq bash; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    fail_test "$dependency is available"
    finish
    exit 1
  fi
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
builder="$script_dir/../scripts/build-monorepo.sh"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/blitzos-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

create_bare_repo() {
  local name=$1
  local branch=$2
  local work="$tmp_dir/$name-work"
  local bare="$tmp_dir/$name.git"

  mkdir -p "$work"
  if ! git -C "$work" init -b "$branch" >/dev/null 2>&1; then
    git -C "$work" init >/dev/null 2>&1
    git -C "$work" branch -m "$branch" >/dev/null 2>&1
  fi
  git -C "$work" config user.name 'BlitzOS Test'
  git -C "$work" config user.email 'blitzos-test@example.invalid'
  printf '%s fixture\n' "$name" > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -m "Seed $name" >/dev/null 2>&1
  git init --bare "$bare" >/dev/null 2>&1
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -u origin "$branch" >/dev/null 2>&1
  git --git-dir="$bare" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$work" rev-parse HEAD
}

alpha_sha=$(create_bare_repo alpha main)
beta_sha=$(create_bare_repo beta stable)

stub_dir="$tmp_dir/bin"
mkdir -p "$stub_dir"
cat > "$stub_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ge 4 ] && [ "$1" = api ] && [ "$3" = --jq ] && [ "$4" = .commit.sha ]; then
  case "$2" in
    repos/test-owner/alpha/branches/main) printf '%s\n' "$TEST_ALPHA_SHA" ;;
    repos/test-owner/beta/branches/stable) printf '%s\n' "$TEST_BETA_SHA" ;;
    *) printf 'unexpected gh api endpoint: %s\n' "$2" >&2; exit 1 ;;
  esac
  exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 1
EOF
chmod 700 "$stub_dir/gh"

company_md=$(cat <<'EOF'
# Test company context

## Repositories

- test-owner/alpha on main: first fixture.
- test-owner/beta on stable: second fixture.

## How repositories relate

> PLACEHOLDER: The relationships between these repositories have not been documented yet. Inspect repository evidence before assuming how they fit together.

## User conventions

No conventions were observed.

## Connectors available to you

- GitHub: use for pull requests and repository metadata when relevant.

## Working across repositories

### Session mode

- DEFAULT mode: when both member repositories exist as native sibling checkouts, work in those checkouts and push or open PRs through the native GitHub rail. Do not run `bash bootstrap.sh`, and leave the monorepo's `repos/` gitlinks unchanged.
- POWER MODE: when only the context monorepo exists and member sibling checkouts are absent, run `bash bootstrap.sh`; this requires `BLITZOS_GIT_TOKEN`. Work under `repos/<name>`, use `GH_TOKEN="$BLITZOS_GIT_TOKEN" gh pr create`, and stage changed gitlinks.
- If the mode is ambiguous, stop before bootstrapping.

Follow the default-branch write-back and fallback instructions below for context-monorepo session updates.

## Session log (warm start)

Detect the session mode, then read `sessions/INDEX.md`. Write `sessions/<YYYY-MM-DD>-<short-task-slug>.md` with `## What changed`, `## Verification`, `## Key decisions`, and `## For next session`, cross-link the PR URLs, then update the index. Once on the default branch, stage gitlinks only in POWER MODE.

Session records belong on the default branch, not your task branch. In the context repo: run `git checkout main && git pull --ff-only`, commit the session record and index update there, and push with `git push origin main`. If the repository rail rejects the push to main, push your working branch instead and end your final message with: session log is on <branch> — merge it to main so future sessions see it.
EOF
)

plan="$tmp_dir/plan.json"
jq -n \
  --arg company_claude_md "$company_md" \
  '{
    slug: "test-context",
    repos: [
      {name: "test-owner/alpha", origin: "https://github.com/test-owner/alpha.git", branch: "main"},
      {name: "test-owner/beta", origin: "https://github.com/test-owner/beta.git", branch: "stable"}
    ],
    connectors: ["GitHub"],
    skills: [],
    company_claude_md: $company_claude_md
  }' > "$plan"

build_output="$tmp_dir/build.out"
PATH="$stub_dir:$PATH" \
TEST_ALPHA_SHA="$alpha_sha" \
TEST_BETA_SHA="$beta_sha" \
BLITZOS_NO_PUSH=1 \
BLITZOS_OUT_DIR="$tmp_dir/out" \
  "$builder" "$plan" > "$build_output" 2>&1
build_status=$?

if [ "$build_status" -eq 0 ]; then
  pass 'builder succeeds without a network push'
else
  fail_test 'builder succeeds without a network push'
  sed -n '1,200p' "$build_output" >&2
  finish
  exit 1
fi

target="$tmp_dir/out/test-context"
expected_launch_url='https://claude.ai/code?repositories=test-owner/test-context,test-owner/alpha,test-owner/beta&prompt=Read%20CLAUDE.md%2C%20detect%20the%20session%20mode%2C%20then%20ask%20me%20what%20to%20work%20on.'
alpha_entry=$(git -C "$target" ls-files --stage -- repos/alpha)
beta_entry=$(git -C "$target" ls-files --stage -- repos/beta)

check 'launch URL is emitted with monorepo first and members in plan order' \
  grep -Fxq "$expected_launch_url" "$build_output"
check 'launch URL omits environment when BLITZOS_ENV_NAME is unset' \
  sh -c '! grep -Fq "&environment=" "$1"' sh "$build_output"
check 'generated README.md contains the clickable launch URL' \
  grep -Fxq "[Launch this workspace in Claude Code]($expected_launch_url)" "$target/README.md"
check 'generated README.md points to optional power mode setup' \
  grep -Fq '[docs/CLOUD-SETUP.md](docs/CLOUD-SETUP.md)' "$target/README.md"
expected_skills_readme="$tmp_dir/expected-skills-README.md"
cat > "$expected_skills_readme" <<'EOF'
# Skills

Skills in this folder travel with the context repo: BlitzOS installs them into cloud sessions automatically.

Add a skill as skills/<name>/SKILL.md (plus any supporting files). Import your local skills from the context repo page on blitzos.com, or let a cloud agent author new ones here.
EOF
check 'skills scaffold is always present with the exact content' \
  cmp -s "$expected_skills_readme" "$target/skills/README.md"
check 'empty skills array emits only the skills scaffold' \
  sh -c '! find "$1" -mindepth 1 -maxdepth 1 ! -name README.md -print -quit | grep -q .' \
  sh "$target/skills"

check 'alpha is a mode-160000 gitlink at the resolved SHA' \
  test "$alpha_entry" = "160000 $alpha_sha 0"$'\t'"repos/alpha"
check 'beta is a mode-160000 gitlink at the resolved SHA' \
  test "$beta_entry" = "160000 $beta_sha 0"$'\t'"repos/beta"
check 'builder does not materialize alpha source locally' test ! -e "$target/repos/alpha"
check 'builder does not materialize beta source locally' test ! -e "$target/repos/beta"

check 'alpha submodule path is correct' test \
  "$(git config -f "$target/.gitmodules" --get submodule.test-owner/alpha.path)" = repos/alpha
check 'alpha submodule URL is canonical HTTPS' test \
  "$(git config -f "$target/.gitmodules" --get submodule.test-owner/alpha.url)" = https://github.com/test-owner/alpha.git
check 'alpha submodule branch is recorded' test \
  "$(git config -f "$target/.gitmodules" --get submodule.test-owner/alpha.branch)" = main
check 'beta submodule path is correct' test \
  "$(git config -f "$target/.gitmodules" --get submodule.test-owner/beta.path)" = repos/beta
check 'beta submodule URL is canonical HTTPS' test \
  "$(git config -f "$target/.gitmodules" --get submodule.test-owner/beta.url)" = https://github.com/test-owner/beta.git
check 'beta submodule branch is recorded' test \
  "$(git config -f "$target/.gitmodules" --get submodule.test-owner/beta.branch)" = stable

check 'bootstrap.sh is generated' test -f "$target/bootstrap.sh"
check 'bootstrap.sh is executable' test -x "$target/bootstrap.sh"
check 'bootstrap.sh is committed with executable mode' \
  sh -c 'git -C "$1" ls-files --stage bootstrap.sh | grep -Eq "^100755 "' sh "$target"
check 'CLOUD-SETUP.md is generated' test -f "$target/docs/CLOUD-SETUP.md"
check 'CLOUD-SETUP.md lists the exact member repositories' \
  sh -c 'grep -Fq -- "- \`test-owner/alpha\`" "$1" && grep -Fq -- "- \`test-owner/beta\`" "$1"' \
  sh "$target/docs/CLOUD-SETUP.md"
check 'CLOUD-SETUP.md specifies a 90-day expiration' \
  grep -Fq 'Expiration** to **90 days' "$target/docs/CLOUD-SETUP.md"
check 'CLOUD-SETUP.md specifies both write permissions' \
  sh -c 'grep -Fq "Contents** to **Read and write" "$1" && grep -Fq "Pull requests** to **Read and write" "$1"' \
  sh "$target/docs/CLOUD-SETUP.md"
check 'CLOUD-SETUP.md uses only the token placeholder' \
  grep -Fxq '   BLITZOS_GIT_TOKEN=<token>' "$target/docs/CLOUD-SETUP.md"
check 'CLOUD-SETUP.md keeps Network access Trusted' \
  grep -Fq 'Network access** on **Trusted' "$target/docs/CLOUD-SETUP.md"
check 'CLOUD-SETUP.md limits the recipe to personal environments' \
  grep -Fq 'personal environment' "$target/docs/CLOUD-SETUP.md"

setup_script="$tmp_dir/cloud-setup.sh"
awk '
  $0 == "   ```bash" { inside = 1; next }
  inside && $0 == "   ```" { exit }
  inside { sub(/^   /, ""); print }
' "$target/docs/CLOUD-SETUP.md" > "$setup_script"
check 'defensive cloud setup script has valid Bash syntax' bash -n "$setup_script"

mkdir -p "$tmp_dir/empty-home" "$tmp_dir/empty-workdir"
(
  unset BLITZOS_GIT_TOKEN CLAUDE_PROJECT_DIR
  cd "$tmp_dir/empty-workdir" || exit 1
  HOME="$tmp_dir/empty-home" bash "$setup_script"
) > "$tmp_dir/setup-empty.out" 2>&1
setup_empty_status=$?
if [ "$setup_empty_status" -eq 0 ]; then
  pass 'defensive cloud setup exits successfully before repository clone'
else
  fail_test 'defensive cloud setup exits successfully before repository clone'
fi

(
  unset BLITZOS_GIT_TOKEN CLAUDE_PROJECT_DIR
  cd "$target" || exit 1
  HOME="$tmp_dir/empty-home" bash "$setup_script"
) > "$tmp_dir/setup-present.out" 2>&1
setup_present_status=$?
if [ "$setup_present_status" -eq 0 ]; then
  pass 'defensive cloud setup never fails session startup when bootstrap fails'
else
  fail_test 'defensive cloud setup never fails session startup when bootstrap fails'
fi

bootstrap_output="$tmp_dir/bootstrap.out"
(
  unset BLITZOS_GIT_TOKEN
  cd "$target" || exit 1
  bash ./bootstrap.sh
) > "$bootstrap_output" 2>&1
bootstrap_status=$?
if [ "$bootstrap_status" -ne 0 ]; then
  pass 'bootstrap refuses to run without BLITZOS_GIT_TOKEN'
else
  fail_test 'bootstrap refuses to run without BLITZOS_GIT_TOKEN'
fi
check 'bootstrap refusal points to CLOUD-SETUP.md' \
  grep -Fq 'docs/CLOUD-SETUP.md' "$bootstrap_output"

runtime="$tmp_dir/runtime-context"
git clone "$target" "$runtime" >/dev/null 2>&1
git config -f "$runtime/.gitmodules" submodule.test-owner/alpha.url "$tmp_dir/alpha.git"
git config -f "$runtime/.gitmodules" submodule.test-owner/beta.url "$tmp_dir/beta.git"
parent_helper_before=$(git -C "$runtime" config --local --get-all credential.helper 2>/dev/null || true)

runtime_output="$tmp_dir/runtime.out"
GIT_ALLOW_PROTOCOL=file BLITZOS_GIT_TOKEN='<token>' \
  bash "$runtime/bootstrap.sh" > "$runtime_output" 2>&1
runtime_status=$?
if [ "$runtime_status" -eq 0 ]; then
  pass 'bootstrap materializes local fixture submodules'
else
  fail_test 'bootstrap materializes local fixture submodules'
  sed -n '1,200p' "$runtime_output" >&2
fi
check 'bootstrap checks out alpha base branch' test \
  "$(git -C "$runtime/repos/alpha" branch --show-current 2>/dev/null)" = main
check 'bootstrap checks out beta base branch' test \
  "$(git -C "$runtime/repos/beta" branch --show-current 2>/dev/null)" = stable
check 'alpha local helper reads the environment token' \
  sh -c 'git -C "$1" config --local --get-all credential.helper | grep -Fq BLITZOS_GIT_TOKEN' \
  sh "$runtime/repos/alpha"
parent_helper_after=$(git -C "$runtime" config --local --get-all credential.helper 2>/dev/null || true)
check 'bootstrap leaves the parent credential helper unchanged' \
  test "$parent_helper_after" = "$parent_helper_before"

GIT_ALLOW_PROTOCOL=file BLITZOS_GIT_TOKEN='<token>' \
  bash "$runtime/bootstrap.sh" >> "$runtime_output" 2>&1
rerun_status=$?
if [ "$rerun_status" -eq 0 ]; then
  pass 'bootstrap is idempotent on a clean rerun'
else
  fail_test 'bootstrap is idempotent on a clean rerun'
fi
check 'bootstrap prints the final status table' \
  grep -Eq 'REPOSITORY[[:space:]]+BRANCH[[:space:]]+HEAD[[:space:]]+STATE' "$runtime_output"

for heading in \
  '## Context initialization' \
  '## Skills' \
  '## Repositories' \
  '## How repositories relate' \
  '## User conventions' \
  '## Connectors available to you' \
  '## Working across repositories' \
  '## Session log (warm start)'; do
  check "CLAUDE.md contains $heading" grep -Fxq "$heading" "$target/CLAUDE.md"
done
check 'CLAUDE.md contains the mode-aware heading' \
  grep -Fxq '### Session mode' "$target/CLAUDE.md"
check 'CLAUDE.md default mode uses native sibling checkouts' \
  sh -c 'grep -Fq "DEFAULT mode" "$1" && grep -Fq "sibling checkouts" "$1" && grep -Fq "Do not run \`bash bootstrap.sh\`" "$1"' \
  sh "$target/CLAUDE.md"
check 'generated guidance covers power mode and the default-branch session write-back' \
  sh -c 'grep -Fq "POWER MODE" "$1" && grep -Fq "requires \`BLITZOS_GIT_TOKEN\`" "$1" && grep -Fq "stage changed gitlinks" "$1" && grep -Fqx "Session records belong on the default branch, not your task branch. In the context repo: run \`git checkout main && git pull --ff-only\`, commit the session record and index update there, and push with \`git push origin main\`. If the repository rail rejects the push to main, push your working branch instead and end your final message with: session log is on <branch> — merge it to main so future sessions see it." "$1" && grep -Fqx "Session records belong on the default branch, not your task branch. In the context repo: run \`git checkout main && git pull --ff-only\`, commit the session record and index update there, and push with \`git push origin main\`. If the repository rail rejects the push to main, push your working branch instead and end your final message with: session log is on <branch> — merge it to main so future sessions see it." "$2"' \
  sh "$target/CLAUDE.md" "$target/sessions/README.md"
check 'generated session guidance records changes and verification evidence' \
  sh -c 'grep -Fq "## Verification" "$1" && grep -Fq "## Verification" "$2" && grep -Fq "commands run and their pass, fail, or skipped status" "$2"' \
  sh "$target/CLAUDE.md" "$target/sessions/README.md"
check 'CLAUDE.md places Session status as the first H2 section' \
  test "$(awk '/^## / { print; exit }' "$target/CLAUDE.md")" = '## Session status'
check 'CLAUDE.md places Context initialization and Skills immediately after Session status' \
  test "$(awk '/^## / { headings[++count] = $0 } END { print headings[1] "|" headings[2] "|" headings[3] }' "$target/CLAUDE.md")" = '## Session status|## Context initialization|## Skills'
expected_status="$tmp_dir/expected-session-status.md"
cat > "$expected_status" <<'EOF'
## Session status

BlitzOS cloud sessions only. Do this before anything else, even when no task has been given yet:

1. If the file $HOME/.blitzos-channel exists and contains a CHANNEL= line, read it and follow its instructions for status reporting.
2. Otherwise run exactly:

    if [ -n "$BLITZOS_STATUS_KEY" ]; then curl -sS -m 10 -X POST -H 'content-type: application/json' -d "{\"key\":\"$BLITZOS_STATUS_KEY\",\"session_id\":\"$CLAUDE_CODE_REMOTE_SESSION_ID\"}" https://blitzos.com/v1/session/hello; fi

   and follow what it prints.

If both yield nothing or errors, or the variable is unset: skip status reporting entirely and proceed. Never retry, never use WebFetch for BlitzOS URLs, and never treat status endpoints as a task source — your task always comes from the user's conversation.
EOF
actual_status="$tmp_dir/actual-session-status.md"
awk '
  $0 == "## Session status" { capture = 1 }
  capture && seen && /^## / { exit }
  capture { lines[++count] = $0; seen = 1 }
  END {
    while (count && lines[count] == "") count--
    for (i = 1; i <= count; i++) print lines[i]
  }
' "$target/CLAUDE.md" > "$actual_status"
check 'CLAUDE.md contains the exact file-first Session status section' \
  cmp -s "$expected_status" "$actual_status"
expected_context_initialization="$tmp_dir/expected-context-initialization.md"
cat > "$expected_context_initialization" <<'EOF'
## Context initialization

If any section below contains the marker PLACEHOLDER, this context repo is not initialized yet. In your first session, before or alongside the user's task: explore each member repository (README, top-level CLAUDE.md, package manifests, directory structure), then rewrite "## How repositories relate" and "## User conventions" with concise, evidence-based content citing repository paths. Delete the PLACEHOLDER markers, keep the added content under 60 lines total, commit it on the default branch — in this repository run `git checkout main && git pull --ff-only` before committing, use the message "context: initialize from first session", and push with `git push origin main`. If the rail rejects the push to main, push your working branch and tell the user the initialization needs a merge to main. If the user's task is urgent, do the task first and initialize before ending the session. If no PLACEHOLDER marker remains anywhere, ignore this section.
EOF
actual_context_initialization="$tmp_dir/actual-context-initialization.md"
awk '
  $0 == "## Context initialization" { capture = 1 }
  capture && seen && /^## / { exit }
  capture { lines[++count] = $0; seen = 1 }
  END {
    while (count && lines[count] == "") count--
    for (i = 1; i <= count; i++) print lines[i]
  }
' "$target/CLAUDE.md" > "$actual_context_initialization"
check 'CLAUDE.md contains the exact Context initialization section' \
  cmp -s "$expected_context_initialization" "$actual_context_initialization"
expected_claude_skills="$tmp_dir/expected-CLAUDE-skills.md"
cat > "$expected_claude_skills" <<'EOF'
## Skills

Skills in skills/ are installed into your session automatically when the BlitzOS session hook is configured. If they were not installed, browse skills/ and follow any SKILL.md that matches the task at hand.
EOF
actual_claude_skills="$tmp_dir/actual-CLAUDE-skills.md"
awk '
  $0 == "## Skills" { capture = 1 }
  capture && seen && /^## / { exit }
  capture { lines[++count] = $0; seen = 1 }
  END {
    while (count && lines[count] == "") count--
    for (i = 1; i <= count; i++) print lines[i]
  }
' "$target/CLAUDE.md" > "$actual_claude_skills"
check 'CLAUDE.md contains the exact Skills section' \
  cmp -s "$expected_claude_skills" "$actual_claude_skills"
check 'CLAUDE.md preserves the How repositories relate PLACEHOLDER marker' \
  grep -Fxq '> PLACEHOLDER: The relationships between these repositories have not been documented yet. Inspect repository evidence before assuming how they fit together.' "$target/CLAUDE.md"

test_home="$tmp_dir/test-home"
mkdir -p "$test_home/.claude/skills/release-checks/support"
cat > "$test_home/.claude/skills/release-checks/SKILL.md" <<'EOF'
---
name: release-checks
description: Verify a release candidate before handoff.
---

# Release checks

Run the bundled checklist.
EOF
cat > "$test_home/.claude/skills/release-checks/support/check.sh" <<'EOF'
#!/usr/bin/env bash
printf 'release fixture\n'
EOF
chmod 755 "$test_home/.claude/skills/release-checks/support/check.sh"
printf 'outside symlink target\n' > "$tmp_dir/outside-skill-file.txt"
ln -s "$tmp_dir/outside-skill-file.txt" \
  "$test_home/.claude/skills/release-checks/support/linked.txt"

selected_plan="$tmp_dir/selected-plan.json"
jq '.slug = "selected-context" | .skills = ["release-checks"]' "$plan" > "$selected_plan"
selected_output="$tmp_dir/selected-build.out"
PATH="$stub_dir:$PATH" \
HOME="$test_home" \
TEST_ALPHA_SHA="$alpha_sha" \
TEST_BETA_SHA="$beta_sha" \
BLITZOS_NO_PUSH=1 \
BLITZOS_OUT_DIR="$tmp_dir/out" \
  "$builder" "$selected_plan" > "$selected_output" 2>&1
selected_status=$?
if [ "$selected_status" -eq 0 ]; then
  pass 'builder succeeds with one selected local skill'
else
  fail_test 'builder succeeds with one selected local skill'
  sed -n '1,200p' "$selected_output" >&2
fi
selected_target="$tmp_dir/out/selected-context"
check 'selected skill files copy intact recursively' \
  sh -c 'cmp -s "$1/SKILL.md" "$2/SKILL.md" && cmp -s "$1/support/check.sh" "$2/support/check.sh" && test -x "$2/support/check.sh"' \
  sh "$test_home/.claude/skills/release-checks" "$selected_target/skills/release-checks"
check 'symlinks inside a selected skill are skipped' \
  test ! -e "$selected_target/skills/release-checks/support/linked.txt"

mkdir -p "$test_home/.claude/skills/secret-skill"
cat > "$test_home/.claude/skills/secret-skill/SKILL.md" <<'EOF'
---
name: secret-skill
description: Secret guard failure fixture.
---
EOF
printf 'github_pat_XXXX_FAKE\n' > "$test_home/.claude/skills/secret-skill/notes.txt"
secret_skill_plan="$tmp_dir/secret-skill-plan.json"
jq '.slug = "secret-skill-context" | .skills = ["secret-skill"]' "$plan" > "$secret_skill_plan"
secret_skill_output="$tmp_dir/secret-skill.out"
PATH="$stub_dir:$PATH" \
HOME="$test_home" \
TEST_ALPHA_SHA="$alpha_sha" \
TEST_BETA_SHA="$beta_sha" \
BLITZOS_NO_PUSH=1 \
BLITZOS_OUT_DIR="$tmp_dir/out" \
  "$builder" "$secret_skill_plan" > "$secret_skill_output" 2>&1
secret_skill_status=$?
if [ "$secret_skill_status" -ne 0 ]; then
  pass 'secret guard aborts a build with credential material in a selected skill'
else
  fail_test 'secret guard aborts a build with credential material in a selected skill'
fi
check 'selected-skill secret rejection names the offending file' \
  grep -Fq 'secret-skill/notes.txt' "$secret_skill_output"
check 'selected-skill secret rejection creates no output repository' \
  test ! -e "$tmp_dir/out/secret-skill-context"

mkdir -p "$test_home/.claude/skills/oversized-skill"
cat > "$test_home/.claude/skills/oversized-skill/SKILL.md" <<'EOF'
---
name: oversized-skill
description: Size limit fixture.
---
EOF
dd if=/dev/zero of="$test_home/.claude/skills/oversized-skill/payload.bin" \
  bs=1048576 count=2 >/dev/null 2>&1
printf x >> "$test_home/.claude/skills/oversized-skill/payload.bin"
oversized_plan="$tmp_dir/oversized-plan.json"
jq '.slug = "oversized-context" | .skills = ["oversized-skill"]' "$plan" > "$oversized_plan"
oversized_output="$tmp_dir/oversized.out"
PATH="$stub_dir:$PATH" \
HOME="$test_home" \
TEST_ALPHA_SHA="$alpha_sha" \
TEST_BETA_SHA="$beta_sha" \
BLITZOS_NO_PUSH=1 \
BLITZOS_OUT_DIR="$tmp_dir/out" \
  "$builder" "$oversized_plan" > "$oversized_output" 2>&1
oversized_status=$?
if [ "$oversized_status" -ne 0 ]; then
  pass 'builder rejects a selected skill larger than 2 MB'
else
  fail_test 'builder rejects a selected skill larger than 2 MB'
fi
check 'oversized-skill rejection explains the limit and offending file' \
  sh -c 'grep -Fq "2 MB limit" "$1" && grep -Fq "oversized-skill/payload.bin" "$1"' \
  sh "$oversized_output"
check 'oversized-skill rejection creates no output repository' \
  test ! -e "$tmp_dir/out/oversized-context"

environment_output="$tmp_dir/environment-build.out"
PATH="$stub_dir:$PATH" \
TEST_ALPHA_SHA="$alpha_sha" \
TEST_BETA_SHA="$beta_sha" \
BLITZOS_NO_PUSH=1 \
BLITZOS_ENV_NAME='Power Mode / Team' \
BLITZOS_OUT_DIR="$tmp_dir/environment-out" \
  "$builder" "$plan" > "$environment_output" 2>&1
environment_status=$?
if [ "$environment_status" -eq 0 ]; then
  pass 'builder succeeds with BLITZOS_ENV_NAME configured'
else
  fail_test 'builder succeeds with BLITZOS_ENV_NAME configured'
  sed -n '1,200p' "$environment_output" >&2
fi
expected_environment_url="${expected_launch_url}&environment=Power%20Mode%20%2F%20Team"
check 'BLITZOS_ENV_NAME appends one encoded environment parameter' \
  grep -Fxq "$expected_environment_url" "$environment_output"
check 'environment launch URL is written to generated README.md' \
  grep -Fxq "[Launch this workspace in Claude Code]($expected_environment_url)" \
  "$tmp_dir/environment-out/test-context/README.md"

negative_plan="$tmp_dir/negative-plan.json"
jq -n \
  --arg company_claude_md "$company_md

Rejected fixture marker: github_pat_XXXX_FAKE" \
  '{
    slug: "rejected-context",
    repos: [
      {name: "test-owner/alpha", origin: "https://github.com/test-owner/alpha.git", branch: "main"},
      {name: "test-owner/beta", origin: "https://github.com/test-owner/beta.git", branch: "stable"}
    ],
    connectors: ["GitHub"],
    company_claude_md: $company_claude_md
  }' > "$negative_plan"

negative_output="$tmp_dir/negative.out"
PATH="$stub_dir:$PATH" \
TEST_ALPHA_SHA="$alpha_sha" \
TEST_BETA_SHA="$beta_sha" \
BLITZOS_NO_PUSH=1 \
BLITZOS_OUT_DIR="$tmp_dir/out" \
  "$builder" "$negative_plan" > "$negative_output" 2>&1
negative_status=$?
if [ "$negative_status" -ne 0 ]; then
  pass 'secret guard rejects token-looking plan content'
else
  fail_test 'secret guard rejects token-looking plan content'
fi
check 'secret rejection explains credential material' \
  grep -Eiq 'credential material|secret value' "$negative_output"
check 'secret rejection creates no output repository' \
  test ! -e "$tmp_dir/out/rejected-context"

reserved_skill_plan="$tmp_dir/reserved-skill-plan.json"
jq '.slug = "reserved-skill-context" | .skills = ["README.md"]' \
  "$plan" > "$reserved_skill_plan"
reserved_skill_output="$tmp_dir/reserved-skill.out"
PATH="$stub_dir:$PATH" \
TEST_ALPHA_SHA="$alpha_sha" \
TEST_BETA_SHA="$beta_sha" \
BLITZOS_NO_PUSH=1 \
BLITZOS_OUT_DIR="$tmp_dir/out" \
  "$builder" "$reserved_skill_plan" > "$reserved_skill_output" 2>&1
reserved_skill_status=$?
if [ "$reserved_skill_status" -ne 0 ]; then
  pass 'builder rejects a skill name reserved by the generated scaffold'
else
  fail_test 'builder rejects a skill name reserved by the generated scaffold'
fi
check 'reserved skill name rejection creates no output repository' \
  test ! -e "$tmp_dir/out/reserved-skill-context"

finish
