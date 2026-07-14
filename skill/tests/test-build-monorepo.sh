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

Their relationship is unknown in this fixture.

## User conventions

No conventions were observed.

## Connectors available to you

- GitHub: use for pull requests and repository metadata when relevant.

## Working across repositories

### Session mode

- DEFAULT mode: when both member repositories exist as native sibling checkouts, work in those checkouts and push or open PRs through the native GitHub rail. Do not run `bash bootstrap.sh`, and leave the monorepo's `repos/` gitlinks unchanged.
- POWER MODE: when only the context monorepo exists and member sibling checkouts are absent, run `bash bootstrap.sh`; this requires `BLITZOS_GIT_TOKEN`. Work under `repos/<name>`, use `GH_TOKEN="$BLITZOS_GIT_TOKEN" gh pr create`, and stage changed gitlinks.
- If the mode is ambiguous, stop before bootstrapping.

Push the context monorepo session log with plain `git push` in both modes.

## Session log (warm start)

Detect the session mode, then read `sessions/INDEX.md`. Write `sessions/<YYYY-MM-DD>-<short-task-slug>.md` with `## What changed`, `## Key decisions`, and `## For next session`, cross-link the PR URLs, then update the index. Stage gitlinks only in POWER MODE.
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
check 'CLAUDE.md power mode requires the token-backed bootstrap' \
  sh -c 'grep -Fq "POWER MODE" "$1" && grep -Fq "requires \`BLITZOS_GIT_TOKEN\`" "$1" && grep -Fq "stage changed gitlinks" "$1"' \
  sh "$target/CLAUDE.md"

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

finish
