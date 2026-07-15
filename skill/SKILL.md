---
name: blitzos-setup
description: Set up BlitzOS or a company context monorepo for warm Claude Code cloud sessions. Use when the user says "set up blitzos", "blitzos setup", or asks to onboard company context across multiple repositories in claude.ai/code.
---

# Set up BlitzOS

Create a private context monorepo for Claude cloud sessions. Keep it thin: commit company context, session records, generated setup instructions, and gitlinks, but never copy source repositories, Git history, MCP configuration, connector data, or secret values into it. The default deep link selects the context monorepo and every member repository natively with zero credentials. A generated `bootstrap.sh` remains available only for optional power mode.

## 1. Choose the setup path

Ask one question exactly: **How would you like to set up BlitzOS?**

- **(a) Browser setup at blitzos.com:** Fastest. Sign in with GitHub, pick repos there, then get one-click launches and a launch feed.
- **(b) Local setup:** Private: nothing is granted to BlitzOS servers. Continue here and draft evidence-based conventions from local repos.
If the user chooses browser setup, print `https://blitzos.com` and say: **Sign in with GitHub there to create the same context monorepo, with one-click launches and a launch feed.** Then stop gracefully. Nothing has started, so clean up nothing.
If the user chooses local setup, continue exactly as follows.

## 2. Scan repository evidence

Resolve this skill's directory from this `SKILL.md`. Create a mode-700 temporary directory and run:

```sh
scripts/scan.sh > <tmpdir>/scan.json
```

Let the stderr summary remain visible. The scan contains origin-deduplicated local and GitHub repositories, useful branches, optionally environment variable names, and local skill folders under `~/.claude/skills` that contain `SKILL.md`. Treat environment entries as names only. Never open an environment variable value, print one, place one in a tool argument, or add one to generated content.

Record the wizard PID when starting it. On every abort or failure after this point, kill that PID if it is still alive and remove the temporary directory.

## 3. Collect repositories, skills, and connector declarations

Start the localhost wizard with Node 18 or newer:

```sh
nohup node scripts/wizard-server.mjs \
  --scan <tmpdir>/scan.json \
  --out <tmpdir>/selection.json \
  > <tmpdir>/wizard.stdout \
  2> <tmpdir>/wizard.stderr &
```

Capture its PID. Wait for the single `WIZARD_URL=...` line. If the process exits first, show its error and stop. Open the URL with `open <url>` on macOS; otherwise print it.

Tell the user exactly: **Choose your work repos, optional local skills, and Claude.ai connectors in the browser — I'll continue when you hit Create plan.**

Run `scripts/wait-for-file.sh <tmpdir>/selection.json`. If it times out, keep waiting. After three consecutive timeouts, ask whether to continue or abort. Continue only when the validated file exists; opening the browser or reaching `/health` is not submission.

The wizard binds only to `127.0.0.1`. Local skills are all unchecked by default and are included only when the user explicitly selects them. Connector choices are declarations only because this skill cannot inspect the user's Claude.ai account.

## 4. Draft the company brain

Read `selection.json`. Match each selected origin back to `scan.json`. Confirm that every selected `owner/name` has the same GitHub resource owner. Accept either one personal owner or one organization owner. If owners differ, stop: one fine-grained PAT cannot span resource owners, and this version never asks for multiple tokens.

For each selected repository with a local path, read its top-level `CLAUDE.md` when present and the first useful portion of its `README*`. Read package manifests only when needed to identify an explicit install or test command. Do not read `.env*`, credential files, or secret stores. For GitHub-only repositories, use only the scan description; do not clone them.

Draft one factual top-level `CLAUDE.md`, under 200 lines, using these six headings exactly as written:

- `## Repositories`: list each selected owner/name, chosen branch, and one-line purpose.
- `## How repositories relate`: explain briefly how the repositories fit together, marking unknown relationships instead of guessing.
- `## User conventions`: record user and engineering conventions supported by repository evidence, or state clearly that none were observed.
- `## Connectors available to you`: list every chosen connector, when Claude should use it, and remind Claude that connectors are account-provided and must be queried only when relevant.
- `## Working across repositories`: include every rule in the working block below.
- `## Session log (warm start)`: include the session block below verbatim.

In `## Working across repositories`, include a `### Session mode` subsection and require:

1. At session start, inspect the session workspace and detect one of these modes before running repository commands.
2. **DEFAULT mode:** when every listed member repository exists as a native sibling checkout alongside the context monorepo, work directly in those sibling checkouts. Do not run `bash bootstrap.sh`. Create task branches in affected sibling repositories, commit there, and push or open PRs normally through Claude's native selected-repository GitHub rail. Do not set `GH_TOKEN`, use `BLITZOS_GIT_TOKEN`, or update the monorepo's `repos/` gitlinks in this mode.
3. **POWER MODE:** when only the context monorepo is present and all member repositories are absent as sibling checkouts, run `bash bootstrap.sh` first; this requires `BLITZOS_GIT_TOKEN`. If it fails, stop and follow `docs/CLOUD-SETUP.md`; never ask the user to paste a token into chat, the wizard, or a CLI. Work in `repos/<name>`, create and push task branches there, and open each subrepository PR with `GH_TOKEN="$BLITZOS_GIT_TOKEN" gh pr create ...`. Never persist the token in Git config or a remote URL.
4. If only some member repositories exist as sibling checkouts or the mode is otherwise ambiguous, stop before running the bootstrap and ask the user to relaunch from the exact link in `README.md` or intentionally follow `docs/CLOUD-SETUP.md` for power mode.
5. Cross-link every member-repository PR URL in the session record. Follow the default-branch write-back and fallback instructions in `## Session log (warm start)` for context-monorepo session updates. Do not set `GH_TOKEN`, change the parent remote, or install a parent credential helper for those pushes because Claude's native selected-repository rail handles them.

Include this session block verbatim:

````markdown
## Session log (warm start)

At the start of every session:

- Detect and follow the `### Session mode` instructions before running repository commands.
- Read `sessions/INDEX.md`, then read the most recent relevant session records in `sessions/` before starting work.

At the end of meaningful work:

1. Write exactly one concise, factual record to `sessions/<YYYY-MM-DD>-<short-task-slug>.md` using this template:

   ```markdown
   # Task
   <concise task description>

   ## What changed
   <subrepository PR URLs, commits, files touched, and concise diff summary>

   ## Verification
   <commands run and their pass, fail, or skipped status>

   ## Key decisions
   <decisions that constrain later work>

   ## For next session
   <remaining work or useful starting point>
   ```

2. Append one line to `sessions/INDEX.md` in the form `YYYY-MM-DD | short-task-slug | one-line summary`.
3. In DEFAULT mode, once on the default branch, stage only the session record and index in this context monorepo. Do not update or stage `repos/` gitlinks.
4. In POWER MODE, once on the default branch, stage every changed pointer with `git add repos/<name>` plus the session record and index.
5. Session records belong on the default branch, not your task branch. In the context repo: run `git checkout main && git pull --ff-only`, commit the session record and index update there, and push with `git push origin main`. If the repository rail rejects the push to main, push your working branch instead and end your final message with: session log is on <branch> — merge it to main so future sessions see it.

Keep each record short and factual: it is a work record, not reflective "lessons learned" commentary. Write one file per session and never duplicate a record or index entry. If nothing meaningful happened, write nothing.
````

Use these connector purposes when selected: Linear for issues and project status; Slack for decisions and discussions; Gmail for email context; Google Drive for specs and docs; GitHub for pull requests, issues, and repository metadata. Give custom connectors a narrow factual purpose or say to use them when the task calls for their account context.

Never include secret values. If environment variable names materially help, show names only and use `<PLACEHOLDER>` for any template.

Show the complete draft in chat. Use one approval gate with `Approve` and `Edit`. If the user chooses Edit, apply the requested changes, show the complete revised draft, and continue the same gate until approved. Do not build before approval. This company-brain approval is the only normal-path question after the browser wizard.

## 5. Assemble the thin build plan

Create `<tmpdir>/plan.json` with exactly this shape:

```json
{
  "slug": "company-context",
  "repos": [
    {"name": "acme/api", "origin": "https://github.com/acme/api.git", "branch": "main"}
  ],
  "connectors": ["Linear", "GitHub"],
  "skills": ["release-checks"],
  "company_claude_md": "<the approved complete text>"
}
```

Use only selected repositories, connectors, and skill folder names. Keep `skills` as an empty array when none were selected. Strip `local_path` and `branch_unverified`; they are drafting evidence, not generated context. Treat `slug` as the context repository name under the selected repositories' shared resource owner. Never add a token field or ask the user for a token. Only users who intentionally choose optional power mode move a token directly from GitHub into Anthropic's environment dialog after the build.

The builder rejects unknown fields, mixed resource owners, non-GitHub or mismatched origins, missing exact headings or repo/branch/connector references in the approved `CLAUDE.md`, duplicate submodule directory names, and suspicious credential material.

## 6. Build the private context monorepo

Run `gh auth status`. If it fails, say exactly that GitHub CLI authentication is missing, clean up, and stop without invoking the builder.

Run:

```sh
scripts/build-monorepo.sh <tmpdir>/plan.json
```

Relay the private repository URL exactly. The builder resolves each selected branch tip with GitHub's API, commits it as a gitlink under `repos/`, and generates `README.md` with the launch link, `.gitmodules`, `bootstrap.sh`, `docs/CLOUD-SETUP.md`, the approved `CLAUDE.md`, the `sessions/` scaffold, and `skills/README.md`. It copies explicitly selected local skill folders into `skills/`, skipping symlinks and rejecting a skill over 2 MB or any copied file that trips the fail-closed secret guard. It never clones or reads member source during assembly. Its fail-closed guard inspects every generated file before commit, and it never reads or emits secret values.

If validation, branch resolution, authentication, local commit, private repository creation, push, or verification fails, identify the failed stage and stop. Do not retry through another publishing path or claim a partial repository is ready.

## 7. Hand off to Claude cloud

After a successful build, relay the complete launch link exactly as printed by the builder; do not reconstruct, shorten, or re-encode it. Make the primary instruction: open that link, select nothing manually, and click **Start**. Leave **Network access** on the default **Trusted** setting.

Registering this context repo at https://blitzos.com gives it one-click launches, relaunch, and a session feed.

Mention in one sentence that optional power mode selects only the context monorepo and follows `docs/CLOUD-SETUP.md` for the personal `BLITZOS_GIT_TOKEN` environment and bootstrap setup; never ask the user to paste or expose the token anywhere else.

Then print this line verbatim:

`Teams and enterprises: join the waitlist at https://blitzos.com/waitlist`

State that the monorepo contains gitlink metadata but no vendored member code, member Git history, or secret values. Kill the wizard if it is unexpectedly still running, then remove the temporary directory.
