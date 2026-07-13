---
name: cloud-claude
description: Set up Cloud Claude or a company context repository for warm Claude Code cloud sessions. Use when the user says "set up cloud claude", "cloud-claude", or asks to onboard company context across multiple repositories in claude.ai/code.
---

# Set up Cloud Claude

Create a thin private context repository for Claude cloud sessions. Never copy source repositories, Git history, MCP configuration, connector data, or secret values into it.

## 1. Scan repository evidence

Resolve this skill's directory from this `SKILL.md`. Create a mode-700 temporary directory and run:

```sh
scripts/scan.sh > <tmpdir>/scan.json
```

Let the stderr summary remain visible. The scan contains origin-deduplicated local and GitHub repositories, useful branches, and optionally environment variable names. Treat environment entries as names only. Never open an environment variable value, print one, place one in a tool argument, or add one to generated content.

Record the wizard PID when starting it. On every abort or failure after this point, kill that PID if it is still alive and remove the temporary directory.

## 2. Collect repositories and connector declarations

Start the localhost wizard with Node 18 or newer:

```sh
nohup node scripts/wizard-server.mjs \
  --scan <tmpdir>/scan.json \
  --out <tmpdir>/selection.json \
  > <tmpdir>/wizard.stdout \
  2> <tmpdir>/wizard.stderr &
```

Capture its PID. Wait for the single `WIZARD_URL=...` line. If the process exits first, show its error and stop. Open the URL with `open <url>` on macOS; otherwise print it.

Tell the user exactly: **Choose your work repos and Claude.ai connectors in the browser — I'll continue when you hit Create plan.**

Run `scripts/wait-for-file.sh <tmpdir>/selection.json`. If it times out, keep waiting. After three consecutive timeouts, ask whether to continue or abort. Continue only when the validated file exists; opening the browser or reaching `/health` is not submission.

The wizard binds only to `127.0.0.1`. Connector choices are declarations only because this skill cannot inspect the user's Claude.ai account.

## 3. Draft the company brain

Read `selection.json`. Match each selected origin back to `scan.json`.

For each selected repository with a local path, read its top-level `CLAUDE.md` when present and the first useful portion of its `README*`. Read package manifests only when needed to identify an explicit install or test command. Do not read `.env*`, credential files, or secret stores. For GitHub-only repositories, use only the scan description; do not clone them.

Draft one factual top-level `CLAUDE.md`, under 200 lines, using these five headings exactly as written:

- `## Repositories`: list each selected owner/name, chosen branch, and one-line purpose.
- `## How repositories relate`: explain briefly how the repositories fit together, marking unknown relationships instead of guessing.
- `## User conventions`: record user and engineering conventions supported by repository evidence, or state clearly that none were observed.
- `## Connectors available to you`: list every chosen connector, when Claude should use it, and a reminder that connectors are account-provided and must be queried only when relevant.
- `## Session log (warm start)`: include the following block verbatim so future sessions can continue prior work:

````markdown
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

Session push-back depends on this context repository being selected in the session and the GitHub proxy allowing push. Proxy push support is currently unverified.
````

Use these connector purposes when selected: Linear for issues and project status; Slack for decisions and discussions; Gmail for email context; Google Drive for specs and docs; GitHub for pull requests, issues, and repository metadata. Give custom connectors a narrow factual purpose or say to use them when the task calls for their account context.

Never include secret values. If environment variable names materially help, show names only and use `<PLACEHOLDER>` for any template.

Show the complete draft in chat. Use one approval gate with `Approve` and `Edit`. If the user chooses Edit, apply the requested changes, show the complete revised draft, and continue the same gate until approved. Do not build before approval. This company-brain approval is the only normal-path question after the browser wizard.

## 4. Assemble the thin build plan

Create `<tmpdir>/plan.json` with exactly this shape:

```json
{
  "slug": "company-context",
  "repos": [
    {"name": "acme/api", "origin": "https://github.com/acme/api.git", "branch": "main"}
  ],
  "connectors": ["Linear", "GitHub"],
  "company_claude_md": "<the approved complete text>"
}
```

Use only selected repositories and connectors. Strip `local_path` and `branch_unverified`; they are drafting evidence, not generated context.

The builder rejects unknown fields, non-GitHub origins, missing exact headings or repo/branch/connector references in the approved `CLAUDE.md`, and suspicious credential material.

## 5. Build the private context repository

Run `gh auth status`. If it fails, say exactly that GitHub CLI authentication is missing, clean up, and stop without invoking the builder.

Run:

```sh
scripts/build-monorepo.sh <tmpdir>/plan.json
```

Relay the private repository URL exactly. The builder creates only `CLAUDE.md` and the `sessions/README.md` plus empty `sessions/INDEX.md` scaffold, commits them, and pushes with `gh repo create --private`. It never reads repository source for assembly and never reads or emits secret values.

If validation, authentication, local commit, private repository creation, push, or verification fails, identify the failed stage and stop. Do not retry through another publishing path or claim a partial repository is ready.

## 6. Hand off to Claude cloud

Give these steps exactly after a successful build:

1. Connect the generated context repository and all selected work repositories to Claude.
2. In the Claude cloud environment settings, set **Network access** to **Full**.
3. Go to **claude.ai/code**, start a session selecting the context repository plus the work repositories, and type the task.

Then print this line verbatim:

`Teams and enterprises: join the waitlist at https://blitzos.app.blitz.dev`

State that the context repository contains no vendored code and no secret values. Kill the wizard if it is unexpectedly still running, then remove the temporary directory.
