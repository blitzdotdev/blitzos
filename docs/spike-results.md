# BlitzOS: Claude cloud handoff feasibility spike

Run date: 2026-07-12 (America/Los_Angeles)

Full command/output transcript: `/tmp/spike-log.txt`

Test account and workstation identifiers are anonymized in this public report.

## Phase 0 — Inventory

| Surface / assumption | Observed on Claude Code 2.1.170 | Status |
|---|---|---|
| `claude --version` | `2.1.170 (Claude Code)` | EXISTS |
| `claude --cloud` | Omitted from full help, but later direct probe proved it is a working hidden interactive-only flag | EXISTS (HIDDEN / INTERACTIVE-ONLY) |
| `claude cloud` / `claude web` | Not listed among documented subcommands | ABSENT |
| `/web-setup` | Not discoverable from CLI help; deferred direct print-mode probe to Phase 2 | UNDOCUMENTED |
| `/remote-env` / remote environment CLI | No flag/subcommand in full help | ABSENT |
| `claude routines` | `claude routines --help` falls through to root help; there is no routines subcommand | ABSENT |
| `/routines` | Later direct print-mode probe proved this slash surface exists and can create/list/update/run cloud routines | EXISTS (HIDDEN SLASH SURFACE) |
| Routine HTTP beta `experimental-cc-routine-2026-04-01` | No documented flag/subcommand or help text | ABSENT |
| `teleport` | Omitted from help, but cloud dispatch printed `claude --teleport <session-id>` and the flag worked with `-p` for report retrieval | EXISTS (HIDDEN) |
| `--resume`, `--continue`, `--from-pr` | Present, but documented as local conversation/session resume surfaces, not cloud dispatch | EXISTS (LOCAL SESSION SURFACE) |
| `--remote-control [name]` | Present; documented as starting an interactive session with Remote Control, not cloud compute dispatch | EXISTS (INTERACTIVE) |
| `claude agents --json` | Present for local background-agent session listing; no documented cloud dispatch option | EXISTS (LOCAL BACKGROUND AGENTS) |
| `claude ultrareview` | Explicitly documented as a “cloud-hosted multi-agent code review”; fixed review workflow, not arbitrary task dispatch | EXISTS (SPECIALIZED CLOUD WORKFLOW) |
| `claude -p "/help"` | Prints `/help isn't available in this environment.` with exit 0 | UNAVAILABLE IN PRINT MODE |
| GitHub CLI auth | Active `example-owner`; HTTPS; token scopes include `repo` and `workflow` | READY |

### Phase 0 evidence

- `claude --version` → `2.1.170 (Claude Code)`.
- Full `claude --help` contains `--remote-control`, `--resume`, `--continue`, `--from-pr`, `agents`, and `ultrareview`; none of the plan's general cloud/environment/routine surfaces appear.
- `claude ultrareview --help` says it runs a cloud-hosted multi-agent review and only offers `--json` and `--timeout`.
- `claude project --help` only exposes `purge`; `claude auth --help` only exposes login/logout/status.
- `gh auth status` confirms the requested GitHub identity and private-repository-capable scopes.

### Plan-assumption comparison

The installed help text does not match the assumed general cloud handoff API. Later direct candidate probing showed that `--cloud` and `--teleport` are implemented but hidden from `--help`; no private endpoint was used.

## Phase 1 — Test repositories

**Verdict: PASS.** Both purpose-built repositories were created privately, committed, pushed, and independently verified through GitHub CLI.

### Evidence

- `gh repo create example-owner/tw-spike-target --private --clone ...` → `https://github.com/example-owner/tw-spike-target`.
- Target commit `6e43902` contains `package.json` with one dependency (`lodash`), `index.js`, `README.md`, and `.claude/settings.json`.
- The target `SessionStart` hook writes `REMOTE=$CLAUDE_CODE_REMOTE hostname=$(hostname)` to `/tmp/hook-fired.txt`.
- The target `Stop` hook runs `git -C /tmp/tw-spike-machine push` when that path exists.
- `gh repo create example-owner/tw-spike-machine --private --clone ...` → `https://github.com/example-owner/tw-spike-machine`.
- Machine commit `3140b51` contains marker `SPIKE-MARKER-7749`, `learnings/.gitkeep`, and dummy base64 at `secrets/fake.env.age`.
- `gh repo view ... --json ...` reports `isPrivate:true` and default branch `main` for both; both local checkouts are clean and track `origin/main`.

### Repository URLs

- https://github.com/example-owner/tw-spike-target
- https://github.com/example-owner/tw-spike-machine

## GATE 1 — Environment creation / zero-touch

**Verdict: SEMI-AUTO — revised after Phase 3.** `/web-setup` and `/remote-env` are unavailable, but the hidden interactive `--cloud` flag implicitly created/selected managed cloud compute without opening a browser. No CLI/config surface was found for injecting a custom setup script.

### Evidence

- From `/tmp/tw-spike-target`, `claude -p "/web-setup"` → `/web-setup isn't available in this environment.` (exit 0).
- From the same checkout, `claude -p "/remote-env"` → `/remote-env isn't available in this environment.` (exit 0).
- Full `claude --help` exposes no `--cloud`, `cloud`, `web`, `web-setup`, `remote-env`, environment, or setup-script option.
- No discovered documented project setting or CLI flag accepts a cloud setup script. The only `--settings` flag applies settings to the current Claude Code session; it is not documented as provisioning a hosted environment.
- The local `SessionStart` hook did execute during print-mode probes and wrote `REMOTE= hostname=developer-machine.local`, confirming these probes ran locally rather than in cloud compute.
- Phase 3 later proved `claude --cloud <prompt>` can create a cloud session directly and that the cloud checkout includes project hooks. This is evidence of implicit/default environment bootstrap, not programmable setup-script configuration.

### Exact blocker / manual step

For a custom setup script, a human must open the cloud environment settings for `tw-spike-target` in Claude Code on the web and enter/save the script there. No discovered CLI flag, slash command, project config, or documented subcommand can perform that injection. Separately, cross-repo access requires the GitHub App authorization described under Gate 2.

### Product implication

The alpha can dispatch into a default managed environment from the CLI, but it must treat custom setup-script configuration as a one-time UI bootstrap and feature-detect the hidden flag because help discovery cannot reveal it.

## Phase 3 — Cloud dispatch

The exact probe was dispatched successfully as cloud session `session_01EY1Tt72ojtsknQPybFKGPT`.

### Dispatch and monitoring evidence

- `claude --cloud -p "<exact probe>"` failed cleanly: `--cloud cannot be combined with --print. Cloud sessions are interactive only.`
- The last-resort PTY invocation `claude --cloud "<exact probe>"` succeeded and printed:
  - `Created cloud session: Run diagnostic checks and report results`
  - `View: https://claude.ai/code/session_01EY1Tt72ojtsknQPybFKGPT?from=cli&m=0`
  - `Resume with: claude --teleport session_01EY1Tt72ojtsknQPybFKGPT`
- `claude agents --json --all --cwd /tmp/tw-spike-target` returned `[]`; local background-agent listing does not expose cloud status.
- GitHub polling showed no new machine-repo commit. `claude --teleport session_01EY1Tt72ojtsknQPybFKGPT -p "Restate ... without running any new checks"` retrieved the completed report.

## GATE 2 — Context path / second-repository clone and write

**Verdict: FAIL.** The cloud task could not clone the private second repository, so it could not read `SPIKE-MARKER-7749`, commit a learning, or push back.

### Evidence

- Retrieved cloud report: clone failed with `could not read Username`; the private repository had no usable cloud-side GitHub authentication.
- Marker fetch therefore never occurred, and the dependent commit/push step was skipped.
- Independent GitHub verification still shows only commit `3140b51` and only `learnings/.gitkeep`; no cloud-side write reached the repository.

### Exact blocker / manual step

In GitHub, the human must configure the Claude GitHub App installation for account `example-owner` and add private repository `tw-spike-machine` to its selected repository access (or select all repositories, if intentionally acceptable). Then rerun the exact cloud probe. If Claude Code on the web separately prompts to connect that repository, approve the same repository there as well.

### Product implication

A target-repo cloud session does not inherit the local `gh` credential and cannot assume arbitrary private sibling-repo access; the alpha needs an explicit preflight/authorization step per machine repository.

## GATE 3 — Hooks, remote reporting, and default network policy

**Verdict: PASS for remote hook/reporting; outbound-network probe FAILS by default.** The cloud report was recoverable via CLI and showed the project hook fired remotely, while the tested public HTTPS request was blocked/failing.

### Evidence

- Cloud environment reported `$CLAUDE_CODE_REMOTE` as `true`.
- `/tmp/hook-fired.txt` existed in the cloud VM and contained `REMOTE=true hostname=vm`.
- `curl -s -m 5 https://httpbin.org/get` failed with curl exit 56, HTTP 000, and no response body.
- The cloud session's result was retrieved non-interactively with hidden `--teleport <session-id> -p ...` after dispatch.

### Exact blocker / manual step

No manual step is needed for SessionStart hooks or CLI report retrieval. If the alpha requires arbitrary outbound HTTPS, a human/admin must allowlist the required domain(s) in the Claude web environment's network settings or use an approved network configuration; then rerun the curl probe to verify the policy.

### Product implication

Hooks can report remote identity reliably, but arbitrary public egress must be treated as denied until explicitly configured and verified.

## GATE 4 — Routines / remote spawn

**Verdict: NOT-PARAMETERIZABLE.** Programmatic CLI creation and “run now” work for a stored/file-driven prompt, but this routine surface exposes no HTTP trigger endpoint, token creation, beta selector, or supported per-invocation payload.

### Evidence

- `claude routines --help` is not a real subcommand and falls through to root help, but `claude -p "/routines help"` exposes a hidden cloud-routine slash surface.
- Help reports exactly cron, one-time, and run-now triggers. It reports one available environment, `Default` (`anthropic_cloud`).
- Added and pushed target commit `3601aa1` containing `ROUTINE_TASK.md`: read the first README line, report it, and make no changes.
- `claude -p "/routines Create ..."` created `tw-spike-file-probe`, ID `trig_01LvNvWKUnogCkX6YptKpc7D`, with exact stored prompt `Read ROUTINE_TASK.md in the repository and follow its instruction.`
- The one-time schedule was set safely to `2027-01-01T07:00:00Z` and was not allowed to fire on schedule during the spike.
- A CLI “run now” dispatched cloud session `cse_016f3k5vCzFCoGfma1gcofKr` successfully.
- `claude --teleport cse_016f3k5vCzFCoGfma1gcofKr -p ...` retrieved the result: first README line `# tw-spike-target`; no repository changes were made. This proves the cloud run consumed the repo-file instruction.
- The routine was then updated to `enabled=false`; it will not fire at its future timestamp unless a human re-enables it.
- Readback confirmed environment `Default` (`anthropic_cloud`) and two inherited connectors, `Claude_Code_Remote` and `Socialloop`. This conflicts with the earlier help response saying no MCP connectors were connected, so connector inheritance must be inspected rather than inferred from help text.
- A read-only `/routines` capability query reported no HTTP trigger type, public endpoint, token-minting action, supported per-run payload contract, or exposure of beta `experimental-cc-routine-2026-04-01`.
- Consequently there was no endpoint/token with which to perform the requested POST. No private endpoint was called or scraped.

### Exact blocker / manual step

There is no one-time UI authorization step that makes HTTP triggering or dynamic payloads available in this observed routine surface. To use it as-is, the alpha must store a fixed prompt (or commit/update a repo instruction file) and invoke “run now” through `/routines`. For a clean external HTTP trigger with per-request parameters, the product needs a separately documented Anthropic API/CLI feature; none is exposed here.

### Product implication

Routines can serve as a CLI-controlled fixed-job launcher and can indirect through a versioned repo file, but they are not a parameterized webhook/job API.

## Phase 5 — Warm-vs-cold baseline

**Verdict: BLOCKED (prerequisite failed; no timings collected).** Phase 5 was explicitly conditional on Phase 3 passing. Phase 3 did not fully pass because Gate 2 could neither clone nor write the private machine repository.

### Evidence

- The prerequisite exact probe failed at private second-repo clone with `could not read Username`.
- No marker was read and no learning commit was pushed, so a “warm” follow-up involving `/tmp/m` would not measure the intended successful context path.
- Per the phase condition, neither warm nor cold comparison session was dispatched.

### Exact blocker / manual step

Authorize `tw-spike-machine` for the Claude GitHub App as specified under Gate 2, rerun the exact Phase 3 probe until marker read and push both succeed, and only then dispatch the two timed warm/cold tasks.

### Product implication

There is no valid warm-vs-cold latency or context-isolation datapoint from this spike; the cross-repo authorization preflight must pass first.

## WHAT THE ALPHA CAN ASSUME

- `claude --cloud "<prompt>"` can create an arbitrary managed cloud session without opening a browser, but it is hidden from help, requires a TTY, and rejects `--print`.
- Default managed compute is implicit; custom setup-script injection has no observed CLI/config path and should be treated as a one-time web-UI setup.
- Project `SessionStart` hooks run remotely with `CLAUDE_CODE_REMOTE=true`; completed reports can be retrieved with hidden `--teleport`, while `claude agents --json` does not list cloud sessions.
- Cloud sessions do not inherit local `gh` credentials: each private sibling repo needs explicit Claude GitHub App access, and arbitrary outbound HTTPS should be assumed blocked until allowlisted and retested.
- `/routines` can create and run fixed/file-driven cloud jobs, but not HTTP-triggered or per-request-parameterized jobs; inspect inherited environment connectors explicitly.

## Phase 6 — Retest

Run date: 2026-07-12 (America/Los_Angeles)

### Authorization method

**Verdict: MANUAL NEEDED; API preflight is blocked by the credential type available to `gh`.**

- `gh api /user/installations` returned HTTP 403: `You must authenticate with an access token authorized to a GitHub App in order to list installations`.
- `gh api /repos/example-owner/tw-spike-target/installation` and the equivalent `tw-spike-machine` request both returned HTTP 401: `A JSON web token could not be decoded`.
- The machine repository ID was retrieved successfully as `1298880604`.
- Because the installation listing failed, the Claude/Anthropic app slug, installation ID, repository-selection mode, and permission map could not be observed. There was therefore no valid installation ID with which to issue `PUT /user/installations/{installation_id}/repositories/1298880604`; sending a guessed ID would not be a valid authorization test.

**Exact single manual step:** GitHub **Settings → Applications → Claude → Repository access → add `tw-spike-machine`** (and save the selection).

Per the retest stop condition, no cloud sessions were dispatched after the 403 and no GitHub installation setting was changed.

### Gate 2 final verdict

**BLOCKED-ON-HUMAN; not retested.** The previous clone failure remains the latest cloud evidence. Clone and push-back are both unverified after this authorization attempt because the required repository addition could not be made through the available `gh` credential.

The app permission level is **UNOBSERVED**: the installation endpoints did not return an installation object or `permissions` field. Consequently, read-only versus write access cannot yet be classified. After the manual repository addition, the exact Phase 3 probe must be rerun; a successful clone plus failed push would establish the key read-only-permission finding.

Independent readback after the stopped retest showed `tw-spike-machine` still at original commit `3140b51bf7ac419b859e4599d079633c3d431e1a` (`Initialize machine context probe`) and `learnings/` still containing only `.gitkeep`.

### Warm-vs-cold baseline

| Case | Dispatch | Wall-clock time | Transcript evidence |
|---|---:|---:|---|
| Warm | BLOCKED-ON-HUMAN | — | Not dispatched because the clone prerequisite was not re-established. |
| Cold | BLOCKED-ON-HUMAN | — | Not dispatched per the stop condition after authorization API failure. |

No crude first datapoint can be reported from this retest; collecting timings before repository authorization would measure a known failure path rather than the requested warm-versus-cold context comparison.

### Cleanup and safety

- Read-only routine readback confirmed `tw-spike-file-probe` (`trig_01LvNvWKUnogCkX6YptKpc7D`) remains disabled: `enabled=false`; it was not run or mutated.
- Neither test repository was deleted or modified during Phase 6.
- GitHub-account changes made in Phase 6: **none**. No installation repository was added, so there is nothing from this phase to revert.

### WHAT THE ALPHA CAN ASSUME — delta

- On this machine, the authenticated `gh` credential cannot enumerate or modify Claude GitHub App installations, so this authorization preflight is not fully scriptable with the currently available token.
- Private sibling-repository clone and push must remain fail-closed until a human adds the repository to Claude's GitHub App access and an exact probe verifies both read and write behavior.
- The disabled routine remains safe, and the failed API attempt made no GitHub-account or repository changes.

## Phase 7 — Post-authorization

Run date: 2026-07-12 (America/Los_Angeles)

### Gate 2 final verdicts

The exact post-authorization probe was dispatched from `/tmp/tw-spike-target` as cloud session `session_01A9GpLJ7ugM7Zts9WxRpka4` and retrieved through `claude --teleport` after the cloud run stopped.

| Check | Final verdict | Evidence |
|---|---|---|
| Clone in | **FAIL** | `git clone https://github.com/example-owner/tw-spike-machine /tmp/m` failed with `fatal: could not read Username for 'https://github.com': terminal prompts disabled`. The cloud agent's token retry also failed with `remote: Invalid username or token. Password authentication is not supported for Git operations.` followed by `fatal: Authentication failed for 'https://github.com/example-owner/tw-spike-machine/'`. |
| Push back | **FAIL (not reached)** | The clone failure left no `/tmp/m` working tree, so no commit or push was attempted. The retrieved report states exactly: `No push was attempted, so there is no push result to report.` Independent GitHub readback found no new learning file or commit. |
| Outbound curl | **FAIL, as expected** | The pipeline returned no body; the cloud agent's diagnostic retry exposed `curl: (56) CONNECT tunnel failed, response 403` and `HTTP_CODE=000`. Arbitrary public HTTPS remains blocked by the proxy. |

### Remote execution evidence

- `$CLAUDE_CODE_REMOTE` was `true`.
- `/tmp/hook-fired.txt` existed in the cloud VM and contained `REMOTE=true hostname=vm`, confirming the target repository's `SessionStart` hook still runs remotely.
- CLI dispatch and result retrieval both succeeded for session `session_01A9GpLJ7ugM7Zts9WxRpka4`.
- Independent verification with `gh api /repos/example-owner/tw-spike-machine/contents/learnings --jq '.[].name'` returned only `.gitkeep`.
- Independent commit readback still showed only original commit `3140b51bf7ac` (`Initialize machine context probe`, `2026-07-13T04:57:33Z`).

The human-granted Claude GitHub App "All repositories" access did not produce usable sibling-repository Git credentials inside this new cloud session. The observed cloud environment had `GH_TOKEN`/`GITHUB_TOKEN`, but its retry reported that token as invalid.

### Warm-vs-cold — prerequisite result

| Case | Session ID | Wall seconds | Correct answer yes/no |
|---|---|---:|---|
| Warm | NOT DISPATCHED | — | N/A |
| Cold | NOT DISPATCHED | — | N/A |

This is **not** a crude n=1 datapoint: the objective explicitly conditioned both timing probes on a successful clone, and clone failed. Dispatching them would have violated that prerequisite and would not measure the intended warm-versus-cold path.

### Safety

- Read-only routine readback confirmed `tw-spike-file-probe` (`trig_01LvNvWKUnogCkX6YptKpc7D`) remains `enabled=false`; it was not run or mutated.
- Both local test checkouts were clean at the end (`main...origin/main`).
- Neither test repository was deleted.

### ALPHA GREENLIGHT SUMMARY

- **NO end-to-end greenlight:** the everything-rides-GitHub architecture is not confirmed because private sibling clone-in failed after authorization and push-out was never reached; independent GitHub verification found no new file.
- **Confirmed components:** cloud dispatch, CLI retrieval, remote identity, and the repository `SessionStart` hook all work in a new cloud session.
- **Operating constraints:** arbitrary outbound HTTPS remains proxy-blocked as expected, and the routine remains safely disabled.

## Phase 8 — Branch-sync variant

Run date: 2026-07-12 (America/Los_Angeles)

### Cloudflare preflight and Worker deployment

**Verdict: PASS; Worker mode was used (no local fallback).**

- `npx -y wrangler@latest whoami` succeeded with Wrangler `4.110.0` for the Cloudflare account `Blitz Development Sandbox`; the token had Worker write/deploy permissions.
- The dependency-free module Worker lives at `/tmp/tw-sync-spike/src/worker.js` with `/tmp/tw-sync-spike/wrangler.jsonc`, compatibility date `2026-07-12`, and cron `*/5 * * * *`.
- Deployment succeeded as Worker `tw-sync-spike` at `https://tw-sync-spike.blitzapp.workers.dev`; initial version ID was `1c733a48-6b24-40da-8495-cf293e27d5a5`.
- Encrypted Worker secrets `GITHUB_TOKEN` and `SYNC_KEY` were set and confirmed by `wrangler secret list`. The generated sync key was recorded only in `/tmp/spike-log.txt` as requested; its temporary plaintext file was removed after verification.
- The Worker uses raw `fetch` calls to `api.github.com`. Fan-out resolves the central default-branch commit/tree, compares per-path blob SHAs, creates target-repository blobs/tree/commit, and creates or force-updates `refs/heads/tw/machine`. It preserves target-only paths while overlaying central content so a session-created learning survives until fan-in. Fan-in serially copies target-only direct `learnings/*` files into central through the contents API.

### Fan-out evidence

**Verdict: PASS.**

- First authenticated `GET /sync` returned `{"fanOutCommitted":1,"fanInCopied":0,"skipped":0}`.
- Independent GitHub readback found target branch `tw/machine` at `01f0b0bd3d03fa85345e09281584a7a469c18ad2` with commit message `sync machine content`.
- `MARKER.md` on that branch decoded exactly to `SPIKE-MARKER-7749`.
- A later sync returned `{"fanOutCommitted":0,"fanInCopied":0,"skipped":1}`, demonstrating the cross-repository blob-SHA skip path.

### SessionStart hook

The target `main` hook was iterated in response to two cloud-only conditions and ended at commit `af085f727decd047a746da5e275caca170b2ac9c` (`Use session token for branch sync`). Its final behavior:

- adds credential-free remote URL `https://github.com/example-owner/tw-spike-target.git` as `origin` when the managed checkout has no remotes;
- installs a repository-local credential helper whose stored command refers literally to runtime `$GITHUB_TOKEN` and contains no token value;
- fetches `tw/machine`, extracts it with `git archive` into `/tmp/m`, and writes `REMOTE=<value> machine=yes|no` to `/tmp/hook-fired.txt`.

Local tests, including a clone with all remotes removed, returned `REMOTE=local-token machine=yes` and read `SPIKE-MARKER-7749`. Both local test repositories were clean and tracked `origin/main` after the commits were pushed.

### Cloud branch probe

Three fresh probe sessions were needed to isolate the managed-checkout behavior:

1. `session_01AAwvtJxS3n1Uv2hsfg5w1Q` proved the cloud checkout initially has no `origin`: the hook wrote `REMOTE=true machine=no`, and fetch failed with `fatal: 'origin' does not appear to be a git repository`.
2. After the hook added `origin`, `session_01NDxNH1s8J1EyGrxt8AiwLe` reached GitHub but had no credential helper: `fatal: could not read Username for 'https://github.com': terminal prompts disabled`.
3. After the hook installed the environment-referencing helper, `session_016YJgYPz9qjEQxrPt12Q6YK` still wrote `REMOTE=true machine=no`. The session reported a 14-character `GITHUB_TOKEN`, and GitHub rejected it.

| Probe | Verdict | Evidence |
|---|---|---|
| Branch read in cloud | **FAIL** | `/tmp/m/MARKER.md` was absent; authenticated fetch failed before `git show`, so the cloud session never obtained the marker. |
| Branch PUSH in cloud | **FAIL** | Safe direct diagnostic session `session_01NNYwaiiqoah161mzdBgvBU` ran `git push origin HEAD:refs/heads/tw/machine` without force and exited 128. Independent readback confirmed the branch SHA stayed `01f0b0bd3d03fa85345e09281584a7a469c18ad2` and its only learning remained `.gitkeep`. |

Exact push result, verbatim:

```text
remote: Invalid username or token. Password authentication is not supported for Git operations.
fatal: Authentication failed for 'https://github.com/example-owner/tw-spike-target.git/'
```

An additional non-secret credential-name/length/status diagnostic session (`session_01HF6HKZMwCCw83Vr7LzBaqD`) was stopped by Claude's cyber safeguard before it ran; that control was not bypassed. It made no Git or repository change.

### Fan-in and round trip

**Verdict: FAIL / not demonstrated because cloud push failed.**

- No `learnings/spike-branch-*.md` was created on target `tw/machine`; the branch never moved from its fan-out commit.
- The second Worker sync returned `fanInCopied:0`, as expected for an unchanged target tree.
- Independent central readback found only `learnings/.gitkeep`, and central `main` remained `3140b51bf7ac419b859e4599d079633c3d431e1a` (`Initialize machine context probe`).
- Therefore Worker fan-out is live-verified, but the cloud-write → Worker-fan-in → central round trip is not verified.

### Warm vs. cold (crude n=1)

Times run from dispatch returning the session ID until the first terminal report returned by `--teleport`. The warm report was a terminal authentication failure rather than a completed marker-bearing answer.

| Case | Session ID | Seconds | Correct (yes/no) |
|---|---|---:|---|
| Warm | `session_01WzysUaiGy3A9xRrPkrhLnc` | 43 | no |
| Cold | `session_01JHUsfA3Jy4UYDTQJ4up7EA` | 39 | yes |

- Warm exact failure: `remote: Invalid username or token. Password authentication is not supported for Git operations.` followed by `fatal: Authentication failed for 'https://github.com/example-owner/tw-spike-target.git/'`; no marker was returned.
- Cold did not fetch, search, or read. It correctly restated `SPIKE-MARKER-7749` as a string supplied directly in the prompt and claimed no external knowledge of it.

### Safety and created resources

- Read-only routine readback confirmed `tw-spike-file-probe` (`trig_01LvNvWKUnogCkX6YptKpc7D`) remains `enabled=false`; it was neither run nor mutated.
- Created Cloudflare Worker: `tw-sync-spike`, URL `https://tw-sync-spike.blitzapp.workers.dev`, cron `*/5 * * * *`, secrets `GITHUB_TOKEN` and `SYNC_KEY`.
- Created target branch: `tw/machine`, final SHA `01f0b0bd3d03fa85345e09281584a7a469c18ad2`.
- Target `main` hook commits created during live hardening: `7810dc6`, `9628e50`, and final `af085f7`. No credential value is present in the repository; the final helper contains only a literal environment-variable reference.
- Both test repository checkouts ended clean. Neither repository nor the Worker was deleted.

### BRANCH-SYNC GREENLIGHT?

- **NO — the credential-free architecture is not verified end to end.** The deployed Worker and fan-out branch are green, but a managed cloud session could neither read nor push its own repository branch with the credentials actually exposed in these runs.
- **Verified:** authenticated Cloudflare deployment, scheduled Worker configuration, Worker secrets, central-to-target fan-out, marker integrity, idempotent blob-SHA skip, remote SessionStart execution, and local no-remote/token-helper hook behavior.
- **Failed:** cloud branch read and direct branch push both ended in the same exact GitHub authentication rejection; no learning reached target, so fan-in and the complete round trip remain unproved.
- **Required unblock:** restore a valid per-session token/credential bridge for the session's own repository, then rerun the final Phase 4 probe and Phase 5 sync without embedding any credential in Git history or remote URLs.

## Phase 9 — Warm vs cold (monorepo design)

Run date: 2026-07-12 (America/Los_Angeles)

The warm baseline was committed to target `main` as `a1a41577778ec5a3717e9631285b57f89c29ad0f`. GitHub API readback confirmed both `CONTEXT/COMPANY.md` and `CONTEXT/conventions.md` on `main`; the cold repository's `main` tree contained zero `CONTEXT/` paths. The SessionStart command now only records `REMOTE` and whether `CONTEXT/COMPANY.md` exists; it performs no Git or context-injection work.

Times run from PTY dispatch returning the session ID until `--teleport` first returned a completed report. Retrieval was attempted at 20-second intervals with a 10-minute cap. Blank/non-report retrievals were treated as incomplete polls.

| Case | Session ID | Seconds to completed report | Correct answers (0-3) | Notes |
|---|---|---:|---:|---|
| Warm 1 | `session_01WafZuz7RCwV7uDt64mBha4` | 168 | 3 | Returned `PELICAN-3391`, `./scripts/ship.sh --canary`, and `https://stage.acme-7749.dev`; cited `CONTEXT/COMPANY.md`. Multiple retrieval transport attempts returned no report before direct PTY retrieval succeeded, making this a timing outlier. |
| Warm 2 | `session_01CYUCGSc6fpJY638mYFHztL` | 34 | 3 | Returned all three exact values and cited `CONTEXT/COMPANY.md`; the first 20-second poll returned the completed report. |
| Cold 1 | `session_017GnW4bDKpYEfQEFjWUV6ZB` | 34 | 0 | Reported all three values absent after inspecting the repository; did not guess, hallucinate, or ask. The first 20-second poll returned the completed report. |
| Cold 2 | `session_01FGdFkvDXiSXAo1T6Wznn6E` | 70 | 0 | Reported all three values absent and cited `MARKER.md`; did not hallucinate or ask. The first retrieval was blank; the next 20-second poll returned the completed refusal. |

- **Warm delivery:** yes. Both warm sessions produced 3/3 exact company answers from the ordinary repository checkout. No delivery configuration beyond files on the session repository's `main` branch was needed; the diagnostic hook did not fetch or inject context.
- **Timing overhead:** raw means were 101 seconds warm versus 52 seconds cold, but that difference is caused by retrieval transport outliers. The clean first-poll warm and cold runs were both 34 seconds, so this n=2 sample shows no measurable warm-context overhead.
- **Cold behavior:** both cold sessions searched their sparse repository and explicitly refused to invent the missing company facts. Neither hallucinated values nor asked the user for them.

Final readback found both local checkouts clean and equal to `origin/main`, and the read-only routine check confirmed `tw-spike-file-probe` (`trig_01LvNvWKUnogCkX6YptKpc7D`) remains `enabled=false`.

**Files-in-repo context delivery proven? YES.**

## Phase 10 — Registry egress probe

Run date: 2026-07-13 (America/Los_Angeles)

Cloud session: `session_01N5eYaPCTvMBn3g1Wndy8ir`

| Probe | Verdict | Evidence |
|---|---|---|
| npm ping | **PASS** | `npm notice PONG 188ms` |
| npm install | **PASS** | `left-pad@1.3.0` installed: `added 1 package in 454ms`, `EXIT:0` |
| pip | **PASS** | `pip3 install --dry-run requests` resolved successfully; the final lines reported `urllib3` and `certifi` already satisfied. |
| registry HTTP | **PASS** | `https://registry.npmjs.org` returned `HTTP/2 200`. |
| pypi HTTP | **PASS** | `https://pypi.org/simple/` returned `HTTP/2 200`. |

- Anthropic's Trusted network mode permits npm and PyPI registry egress in this cloud VM: both direct HTTP probes passed, npm ping passed, and a real npm package install completed successfully.
- An explicit dependency-install step can make JavaScript/TypeScript monorepos runnable for typecheck/build when their dependencies are available from allowed registries; this probe does not establish access to arbitrary hosts, private registries, or required external services.

## Phase 11 — Environments API verification

Run date: 2026-07-13 (America/Los_Angeles)

### Scope and credential preflight

`ANTHROPIC_API_KEY` was absent from the process environment. No key was found in the standard Anthropic/Claude API-key files, shell profiles, top-level Claude settings, or API-key-named Keychain services checked without printing values. The machine is authenticated to Claude Code with a `claude.ai` Max subscription, not an API key. The `ant` API CLI is not installed.

Consequently, Q1 and Q2 are explicitly **BLOCKED (no key)** for live HTTP verification. No request was sent to `api.anthropic.com`, no API Agent/Environment/Session was created, and there is no live response header or usage record to report. Primary evidence below comes from Anthropic's current documentation, API reference, pricing page, and generated official SDK types.

### Q1 — `POST /v1/environments` and schema

**Verdict: BLOCKED (no key; existence and documented schema CONFIRMED, live request not run).**

Primary sources: [Cloud environment setup](https://platform.claude.com/docs/en/managed-agents/environments), [Environments API reference](https://platform.claude.com/docs/en/api/beta/environments), and the official SDK's generated [`EnvironmentCreateParams`](https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/beta/environment_create_params.py), [`BetaCloudConfigParams`](https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/beta/beta_cloud_config_params.py), and [`BetaEnvironment`](https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/beta/beta_environment.py).

- `GET /v1/environments` and `POST /v1/environments` are documented beta endpoints. Every request needs `x-api-key`, `anthropic-version: 2023-06-01`, and `anthropic-beta: managed-agents-2026-04-01`.
- Create request fields are `name` (required), `config`, `description`, `metadata`, and `scope` (the latter only materially applies to self-hosted environments). A cloud config is `{"type":"cloud","networking":...,"packages":...}`.
- Networking is exactly the reported tagged union: `{"type":"unrestricted"}` or `{"type":"limited","allowed_hosts":[...],"allow_package_managers":bool,"allow_mcp_servers":bool}`. The two booleans default to `false`; limited-mode hosts accept ordinary domains and wildcard patterns. Unrestricted is the documented default.
- `packages` is a map of optional arrays named `apt`, `cargo`, `gem`, `go`, `npm`, and `pip`; version strings use each package manager's native syntax. This is package pre-install/caching, not an arbitrary setup script.
- The documented response is an Environment object with `id` (`env_...`), `type: "environment"`, `name`, `description`, `metadata`, `config`, `created_at`, `updated_at`, `archived_at`, and `scope`. A returned cloud config contains normalized `networking` and all package-manager lists.

Documented create shape (not sent):

```http
POST /v1/environments
x-api-key: [REDACTED]
anthropic-version: 2023-06-01
anthropic-beta: managed-agents-2026-04-01
content-type: application/json

{
  "name": "cc-spike-env",
  "config": {
    "type": "cloud",
    "networking": {
      "type": "limited",
      "allowed_hosts": ["github.com"],
      "allow_package_managers": true,
      "allow_mcp_servers": false
    },
    "packages": {"apt": ["gh"], "pip": ["requests==2.32.4"]}
  }
}
```

Critical qualification: the Managed Agents Environment schema contains no `setup_script` field. Anthropic separately documents setup scripts on **Claude Code on the web subscription environments**, which are managed at `claude.ai/code`.

### Q2 — `POST /v1/sessions`, requirements, and billing

**Verdict: BLOCKED (no key; existence, shape, and API billing CONFIRMED, live request not run).**

Primary sources: [Start a session](https://platform.claude.com/docs/en/managed-agents/sessions), [Create Session API reference](https://platform.claude.com/docs/en/api/beta/sessions/create), official SDK [`SessionCreateParams`](https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/beta/session_create_params.py), and [Claude Managed Agents pricing](https://platform.claude.com/docs/en/about-claude/pricing#claude-managed-agents-pricing).

- `POST /v1/sessions` exists, but `environment_id` alone is insufficient. Required request fields are `agent` (an existing Agent ID, pinned Agent reference, or Agent-with-overrides object) and `environment_id`. Optional fields are `title`, `metadata`, `resources`, and `vault_ids`.
- A repository and prompt are **not** create-time requirements. A GitHub repository is an optional `resources[]` item with required `type: "github_repository"`, `url`, and `authorization_token`, plus optional `checkout` and `mount_path`. The prompt is sent afterward as a `user.message` event to `POST /v1/sessions/{session_id}/events`.
- The response is a Session object containing `id`, resolved `agent`, `environment_id`, `status`, `resources`, `metadata`, `title`, `vault_ids`, timestamps, cumulative `usage`, and `stats`. `usage` exposes `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and cache-creation detail; `stats` exposes `active_seconds` and `duration_seconds`.

Documented lifecycle shapes (not sent):

```json
POST /v1/sessions
{
  "agent": "agent_...",
  "environment_id": "env_...",
  "title": "cc spike",
  "resources": [{
    "type": "github_repository",
    "url": "https://github.com/example-owner/tw-spike-target",
    "authorization_token": "[REDACTED]",
    "mount_path": "/workspace/tw-spike-target"
  }]
}

POST /v1/sessions/session_.../events
{"events":[{"type":"user.message","content":[{"type":"text","text":"echo hello, state your working directory, then stop"}]}]}
```

**BILLING — ARCHITECTURE-BREAKING: Managed Agents sessions are API-billed, not Claude subscription usage.** Anthropic bills every session's model input/output/cache tokens at API model rates **plus $0.08 per running session-hour**, metered to the millisecond while status is `running`. Web search has its normal API surcharge. The response's cumulative `usage` and `stats.active_seconds` are the direct billing evidence fields. Organization spend limits also apply. This breaks the ride-the-subscription economics; the API is not a subscription-backed remote-spawn path.

### Q3 — Can subscription dispatch select an API-created environment?

**Verdict: PARTIAL — custom subscription environments are selectable; API-created Environment interoperability is not documented or exposed.**

Primary sources: [Claude Code on the web: configure your environment](https://code.claude.com/docs/en/claude-code-on-the-web#configure-your-environment) and [web quickstart](https://code.claude.com/docs/en/web-quickstart).

- Installed Claude Code is `2.1.170`; npm reports `2.1.207`, whose help was inspected non-destructively with `npx`. In both, `--remote` is a recognized hidden parser option even though it is omitted from `--help`. `--environment` is rejected as unknown. Legacy `--cloud` remains recognized by 2.1.170.
- An interactive `/remote-env` test succeeded and opened `Select remote environment`, showing this account's existing `Default` subscription environment. Anthropic documents `/remote-env` as setting the default for `--remote`; it only selects, while add/edit/archive operations happen in the `claude.ai/code` UI.
- The web start form can select a custom subscription environment, and the documented prefill URL accepts `environment=<name-or-ID>`.
- No Anthropic source says that an `env_...` Managed Agents API Environment appears in the Claude Code web selector. Managed Agents docs only attach it through API `environment_id`; Claude Code web docs only create/manage environments in the subscription UI. Therefore an API-created environment must not be assumed usable by subscription dispatch.

### Q4 — Git push and PR reality

**Verdict: PARTIAL — current docs CONFIRM push/PR for properly authenticated Claude Code web sessions; this machine's new live probe was inconclusive, and API-session push/PR is not equivalently guaranteed.**

Primary source: [Claude Code on the web: GitHub authentication and proxy](https://code.claude.com/docs/en/claude-code-on-the-web#github-authentication-options).

- Current docs say Claude Code web sessions need GitHub access to clone and push. Authentication comes from the Claude GitHub App or `/web-setup`, which syncs the local `gh` token. Inside a web sandbox, Git uses a custom scoped credential translated by Anthropic's dedicated GitHub proxy; the proxy supports clone/fetch, restricts push to the current working branch, and enables PR operations. The web workflow can create a PR from the resulting branch.
- `claude --remote` is documented to clone the current checkout's GitHub remote/current branch. If GitHub access is unavailable it falls back to a local bundle; bundled sessions cannot push unless GitHub authentication is also configured.
- This reconciles Phase 8: those legacy `claude --cloud` checkouts had no remote and a 14-character dummy token, behavior consistent with a bundled/unconfigured session, not the now-documented properly authenticated GitHub-proxy path. Phase 8 remains valid evidence for those exact sessions, but not a universal property of current configured web sessions.
- The Managed Agents API is different: a private repository resource requires the caller to supply `authorization_token`. Its public session schema does not promise Claude Code web's account-level GitHub App/proxy/PR workflow, so parity must not be inferred.

One bounded subscription probe was dispatched from `tw-spike-target` with `claude --remote` as session `session_01H3rMA17qiqL8ny8QcEfCnX`. It requested `pwd`, `git remote -v`, the safe push to `refs/heads/cc-spike-push-test`, and a second private-repo clone. Immediate teleport returned exactly: `I don't have any diagnostic command outputs to report.` `/tasks` then showed no running task. Independent `gh` readback returned HTTP 404 for `refs/heads/cc-spike-push-test`. This proves only that no branch appeared; without a transcript or command output it does **not** distinguish provisioning/non-execution from Git authentication failure and is therefore inconclusive.

### Q5 — Setup-script multi-repo clone authentication

**Verdict: PARTIAL — docs imply Git proxy availability in the subscription sandbox and offer native multi-repo selection, but the exact setup-script clone was not live-verified.**

Primary sources: [Claude Code web setup scripts and GitHub proxy](https://code.claude.com/docs/en/claude-code-on-the-web#setup-scripts) and [web quickstart: start a task](https://code.claude.com/docs/en/web-quickstart#start-a-task).

- Subscription environment setup scripts run as root on Ubuntu 24.04 before Claude Code launches and are filesystem-cached. The quickstart describes repository cloning followed by the configured setup script.
- Static API tokens are not automatically injected. Git credentials stay out of the sandbox; Anthropic says **all GitHub operations** in it go through the separate GitHub proxy with a custom scoped credential derived from the configured GitHub App or `/web-setup` auth. The docs do not explicitly state whether that credential authorizes an arbitrary unselected second private repo during the setup-script phase, so the exact `git clone ... /opt/m` claim remains unproven.
- The web UI now supports selecting multiple repositories for one session. For the subscription path this is the documented solution to multi-repo work and avoids relying on an undocumented setup-script clone scope.
- `gh` is a separate case: it is not preinstalled, and Anthropic tells users to supply their own `GH_TOKEN` environment variable for `gh` commands not covered by built-in tools.
- Managed Agents API environments have no setup script. Their supported private-repo path is one or more session `github_repository` resources, each carrying an explicit caller-supplied `authorization_token` and optional mount path.

The exact setup script was not run: creating/editing a subscription environment is web-UI-only, and no browser surface was available in this runtime. The single cloud probe above also yielded no command transcript, so there is no new clone error to quote. The last exact live clone error remains Phase 7's legacy-session result: `fatal: could not read Username for 'https://github.com': terminal prompts disabled` (followed by the token retry's authentication failure); current documentation shows that correctly configured web auth is intended to change that result.

### WHAT THIS MEANS FOR THE ARCHITECTURE

- The monorepo stays the reliable context vehicle for subscription CLI dispatch: `--remote` is single-repository, repo-contained context is already proven, and API-created environments do not bridge into the subscription selector. Web-only native multi-repo selection is an optional alternative, not a portable replacement.
- Managed Agents Environment CRUD handles API sandbox networking and package pre-installs, but it does not replace the builder's subscription-machine/setup-script concerns and exposes no arbitrary setup script.
- Remote spawn through `/v1/sessions` is technically viable but economically wrong here: API tokens plus runtime are billed outside the Max subscription. Environment CRUD may still be useful for a separate API product, not for ride-the-subscription dispatch.
- PR-back can simplify on properly configured Claude Code web sessions because the documented GitHub proxy supports branch pushes and PR operations; retain teleport/diff fallback until a clean live push/PR probe succeeds on this account.
- Private multi-repo auth is no longer inherently impossible on the web path (native multi-repo selection exists), but API sessions require explicit repository tokens and setup-script cloning of an unselected private repo remains unverified.
- Treat Claude Code web environments and Managed Agents API environments as separate resource systems unless Anthropic documents an interoperability bridge.

### Cleanup

- API Environment `cc-spike-env`: not created, so nothing existed to archive or delete.
- API Agent/Session: not created; API token usage and API runtime charge are exactly zero for this phase.
- Subscription test branch `cc-spike-push-test`: independent GitHub readback returned 404, so it was never created and required no deletion.
- Subscription probe session: created as `session_01H3rMA17qiqL8ny8QcEfCnX`; it produced no retrievable diagnostic transcript. No repository file or local checkout was changed by the probe.
